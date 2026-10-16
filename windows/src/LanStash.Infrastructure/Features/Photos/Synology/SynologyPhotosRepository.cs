using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

/// <summary>
/// Synology Photos 内部接口。字段与固定版本依据 photos-library-read.md；
/// 每个实例绑定一个登录会话，不回退 File Station，不把管理员身份当作共享空间授权。
/// </summary>
public sealed partial class SynologyPhotosRepository : ISynologyPhotosRepository
{
    private readonly NasProfile _profile;
    private readonly DsmSession _session;
    private readonly IDsmApiClient _api;
    private readonly IReadOnlyDictionary<string, ApiCapability> _capabilities;
    private readonly object _accessGate = new();
    private long _accessGeneration;
    private volatile bool _personalAllowed;
    private volatile bool _sharedAllowed;
    private volatile bool _hasPhotosAccess;
    private bool _managesSharedSpace;
    public bool SupportsOriginalSizeJpeg { get; private set; }
    private long? _currentUserId;
    private SynologyPhotoShareIdentity? _currentUserUid;
    private IReadOnlySet<SynologyPhotoCategory> _disabledPersonalCategories = new HashSet<SynologyPhotoCategory>();
    private IReadOnlySet<SynologyPhotoCategory> _sharedCategories = new HashSet<SynologyPhotoCategory>();

    public SynologyPhotosRepository(NasProfile profile, DsmSession session, IDsmApiClient api,
        IReadOnlyDictionary<string, ApiCapability> capabilities, bool deletionEnabled = false, IProtectedTaskStore? uploadStore = null,
        IProtectedTaskStore? managementStore = null, SynologyPhotoFileSafety? fileSafety = null, SynologyPhotoAlbumSafety? albumSafety = null,
        SynologyPhotoSharingSafety? sharingSafety = null, SynologyPhotoRecognitionSafety? recognitionSafety = null,
        ISynologyPhotoPreviewConverter? previewConverter = null, SynologyPhotoSettingsSafety? settingsSafety = null)
    {
        if (profile.Id != session.ProfileId || profile.Id == Guid.Empty || string.IsNullOrWhiteSpace(session.Sid))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        _profile = profile;
        _session = session;
        _api = api;
        _capabilities = new Dictionary<string, ApiCapability>(capabilities, StringComparer.Ordinal);
        CanDeleteOriginals = deletionEnabled;
        FileSafety = fileSafety ?? new();
        AlbumSafety = albumSafety ?? new();
        SharingSafety = sharingSafety ?? new();
        RecognitionSafety = recognitionSafety ?? new();
        SettingsSafety = settingsSafety ?? new();
        _previewConverter = previewConverter ?? new WindowsPhotoPreviewConverter();
        _uploadStore = uploadStore;
        _uploads = uploadStore is null ? new() : UploadRegistries.GetValue(uploadStore, _ => new());
        _managementStore = managementStore;
        _changes = managementStore is null ? new() : ManagementRegistries.GetValue(managementStore, _ => new());
    }

    public Guid ProfileId => _profile.Id;
    public bool CanDeleteOriginals { get; }
    public SynologyPhotoFileSafety FileSafety { get; }
    public SynologyPhotoAlbumSafety AlbumSafety { get; }
    public SynologyPhotoSharingSafety SharingSafety { get; }
    public SynologyPhotoRecognitionSafety RecognitionSafety { get; }
    public SynologyPhotoSettingsSafety SettingsSafety { get; }

    public async Task<SynologyPhotoAccess> AccessAsync(CancellationToken cancellationToken = default)
    {
        long generation;
        lock (_accessGate)
        {
            _personalAllowed = false; _sharedAllowed = false; _hasPhotosAccess = false;
            _categoryThumbnails.Clear();
            _authorizedFaces.Clear();
            _managesSharedSpace = false; SupportsOriginalSizeJpeg = false; _currentUserId = null; _currentUserUid = null; _sharedCategories = new HashSet<SynologyPhotoCategory>();
            generation = Interlocked.Increment(ref _accessGeneration);
        }
        var info = await CallAsync("UserInfo", 1, "me", cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!Boolean(info, "enabled"))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var user = await CallAsync("Setting.User", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        var home = Boolean(user, "enable_home_service");
        var teamPermission = Text(user, "team_space_permission");
        var admin = await CallAsync("Setting.Admin", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        var team = await CallAsync("Setting.TeamSpace", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        var shared = Boolean(team, "enabled") && teamPermission is "entry" or "management";
        var packageVersion = Text(admin, "package_version");
        var currentUserId = info["id"] is null ? (long?)null : Positive(info, "id");
        var currentUserUid = ShareIdentity("user", info["uid"]);
        var managesShared = shared && teamPermission == "management";
        var disabledPersonal = new HashSet<SynologyPhotoCategory>();
        foreach (var (category, field) in new[] { (SynologyPhotoCategory.People, "enable_person"), (SynologyPhotoCategory.Subjects, "enable_concept") })
        {
            if ((user[field] is not null && !Boolean(user, field)) || (admin[field] is not null && !Boolean(admin, field))) disabledPersonal.Add(category);
        }
        var categories = new HashSet<SynologyPhotoCategory>
        { SynologyPhotoCategory.Recent, SynologyPhotoCategory.Locations, SynologyPhotoCategory.Tags, SynologyPhotoCategory.Videos };
        if (Permission(team, "enable_person") && (admin["enable_person"] is null || Boolean(admin, "enable_person"))) categories.Add(SynologyPhotoCategory.People);
        if (Permission(team, "enable_concept") && (admin["enable_concept"] is null || Boolean(admin, "enable_concept"))) categories.Add(SynologyPhotoCategory.Subjects);
        if (!Permission(user, "enable_similar")) disabledPersonal.Add(SynologyPhotoCategory.Similar);
        if (Permission(team, "enable_similar")) categories.Add(SynologyPhotoCategory.Similar);
        lock (_accessGate)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (generation != Volatile.Read(ref _accessGeneration)) throw new OperationCanceledException(cancellationToken);
            _personalAllowed = home; _sharedAllowed = shared; _hasPhotosAccess = true;
            _managesSharedSpace = managesShared; _currentUserId = currentUserId; _sharedCategories = categories; _disabledPersonalCategories = disabledPersonal;
            _currentUserUid = currentUserUid;
            SupportsOriginalSizeJpeg = Permission(OptionalObject(user, "ame_status"), "has_hevc") && Permission(admin, "enable_converted_original_jpeg");
        }
        var spaces = new List<SynologyPhotoSpace>();
        if (home) spaces.Add(SynologyPhotoSpace.Personal);
        if (shared) spaces.Add(SynologyPhotoSpace.Shared);
        return new(spaces, packageVersion) { CanManageSharedSpace = managesShared, IsAdministrator = KnownPreference(info, "is_admin") == true, DisplaySettings = ParseDisplaySettings(user) };
    }

    public async Task<IReadOnlyList<SynologyPhotoDay>> TimelineAsync(SynologyPhotoQuery? query = null,
        CancellationToken cancellationToken = default)
    {
        var parameters = Parameters(("timeline_group_unit", "day"));
        var (api, version, method) = ("Browse.Timeline", 5, "get");
        switch (query)
        {
            case null or SynologyPhotoQuery.Timeline: break;
            case SynologyPhotoQuery.Search search:
                (api, version, method) = ("Search.Search", 2, "get_search_timeline");
                parameters["keyword"] = JsonSerializer.Serialize(search.Keyword);
                break;
            case SynologyPhotoQuery.Filtered filtered:
                (version, method) = (3, "get_with_filter");
                Add(parameters, FilterParameters(filtered.Filter));
                break;
            case SynologyPhotoQuery.Category { Kind: SynologyPhotoCategory.Similar } similar:
                RequireSimilarAccess(similar.Space); (api, version, method) = ("Browse.SimilarTimeline", 1, "get_similar"); break;
            case SynologyPhotoQuery.Category category:
                RequireCategoryAccess(category.Kind, category.Space);
                RequirePositive(category.Id);
                parameters[CategoryParameter(category.Kind)] = JsonSerializer.Serialize(category.Id);
                break;
            default: throw Invalid();
        }
        return Days(await ReadAsync(api, version, method, parameters, cancellationToken, query?.Space ?? SynologyPhotoSpace.Personal).ConfigureAwait(false));
    }

    public async Task<SynologyPhotoPage> PhotosAsync(SynologyPhotoQuery query, int offset, int limit,
        CancellationToken cancellationToken = default)
    {
        var space = query is SynologyPhotoQuery.Album ? (SynologyPhotoSpace?)null : query.Space;
        RequireAccess(space);
        var parameters = PageParameters(offset, limit);
        parameters["additional"] = JsonSerializer.Serialize(new[] { "thumbnail", "resolution", "orientation", "video_convert", "video_meta", "address" });
        var (api, version, method) = ("Browse.Item", 4, "list");
        void Range(long start, long end)
        {
            _ = Time(start, end);
            Add(parameters, Parameters(("start_time", start), ("end_time", end)));
        }
        switch (query)
        {
            case SynologyPhotoQuery.Timeline timeline: Range(timeline.Start, timeline.End); break;
            case SynologyPhotoQuery.Search search:
                (api, version, method) = ("Search.Search", 1, "list_item");
                parameters["keyword"] = JsonSerializer.Serialize(search.Keyword);
                Range(search.Start, search.End);
                break;
            case SynologyPhotoQuery.Folder folder:
                RequirePositive(folder.Id);
                Add(parameters, Parameters(("folder_id", folder.Id), ("sort_by", SortField((folder.Sort ?? new()).Field)), ("sort_direction", folder.Sort?.Descending == true ? "desc" : "asc"),
                    ("additional", new[] { "thumbnail", "resolution", "orientation", "video_convert", "video_meta" })));
                break;
            case SynologyPhotoQuery.Album album:
                RequirePositive(album.Id);
                Add(parameters, Parameters(("album_id", album.Id), ("sort_by", SortField((album.Sort ?? new()).Field)), ("sort_direction", album.Sort?.Descending == false ? "asc" : "desc"),
                    ("additional", new[] { "thumbnail", "resolution", "orientation", "video_convert", "video_meta", "provider_user_id" })));
                break;
            case SynologyPhotoQuery.Recent:
                (api, version) = ("Browse.RecentlyAdded", 1);
                parameters["additional"] = JsonSerializer.Serialize(new[] { "thumbnail" });
                break;
            case SynologyPhotoQuery.Category { Kind: SynologyPhotoCategory.Similar } similar:
                RequireSimilarAccess(similar.Space); (api, version, method) = ("Browse.SimilarItem", 1, "list_similar"); Range(similar.Start, similar.End); break;
            case SynologyPhotoQuery.Filtered filtered:
                _ = Time(filtered.Start, filtered.End);
                (version, method) = (2, "list_with_filter");
                Add(parameters, FilterParameters(filtered.Filter));
                var start = Math.Max(filtered.Start, filtered.Filter.StartTime ?? 0);
                var end = Math.Min(filtered.End, filtered.Filter.EndTime ?? long.MaxValue);
                if (end < start) return new([], offset, offset, false);
                parameters["time"] = Time(start, end);
                break;
            case SynologyPhotoQuery.Category category:
                RequireCategoryAccess(category.Kind, category.Space);
                RequirePositive(category.Id);
                parameters[CategoryParameter(category.Kind)] = JsonSerializer.Serialize(category.Id);
                Range(category.Start, category.End);
                break;
            default: throw Invalid();
        }
        var raw = List(await ReadAsync(api, version, method, parameters, cancellationToken, space).ConfigureAwait(false));
        var albumId = (query as SynologyPhotoQuery.Album)?.Id;
        var items = raw.Select(item => Photo(item, ProfileId, query.Space, albumId)).ToArray();
        if (query is SynologyPhotoQuery.Category { Kind: SynologyPhotoCategory.Similar } && items.Any(item => item.SimilarGroup is null)) throw Invalid();
        if (items.Length > limit || raw.Select(item => Number(item, "id")).Distinct().Count() != raw.Length) throw Invalid();
        // API 没有 total/has_more；使用原始返回条数推进，短页和空页才结束。
        return new(items, offset, checked(offset + raw.Length), raw.Length == limit);
    }

    public async Task<SynologyPhotoCollection> RootFolderAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal)
    {
        var result = await ReadAsync("Browse.Folder", 2, "get", Parameters(("name", "/"), ("additional", new[] { "access_permission" })), cancellationToken, space).ConfigureAwait(false);
        var folder = Object(result["folder"]);
        var additional = OptionalObject(folder, "additional");
        if (!(space == SynologyPhotoSpace.Shared && _managesSharedSpace) &&
            !Permission(additional is null ? null : OptionalObject(additional, "access_permission"), "view"))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return Collection(folder, true) with { Space = space };
    }

    public Task<IReadOnlyList<SynologyPhotoCollection>> FoldersAsync(long parentId, int offset, int limit,
        CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal)
        => FoldersAsync(parentId, offset, limit, false, cancellationToken, space);
    public async Task<IReadOnlyList<SynologyPhotoCollection>> FoldersAsync(long parentId, int offset, int limit, bool descending,
        CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal)
    {
        RequirePositive(parentId);
        var parameters = PageParameters(offset, limit);
        Add(parameters, Parameters(("id", parentId), ("sort_by", "filename"), ("sort_direction", descending ? "desc" : "asc"), ("additional", new[] { "thumbnail" })));
        return Collections(await ReadAsync("Browse.Folder", 2, "list", parameters, cancellationToken, space).ConfigureAwait(false), limit, true, parentId)
            .Select(item => item with { Space = space }).ToArray();
    }

    public async Task<IReadOnlyList<SynologyPhotoCollection>> AlbumsAsync(int offset, int limit, CancellationToken cancellationToken = default)
    {
        var parameters = PageParameters(offset, limit);
        Add(parameters, Parameters(("category", "normal_share_with_me"), ("additional", new[] { "thumbnail", "sharing_info" })));
        return Collections(await ReadAsync("Browse.Album", 4, "list", parameters, cancellationToken, space: null).ConfigureAwait(false), limit);
    }

    public async Task<IReadOnlySet<SynologyPhotoCategory>> CategoriesAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal)
    {
        RequireAccess(space);
        if (space == SynologyPhotoSpace.Shared && !_managesSharedSpace) return new HashSet<SynologyPhotoCategory>();
        // 分类入口只有统一 Foto；不得构造不存在的 FotoTeam.Category。
        var payload = await ReadAsync("Browse.Category", 3, "get", cancellationToken: cancellationToken, space: null).ConfigureAwait(false);
        return List(payload).Select(item => Text(item, "id") switch
        {
            "recently_added" => (SynologyPhotoCategory?)SynologyPhotoCategory.Recent,
            "person" => SynologyPhotoCategory.People,
            "concept" => SynologyPhotoCategory.Subjects,
            "geocoding" => SynologyPhotoCategory.Locations,
            "general_tag" => SynologyPhotoCategory.Tags,
            "video" => SynologyPhotoCategory.Videos,
            "similar" => SynologyPhotoCategory.Similar,
            _ => null,
        }).OfType<SynologyPhotoCategory>().Where(category => category != SynologyPhotoCategory.Similar || SupportsSimilar(space)).Where(category => space == SynologyPhotoSpace.Personal
            ? !_disabledPersonalCategories.Contains(category) : _sharedCategories.Contains(category) && SupportsCategory(category, space)).ToHashSet();
    }

    public async Task<IReadOnlyList<SynologyPhotoCollection>> CategoryItemsAsync(SynologyPhotoCategory category,
        int offset, int limit, CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal)
    {
        RequireCategoryAccess(category, space);
        if (category == SynologyPhotoCategory.People)
            return (await PersonPageAsync(space, offset, limit, false, cancellationToken).ConfigureAwait(false)).Select(person => person.Person).ToArray();
        var (suffix, version) = category switch
        {
            SynologyPhotoCategory.People => ("Browse.Person", 1),
            SynologyPhotoCategory.Subjects => ("Browse.Concept", 2),
            SynologyPhotoCategory.Locations => ("Browse.Geocoding", 1),
            SynologyPhotoCategory.Tags => ("Browse.GeneralTag", 1),
            _ => throw Invalid(),
        };
        var parameters = PageParameters(offset, limit);
        Add(parameters, Parameters(("additional", new[] { "thumbnail" })));
        var generation = Volatile.Read(ref _accessGeneration);
        var data = await ReadAsync(suffix, version, "list", parameters, cancellationToken, space).ConfigureAwait(false);
        var values = Collections(data, limit).Select(item => item with { Space = space }).ToArray();
        if (category == SynologyPhotoCategory.Subjects)
        {
            var raw = List(data);
            for (var index = 0; index < values.Length; index++)
                if (OptionalObject(OptionalObject(raw[index], "additional") ?? new(), "thumbnail") is { } thumb)
                    values[index] = values[index] with { Thumbnail = new(Positive(thumb, "unit_id"), Text(thumb, "cache_key")) { Space = space, NativeSize = true } };
            lock (_accessGate) { RequireGeneration(generation, cancellationToken); CacheConcepts(values.Select(value => new SynologyPhotoConcept(value, true)).ToArray(), space, offset == 0); }
        }
        return values;
    }

    public Task<IReadOnlyList<SynologyPhotoSharedEntry>> SharedEntriesAsync(SynologyPhotoShareScope scope,
        int offset, int limit, CancellationToken cancellationToken = default)
        => ReadSharedAlbumsAsync(scope, offset, limit, null, cancellationToken);
    public Task<IReadOnlyList<SynologyPhotoSharedEntry>> SharedEntriesAsync(SynologyPhotoShareScope scope,
        int offset, int limit, SynologyPhotoAlbumListSort sort, CancellationToken cancellationToken = default)
        => ReadSharedAlbumsAsync(scope, offset, limit, sort, cancellationToken);
    private async Task<IReadOnlyList<SynologyPhotoSharedEntry>> ReadSharedAlbumsAsync(SynologyPhotoShareScope scope,
        int offset, int limit, SynologyPhotoAlbumListSort? sort, CancellationToken cancellationToken)
    {
        RequireAccess();
        if (!Enum.IsDefined(scope) || scope == SynologyPhotoShareScope.Requests && sort is not null) throw Invalid();
        if (sort is not null) ValidateAlbumListSort(scope == SynologyPhotoShareScope.WithMe ? SynologyPhotoAlbumListScope.WithMe : SynologyPhotoAlbumListScope.ByMe, sort);
        if (scope == SynologyPhotoShareScope.Requests && !_personalAllowed && !_sharedAllowed)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var parameters = PageParameters(offset, limit);
        if (sort is not null) Add(parameters, Parameters(("sort_by", AlbumListField(sort.Field)), ("sort_direction", sort.Descending ? "desc" : "asc")));
        JsonObject payload;
        if (scope == SynologyPhotoShareScope.Requests)
            payload = await ReadAsync("PhotoRequest", 1, "list", parameters, cancellationToken, space: null).ConfigureAwait(false);
        else if (scope == SynologyPhotoShareScope.WithMe)
        {
            Add(parameters, Parameters(("additional", new[] { "sharing_info", "thumbnail", "access_permission" })));
            payload = await ReadAsync("Sharing.Misc", 2, "list_shared_with_me_album", parameters, cancellationToken, space: null).ConfigureAwait(false);
        }
        else
        {
            Add(parameters, Parameters(("category", "shared"), ("sort_by", sort is null ? "share_modify_time" : AlbumListField(sort.Field)), ("sort_direction", sort?.Descending == false ? "asc" : "desc"),
                ("additional", new[] { "thumbnail", "sharing_info" })));
            payload = await ReadAsync("Browse.Album", 4, "list", parameters, cancellationToken, space: null).ConfigureAwait(false);
        }
        var result = List(payload).Select(item => scope == SynologyPhotoShareScope.Requests
            ? new SynologyPhotoSharedEntry(Text(item, "passphrase"), Text(item, "subject"), Url: SafeSharingUri(OptionalText(item, "sharing_link")))
            : new SynologyPhotoSharedEntry(Positive(item, "id").ToString(System.Globalization.CultureInfo.InvariantCulture), Text(item, "name"), Positive(item, "id"))).ToArray();
        if (result.Length > limit || result.Any(item => item.Id.Length == 0) || result.DistinctBy(item => item.Id).Count() != result.Length) throw Invalid();
        return result;
    }

    public async Task<SynologyPhotoFilterOptions> FilterOptionsAsync(CancellationToken cancellationToken = default, SynologyPhotoSpace space = SynologyPhotoSpace.Personal)
    {
        var setting = new[] { "item_type", "time", "person", "geocoding", "rating", "general_tag", "camera", "lens", "iso", "aperture", "focal_length_group", "exposure_time_group" }
            .ToDictionary(key => key, _ => true, StringComparer.Ordinal);
        return Options(await ReadAsync("Search.Filter", 3, "list", Parameters(("setting", setting), ("additional", new[] { "thumbnail" })), cancellationToken, space).ConfigureAwait(false));
    }

    private async Task<JsonObject> ReadAsync(string suffix, int version, string method,
        IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default,
        SynologyPhotoSpace? space = SynologyPhotoSpace.Personal)
    {
        RequireAccess(space);
        var generation = Volatile.Read(ref _accessGeneration);
        var result = await CallAsync(suffix, version, method, parameters, cancellationToken, space).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken);
        return result;
    }

    private Task<JsonObject> CallAsync(string suffix, int version, string method,
        IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default,
        SynologyPhotoSpace? space = SynologyPhotoSpace.Personal) =>
        _api.CallPhotoJsonAsync(_profile, _session, Capability(suffix, version, space), version, method, parameters, cancellationToken);

    private ApiCapability Capability(string suffix, int version, SynologyPhotoSpace? space = SynologyPhotoSpace.Personal)
    {
        var name = $"{(space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam" : "SYNO.Foto")}.{suffix}";
        if (!_capabilities.TryGetValue(name, out var capability) || capability.Name != name ||
            version < capability.MinVersion || version > capability.MaxVersion ||
            !capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase) ||
            capability.Path is not ("entry.cgi" or "webapi/entry.cgi" or "/webapi/entry.cgi"))
            throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        return capability with { MinVersion = version, MaxVersion = version };
    }

    private void RequireAccess(SynologyPhotoSpace? space = null)
    {
        if (!_hasPhotosAccess || (space is { } source && (source switch
            { SynologyPhotoSpace.Personal => !_personalAllowed, SynologyPhotoSpace.Shared => !_sharedAllowed, _ => true })))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private void RequireCategoryAccess(SynologyPhotoCategory category, SynologyPhotoSpace space)
    {
        RequireAccess(space);
        if ((space == SynologyPhotoSpace.Personal && _disabledPersonalCategories.Contains(category)) ||
            (space == SynologyPhotoSpace.Shared && (!_managesSharedSpace || !_sharedCategories.Contains(category))))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private bool SupportsCategory(SynologyPhotoCategory category, SynologyPhotoSpace space)
    {
        if (category == SynologyPhotoCategory.Similar) return SupportsSimilar(space);
        var (suffix, version) = category switch
        {
            SynologyPhotoCategory.People => ("Browse.Person", 1), SynologyPhotoCategory.Subjects => ("Browse.Concept", 2),
            SynologyPhotoCategory.Locations => ("Browse.Geocoding", 1), SynologyPhotoCategory.Tags => ("Browse.GeneralTag", 1),
            SynologyPhotoCategory.Recent => ("Browse.RecentlyAdded", 1), SynologyPhotoCategory.Videos => ("Browse.Item", 4),
            _ => throw Invalid(),
        };
        try { _ = Capability(suffix, version, space); return true; }
        catch (SynologyPhotoException error) when (error.Failure == SynologyPhotoFailure.Unavailable) { return false; }
    }
    private void RequirePhoto(SynologyPhoto photo)
    {
        if (photo.Id.ProfileId != ProfileId || photo.Id.ItemId <= 0)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (photo.AlbumContext is { } context)
        {
            RequireAccess();
            if (context.AlbumId <= 0 || context.OwnerUserId < 0 || context.ProviderUserId < 0 ||
                photo.Id.Space != (context.OwnerUserId == 0 ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal))
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
        else RequireAccess(photo.Id.Space);
    }
    private void RequireDeletablePhoto(SynologyPhoto photo)
    {
        RequirePhoto(photo); RequireAccess(photo.Id.Space);
        // 本切片只增补读取；共享原件删除等待管理切片与真实 NAS 验收。
        if (photo.Id.Space != SynologyPhotoSpace.Personal ||
            (photo.AlbumContext is { } context && context.OwnerUserId != _currentUserId))
            throw new SynologyPhotoException(SynologyPhotoFailure.DeleteDenied);
    }
    private static SynologyPhotoSpace? ReadSpace(SynologyPhoto photo) => photo.AlbumContext is null ? photo.Id.Space : null;
    private static Dictionary<string, string> ReadParameters(SynologyPhoto photo, params (string Key, object Value)[] values)
    {
        var result = Parameters(values);
        if (photo.AlbumContext is { } context) result["album_id"] = JsonSerializer.Serialize(context.AlbumId);
        return result;
    }
    private void RequireGeneration(long generation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (generation != Volatile.Read(ref _accessGeneration)) throw new OperationCanceledException(cancellationToken);
        RequireAccess();
    }
    private static void RequirePositive(long value) { if (value <= 0) throw Invalid(); }
    private static void Add(Dictionary<string, string> destination, IReadOnlyDictionary<string, string> values)
    {
        foreach (var (key, value) in values) destination[key] = value;
    }
    private static Dictionary<string, string> PageParameters(int offset, int limit)
    {
        if (offset < 0 || limit is < 1 or > 500 || offset > int.MaxValue - limit) throw Invalid();
        return Parameters(("offset", offset), ("limit", limit));
    }
    private static string CategoryParameter(SynologyPhotoCategory category) => category switch
    {
        SynologyPhotoCategory.People => "person_id", SynologyPhotoCategory.Subjects => "concept_id",
        SynologyPhotoCategory.Locations => "geocoding_id", SynologyPhotoCategory.Tags => "general_tag_id",
        _ => throw Invalid(),
    };
    private static Uri? SafeSharingUri(string? value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme is "https" or "http" && uri.Host.Length > 0 && uri.UserInfo.Length == 0 ? uri : null;
}
