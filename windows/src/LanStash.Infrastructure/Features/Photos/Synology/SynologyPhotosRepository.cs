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
    private long _accessGeneration;
    private volatile bool _personalAllowed;
    private readonly SemaphoreSlim _deletionGate = new(1, 1);
    private readonly Dictionary<Guid, SynologyPhoto> _operations = [];
    private readonly Dictionary<SynologyPhotoIdentity, SynologyPhoto> _pendingDeletions = [];
    private readonly Dictionary<SynologyPhotoIdentity, SynologyPhoto> _confirmedDeletions = [];

    public SynologyPhotosRepository(NasProfile profile, DsmSession session, IDsmApiClient api,
        IReadOnlyDictionary<string, ApiCapability> capabilities, bool deletionEnabled = false)
    {
        if (profile.Id != session.ProfileId || profile.Id == Guid.Empty || string.IsNullOrWhiteSpace(session.Sid))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        _profile = profile;
        _session = session;
        _api = api;
        _capabilities = new Dictionary<string, ApiCapability>(capabilities, StringComparer.Ordinal);
        CanDeleteOriginals = deletionEnabled;
    }

    public Guid ProfileId => _profile.Id;
    public bool CanDeleteOriginals { get; }

    public async Task<SynologyPhotoAccess> AccessAsync(CancellationToken cancellationToken = default)
    {
        _personalAllowed = false;
        var generation = Interlocked.Increment(ref _accessGeneration);
        if (!Boolean(await CallAsync("UserInfo", 1, "me", cancellationToken: cancellationToken).ConfigureAwait(false), "enabled"))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var user = await CallAsync("Setting.User", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        var home = Boolean(user, "enable_home_service");
        _ = Text(user, "team_space_permission");
        var admin = await CallAsync("Setting.Admin", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        var team = await CallAsync("Setting.TeamSpace", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        _ = Boolean(team, "enabled");
        var packageVersion = Text(admin, "package_version");
        cancellationToken.ThrowIfCancellationRequested();
        if (generation != Volatile.Read(ref _accessGeneration)) throw new OperationCanceledException(cancellationToken);
        _personalAllowed = home;
        return new(home ? [SynologyPhotoSpace.Personal] : [], packageVersion);
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
            case SynologyPhotoQuery.Category category:
                RequirePositive(category.Id);
                parameters[CategoryParameter(category.Kind)] = JsonSerializer.Serialize(category.Id);
                break;
            default: throw Invalid();
        }
        return Days(await ReadAsync(api, version, method, parameters, cancellationToken).ConfigureAwait(false));
    }

    public async Task<SynologyPhotoPage> PhotosAsync(SynologyPhotoQuery query, int offset, int limit,
        CancellationToken cancellationToken = default)
    {
        RequireAccess();
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
                Add(parameters, Parameters(("folder_id", folder.Id), ("sort_by", "takentime"), ("sort_direction", "asc"),
                    ("additional", new[] { "thumbnail", "resolution", "orientation", "video_convert", "video_meta" })));
                break;
            case SynologyPhotoQuery.Album album:
                RequirePositive(album.Id);
                Add(parameters, Parameters(("album_id", album.Id), ("sort_by", "takentime"), ("sort_direction", "desc"),
                    ("additional", new[] { "thumbnail", "resolution", "orientation", "video_convert", "video_meta", "provider_user_id" })));
                break;
            case SynologyPhotoQuery.Recent:
                (api, version) = ("Browse.RecentlyAdded", 1);
                parameters["additional"] = JsonSerializer.Serialize(new[] { "thumbnail" });
                break;
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
                RequirePositive(category.Id);
                parameters[CategoryParameter(category.Kind)] = JsonSerializer.Serialize(category.Id);
                Range(category.Start, category.End);
                break;
            default: throw Invalid();
        }
        var raw = List(await ReadAsync(api, version, method, parameters, cancellationToken).ConfigureAwait(false));
        var items = raw.Select(item => Photo(item, ProfileId)).ToArray();
        if (items.Length > limit || items.DistinctBy(item => item.Id).Count() != items.Length) throw Invalid();
        // API 没有 total/has_more；使用原始返回条数推进，短页和空页才结束。
        return new(items, offset, checked(offset + raw.Length), raw.Length == limit);
    }

    public async Task<SynologyPhotoCollection> RootFolderAsync(CancellationToken cancellationToken = default)
    {
        var result = await ReadAsync("Browse.Folder", 2, "get", Parameters(("name", "/"), ("additional", new[] { "access_permission" })), cancellationToken).ConfigureAwait(false);
        var folder = Object(result["folder"]);
        var additional = OptionalObject(folder, "additional");
        if (!Permission(additional is null ? null : OptionalObject(additional, "access_permission"), "view"))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return Collection(folder, true);
    }

    public async Task<IReadOnlyList<SynologyPhotoCollection>> FoldersAsync(long parentId, int offset, int limit,
        CancellationToken cancellationToken = default)
    {
        RequirePositive(parentId);
        var parameters = PageParameters(offset, limit);
        Add(parameters, Parameters(("id", parentId), ("sort_by", "filename"), ("sort_direction", "asc"), ("additional", new[] { "thumbnail" })));
        return Collections(await ReadAsync("Browse.Folder", 2, "list", parameters, cancellationToken).ConfigureAwait(false), limit, true, parentId);
    }

    public async Task<IReadOnlyList<SynologyPhotoCollection>> AlbumsAsync(int offset, int limit, CancellationToken cancellationToken = default)
    {
        var parameters = PageParameters(offset, limit);
        Add(parameters, Parameters(("category", "normal_share_with_me"), ("additional", new[] { "thumbnail", "sharing_info" })));
        return Collections(await ReadAsync("Browse.Album", 4, "list", parameters, cancellationToken).ConfigureAwait(false), limit);
    }

    public async Task<IReadOnlySet<SynologyPhotoCategory>> CategoriesAsync(CancellationToken cancellationToken = default)
    {
        var payload = await ReadAsync("Browse.Category", 3, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        return List(payload).Select(item => Text(item, "id") switch
        {
            "recently_added" => (SynologyPhotoCategory?)SynologyPhotoCategory.Recent,
            "person" => SynologyPhotoCategory.People,
            "concept" => SynologyPhotoCategory.Subjects,
            "geocoding" => SynologyPhotoCategory.Locations,
            "general_tag" => SynologyPhotoCategory.Tags,
            "video" => SynologyPhotoCategory.Videos,
            _ => null,
        }).OfType<SynologyPhotoCategory>().ToHashSet();
    }

    public async Task<IReadOnlyList<SynologyPhotoCollection>> CategoryItemsAsync(SynologyPhotoCategory category,
        int offset, int limit, CancellationToken cancellationToken = default)
    {
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
        return Collections(await ReadAsync(suffix, version, "list", parameters, cancellationToken).ConfigureAwait(false), limit);
    }

    public async Task<IReadOnlyList<SynologyPhotoSharedEntry>> SharedEntriesAsync(SynologyPhotoShareScope scope,
        int offset, int limit, CancellationToken cancellationToken = default)
    {
        var parameters = PageParameters(offset, limit);
        JsonObject payload;
        if (scope == SynologyPhotoShareScope.Requests)
            payload = await ReadAsync("PhotoRequest", 1, "list", parameters, cancellationToken).ConfigureAwait(false);
        else if (scope == SynologyPhotoShareScope.WithMe)
        {
            Add(parameters, Parameters(("additional", new[] { "sharing_info", "thumbnail", "access_permission" })));
            payload = await ReadAsync("Sharing.Misc", 2, "list_shared_with_me_album", parameters, cancellationToken).ConfigureAwait(false);
        }
        else
        {
            Add(parameters, Parameters(("category", "shared"), ("sort_by", "share_modify_time"), ("sort_direction", "desc"),
                ("additional", new[] { "thumbnail", "sharing_info" })));
            payload = await ReadAsync("Browse.Album", 4, "list", parameters, cancellationToken).ConfigureAwait(false);
        }
        var result = List(payload).Select(item => scope == SynologyPhotoShareScope.Requests
            ? new SynologyPhotoSharedEntry(Text(item, "passphrase"), Text(item, "subject"), Url: SafeSharingUri(OptionalText(item, "sharing_link")))
            : new SynologyPhotoSharedEntry(Positive(item, "id").ToString(System.Globalization.CultureInfo.InvariantCulture), Text(item, "name"), Positive(item, "id"))).ToArray();
        if (result.Length > limit || result.Any(item => item.Id.Length == 0) || result.DistinctBy(item => item.Id).Count() != result.Length) throw Invalid();
        return result;
    }

    public async Task<SynologyPhotoFilterOptions> FilterOptionsAsync(CancellationToken cancellationToken = default)
    {
        var setting = new[] { "item_type", "time", "person", "geocoding", "rating", "general_tag", "camera", "lens", "iso", "aperture", "focal_length_group", "exposure_time_group" }
            .ToDictionary(key => key, _ => true, StringComparer.Ordinal);
        return Options(await ReadAsync("Search.Filter", 3, "list", Parameters(("setting", setting), ("additional", new[] { "thumbnail" })), cancellationToken).ConfigureAwait(false));
    }

    private async Task<JsonObject> ReadAsync(string suffix, int version, string method,
        IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default)
    {
        RequireAccess();
        var generation = Volatile.Read(ref _accessGeneration);
        var result = await CallAsync(suffix, version, method, parameters, cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken);
        return result;
    }

    private Task<JsonObject> CallAsync(string suffix, int version, string method,
        IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) =>
        _api.CallPhotoJsonAsync(_profile, _session, Capability(suffix, version), version, method, parameters, cancellationToken);

    private ApiCapability Capability(string suffix, int version)
    {
        var name = $"SYNO.Foto.{suffix}";
        if (!_capabilities.TryGetValue(name, out var capability) || capability.Name != name ||
            version < capability.MinVersion || version > capability.MaxVersion ||
            !capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase) ||
            capability.Path is not ("entry.cgi" or "webapi/entry.cgi" or "/webapi/entry.cgi"))
            throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        return capability with { MinVersion = version, MaxVersion = version };
    }

    private void RequireAccess()
    {
        if (!_personalAllowed) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private void RequirePhoto(SynologyPhoto photo)
    {
        RequireAccess();
        if (photo.Id.ProfileId != ProfileId || photo.Id.Space != SynologyPhotoSpace.Personal || photo.Id.ItemId <= 0)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
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
        uri.Scheme == Uri.UriSchemeHttps && uri.Host.Length > 0 && uri.UserInfo.Length == 0 ? uri : null;
}
