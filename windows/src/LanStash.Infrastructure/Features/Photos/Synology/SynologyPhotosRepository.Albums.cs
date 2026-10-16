using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public bool SupportsAlbumManagement => SupportsManagement;
    private static string AlbumScope(SynologyPhotoAlbumListScope scope) => scope switch
    { SynologyPhotoAlbumListScope.Albums => "album_list", SynologyPhotoAlbumListScope.WithMe => "shared_with_me", SynologyPhotoAlbumListScope.ByMe => "shared_with_others", _ => throw Invalid() };
    private static string AlbumListField(SynologyPhotoAlbumListField field) => field switch
    {
        SynologyPhotoAlbumListField.Name => "album_name", SynologyPhotoAlbumListField.Type => "album_type", SynologyPhotoAlbumListField.StartTime => "start_time",
        SynologyPhotoAlbumListField.Created => "create_time", SynologyPhotoAlbumListField.Sharing => "share_status", SynologyPhotoAlbumListField.ShareModified => "share_modify_time", _ => throw Invalid(),
    };
    private static void ValidateAlbumListSort(SynologyPhotoAlbumListScope scope, SynologyPhotoAlbumListSort sort)
    {
        _ = AlbumScope(scope); _ = AlbumListField(sort.Field);
        if (scope == SynologyPhotoAlbumListScope.Albums && sort.Field == SynologyPhotoAlbumListField.ShareModified ||
            scope != SynologyPhotoAlbumListScope.Albums && sort.Field is SynologyPhotoAlbumListField.Created or SynologyPhotoAlbumListField.Sharing) throw Invalid();
    }
    public async Task<SynologyPhotoAlbumListSort> AlbumListSortAsync(SynologyPhotoAlbumListScope scope, CancellationToken cancellationToken = default)
    {
        var key = AlbumScope(scope);
        var data = await ReadAsync("Browse.Album", 2, "get_album_list_order", cancellationToken: cancellationToken, space: null).ConfigureAwait(false);
        var field = Enum.GetValues<SynologyPhotoAlbumListField>().Cast<SynologyPhotoAlbumListField?>().SingleOrDefault(value => AlbumListField(value!.Value) == Text(data, key + "_sort_by")) ?? throw Invalid();
        var sort = new SynologyPhotoAlbumListSort(field, SortDirection(Text(data, key + "_sort_direction")) ?? throw Invalid());
        ValidateAlbumListSort(scope, sort); return sort;
    }
    public async Task<SynologyPhotoAlbumDisplay> AlbumDisplayAsync(CancellationToken cancellationToken = default)
    {
        var data = await ReadAsync("Browse.Album", 3, "get_album_list_display", cancellationToken: cancellationToken, space: null).ConfigureAwait(false);
        return Text(data, "album_display_type") switch { "all_album" => SynologyPhotoAlbumDisplay.All, "my_album" => SynologyPhotoAlbumDisplay.Mine, _ => throw Invalid() };
    }
    public async Task<IReadOnlyList<SynologyPhotoCollection>> AlbumsAsync(int offset, int limit, SynologyPhotoAlbumDisplay display,
        SynologyPhotoAlbumListSort sort, CancellationToken cancellationToken = default)
    {
        ValidateAlbumListSort(SynologyPhotoAlbumListScope.Albums, sort); if (!Enum.IsDefined(display)) throw Invalid();
        var fields = PageParameters(offset, limit);
        Add(fields, Parameters(("category", display == SynologyPhotoAlbumDisplay.Mine ? "normal" : "normal_share_with_me"),
            ("sort_by", AlbumListField(sort.Field)), ("sort_direction", sort.Descending ? "desc" : "asc"), ("additional", new[] { "thumbnail", "sharing_info" })));
        return Collections(await ReadAsync("Browse.Album", 4, "list", fields, cancellationToken, null).ConfigureAwait(false), limit);
    }
    private async Task<JsonObject?> ReadAlbumRawAsync(long id, CancellationToken token)
    {
        RequirePositive(id);
        var raw = List(await ReadAsync("Browse.Album", 4, "get", Parameters(("id", new[] { id }),
            ("additional", new[] { "sharing_info", "thumbnail", "condition_object" })), token, null).ConfigureAwait(false));
        if (raw.Length > 1 || raw.Length == 1 && Positive(raw[0], "id") != id) throw Invalid();
        return raw.SingleOrDefault();
    }
    private static JsonNode? CanonicalAlbumJson(JsonNode? node) => node switch
    {
        JsonObject value => new JsonObject(value.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => new KeyValuePair<string, JsonNode?>(pair.Key, CanonicalAlbumJson(pair.Value)))),
        JsonArray values => new JsonArray(values.Select(CanonicalAlbumJson).ToArray()), _ => node?.DeepClone(),
    };
    private SynologyPhotoAlbum AlbumSnapshot(JsonObject raw)
    {
        if (_currentUserId is not > 0) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var additional = OptionalObject(raw, "additional");
        var sortBy = OptionalText(raw, "sort_by"); var direction = OptionalText(raw, "sort_direction");
        if (!string.IsNullOrEmpty(sortBy) && ParseSortField(sortBy) is null || !string.IsNullOrEmpty(direction) && SortDirection(direction) is null) throw Invalid();
        var revision = new JsonObject();
        foreach (var key in new[] { "id", "owner_user_id", "name", "type", "freeze_album", "item_count", "shared", "cant_migrate_condition" }) revision[key] = raw[key]?.DeepClone();
        revision["sharing"] = additional?["sharing_info"]?.DeepClone(); revision["condition"] = additional?["condition_object"]?.DeepClone();
        var result = new SynologyPhotoAlbum(Positive(raw, "id"), Positive(raw, "owner_user_id"), _currentUserId.Value, Text(raw, "name"),
            Text(raw, "type") == "condition", Permission(raw, "freeze_album"), PhotoTextHash(CanonicalAlbumJson(revision)!.ToJsonString()))
        {
            ProfileId = ProfileId, ItemCount = OptionalInt(raw, "item_count"), Shared = raw["shared"] is null ? null : Boolean(raw, "shared"),
            Sort = new(ParseSortField(sortBy) ?? SynologyPhotoSortField.TakenTime, SortDirection(direction) ?? false),
            CoverId = OptionalObject(additional ?? new(), "thumbnail") is { } cover ? Positive(cover, "unit_id") : null,
        };
        if (result.ItemCount < 0) throw Invalid(); return result;
    }
    public async Task<SynologyPhotoAlbum> AlbumAsync(long id, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration);
        var raw = await ReadAlbumRawAsync(id, cancellationToken).ConfigureAwait(false) ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var album = AlbumSnapshot(raw);
        if (!album.Conditional && !album.Frozen)
        {
            try { _ = await ReadContributingAlbumAsync(raw, cancellationToken).ConfigureAwait(false); album = album with { CanContribute = true }; }
            catch (SynologyPhotoException error) when (error.Failure is SynologyPhotoFailure.Permission or SynologyPhotoFailure.Unavailable) { }
        }
        RequireGeneration(generation, cancellationToken); return album;
    }
    private static bool SameAlbumIdentity(SynologyPhotoAlbum original, SynologyPhotoAlbum current) => original.Id == current.Id &&
        original.OwnerUserId == current.OwnerUserId && original.CurrentUserId == current.CurrentUserId && original.Name == current.Name &&
        original.Conditional == current.Conditional && original.Frozen == current.Frozen;
    private static bool AlbumNeedsName(SynologyPhotoAlbumEditKind kind) => kind is SynologyPhotoAlbumEditKind.Create or SynologyPhotoAlbumEditKind.Rename or SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Rebuild;
    private static bool AlbumNeedsCondition(SynologyPhotoAlbumEditKind kind) => kind is SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Condition or SynologyPhotoAlbumEditKind.Rebuild;
    private static bool AlbumCreates(SynologyPhotoAlbumEditKind kind) => kind is SynologyPhotoAlbumEditKind.Create or SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Rebuild;
    private static bool AlbumMembership(SynologyPhotoAlbumEditKind kind) => kind is SynologyPhotoAlbumEditKind.AddMembers or SynologyPhotoAlbumEditKind.RemoveMembers;
    private static void ValidateAlbumEdit(SynologyPhotoAlbumEdit edit, bool restored = false)
    {
        if (!Enum.IsDefined(edit.Kind) || edit.Photos is null || edit.Photos.Count > 100 ||
            edit.Photos.DistinctBy(photo => photo.Id.ItemId).Count() != edit.Photos.Count ||
            AlbumNeedsName(edit.Kind) && !restored && string.IsNullOrWhiteSpace(edit.Name) || edit.Name?.Contains('\0') == true) throw Invalid();
        var hasAlbum = edit.Kind is not (SynologyPhotoAlbumEditKind.Create or SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.ListSort or SynologyPhotoAlbumEditKind.ListDisplay);
        if (hasAlbum != (edit.Album is not null)) throw Invalid();
        if (edit.Album is { } album && (album.ProfileId == Guid.Empty || album.Id <= 0 || album.OwnerUserId <= 0 || album.CurrentUserId <= 0 || !UploadHash(album.Revision))) throw Invalid();
        if (AlbumMembership(edit.Kind) && edit.Photos.Count == 0 || edit.Kind == SynologyPhotoAlbumEditKind.Cover && edit.Photos.Count != 1 ||
            edit.Kind is not (SynologyPhotoAlbumEditKind.Create or SynologyPhotoAlbumEditKind.AddMembers or SynologyPhotoAlbumEditKind.RemoveMembers or SynologyPhotoAlbumEditKind.Cover) && edit.Photos.Count != 0) throw Invalid();
        if (edit.Kind == SynologyPhotoAlbumEditKind.Sort && (edit.Sort is null || !Enum.IsDefined(edit.Sort.Field) || edit.Album!.Sort is null)) throw Invalid();
        if (edit.Kind == SynologyPhotoAlbumEditKind.ListSort)
        {
            if (edit.OriginalListSort is null || edit.ListSort is null) throw Invalid();
            ValidateAlbumListSort(edit.Scope, edit.OriginalListSort); ValidateAlbumListSort(edit.Scope, edit.ListSort);
        }
        if (edit.Kind == SynologyPhotoAlbumEditKind.ListDisplay && (edit.OriginalDisplay is null || edit.Display is null ||
            !Enum.IsDefined(edit.OriginalDisplay.Value) || !Enum.IsDefined(edit.Display.Value))) throw Invalid();
        if (AlbumNeedsCondition(edit.Kind) && (restored ? edit.ConditionSpace is null || !Enum.IsDefined(edit.ConditionSpace.Value) : edit.Condition is null) ||
            edit.Kind == SynologyPhotoAlbumEditKind.Condition && !UploadHash(edit.OriginalConditionRevision)) throw Invalid();
        foreach (var photo in edit.Photos)
            if (photo.Id.ProfileId == Guid.Empty || photo.Id.ItemId <= 0 || !Enum.IsDefined(photo.Id.Space) || photo.FolderId <= 0 || photo.SizeBytes < 0) throw Invalid();
    }
    private (string Api, int Version, string Method) AlbumWriteRoute(SynologyPhotoAlbumEditKind kind) => kind switch
    {
        SynologyPhotoAlbumEditKind.Create => ("Browse.NormalAlbum", 1, "create"),
        SynologyPhotoAlbumEditKind.AddMembers => ("Browse.NormalAlbum", 1, "add_item"), SynologyPhotoAlbumEditKind.RemoveMembers => ("Browse.NormalAlbum", 1, "delete_item"),
        SynologyPhotoAlbumEditKind.Rename => ("Browse.Album", 1, "set_name"), SynologyPhotoAlbumEditKind.Delete => ("Browse.Album", 1, "delete"),
        SynologyPhotoAlbumEditKind.Cover => ("Browse.Album", 1, "set_cover"), SynologyPhotoAlbumEditKind.Sort => ("Browse.Album", 1, "set_order"),
        SynologyPhotoAlbumEditKind.CreateCondition or SynologyPhotoAlbumEditKind.Rebuild => ("Browse.ConditionAlbum", 3, "create"),
        SynologyPhotoAlbumEditKind.Condition => ("Browse.ConditionAlbum", 3, "set_condition"), SynologyPhotoAlbumEditKind.Unfreeze => ("Browse.NormalAlbum", 1, "set_unfreeze"),
        SynologyPhotoAlbumEditKind.ListSort => ("Browse.Album", 2, "set_album_list_order"), SynologyPhotoAlbumEditKind.ListDisplay => ("Browse.Album", 3, "set_album_list_display"), _ => throw Invalid(),
    };
    public async Task PrepareAlbumAsync(SynologyPhotoAlbumEdit edit, CancellationToken cancellationToken = default)
    {
        var record = CreateAlbumRecord(Guid.NewGuid(), edit); await LoadChangesAsync().ConfigureAwait(false);
        _ = await PrepareAlbumCoreAsync(record, cancellationToken, edit.Condition).ConfigureAwait(false);
    }
    private async Task<ContributingAlbum?> PrepareAlbumCoreAsync(PhotoAlbumChangeRecord record, CancellationToken token, SynologyPhotoCondition? condition = null)
    {
        CheckAlbumOwner(record); var edit = record.Edit; var generation = Volatile.Read(ref _accessGeneration);
        var sourceRequired = edit.Kind is SynologyPhotoAlbumEditKind.Create or SynologyPhotoAlbumEditKind.AddMembers;
        await FreshManagementAccessAsync(edit.ConditionSpace is { } conditionSpace ? [conditionSpace] : sourceRequired ? edit.Photos.Select(photo => photo.Id.Space).Distinct().ToArray() : [], token).ConfigureAwait(false);
        if (edit.Kind == SynologyPhotoAlbumEditKind.Delete && !AlbumSafety.Delete) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        if (edit.Kind == SynologyPhotoAlbumEditKind.Unfreeze && !AlbumSafety.Unfreeze || edit.Kind == SynologyPhotoAlbumEditKind.Rebuild && !AlbumSafety.Rebuild) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        var route = AlbumWriteRoute(edit.Kind); _ = Capability(route.Api, route.Version, null);
        await CheckAlbumConflictsAsync(record, token).ConfigureAwait(false);
        ContributingAlbum? rights = null;
        if (edit.Album is { } original)
        {
            var raw = await ReadAlbumRawAsync(original.Id, token).ConfigureAwait(false) ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var current = AlbumSnapshot(raw);
            if (!SameAlbumIdentity(original, current) || edit.Kind is SynologyPhotoAlbumEditKind.Delete or SynologyPhotoAlbumEditKind.Unfreeze or SynologyPhotoAlbumEditKind.Rebuild && original.Revision != current.Revision ||
                edit.Kind == SynologyPhotoAlbumEditKind.Sort && original.Sort != current.Sort) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (AlbumMembership(edit.Kind)) rights = await ReadContributingAlbumAsync(raw, token).ConfigureAwait(false);
            else if (edit.Kind != SynologyPhotoAlbumEditKind.Sort && !current.IsOwner) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
        if (edit.Kind == SynologyPhotoAlbumEditKind.ListSort && await AlbumListSortAsync(edit.Scope, token).ConfigureAwait(false) != edit.OriginalListSort ||
            edit.Kind == SynologyPhotoAlbumEditKind.ListDisplay && await AlbumDisplayAsync(token).ConfigureAwait(false) != edit.OriginalDisplay)
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        if (sourceRequired && edit.Photos.Any(photo => photo.AlbumContext is not null) && edit.Photos.Select(photo => photo.Id.Space).Distinct().Count() > 1 && !_managesSharedSpace)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        foreach (var photo in edit.Photos.Where(photo => record.Members.Single(item => item.Photo.Id == photo.Id).State != SynologyPhotoChangeState.Completed))
        {
            RequirePhoto(photo);
            if (sourceRequired) RequireAccess(photo.Id.Space);
            var current = await DetailsAsync(photo, token).ConfigureAwait(false);
            if (!photo.IsSameDeletionTarget(current) || photo.AlbumContext != current.AlbumContext) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (sourceRequired)
            {
                if (photo.AlbumContext is not null)
                { if (current.AlbumContext?.ProviderUserId != _currentUserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission); }
                else _ = await ReadPhotoFolderAsync(photo.FolderId, photo.Id.Space, photo.Id.Space == SynologyPhotoSpace.Shared ? PhotoFolderRight.Download : PhotoFolderRight.Manage, token).ConfigureAwait(false);
            }
            if (edit.Kind == SynologyPhotoAlbumEditKind.RemoveMembers && (photo.AlbumContext?.AlbumId != edit.Album!.Id ||
                !edit.Album.IsOwner && current.AlbumContext?.ProviderUserId != _currentUserId)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            await CheckManagedFolderConflictsAsync(photo.FolderId, photo.Id.Space, null, token).ConfigureAwait(false);
        }
        if (edit.Kind == SynologyPhotoAlbumEditKind.Cover && !(await AlbumMemberMatchesAsync(edit.Album!.Id, edit.Photos, token).ConfigureAwait(false))[0])
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        await PrepareConditionAlbumAsync(record, condition, token).ConfigureAwait(false);
        RequireGeneration(generation, token); CheckAlbumOwner(record); return rights;
    }
    private async Task<bool[]> AlbumMemberMatchesAsync(long id, IReadOnlyList<SynologyPhoto> photos, CancellationToken token, bool exact = false)
    {
        var found = new bool[photos.Count]; var seen = new HashSet<long>();
        for (var offset = 0; ;)
        {
            var page = await PhotosAsync(new SynologyPhotoQuery.Album(id), offset, 100, token).ConfigureAwait(false);
            foreach (var member in page.Items)
            {
                if (!seen.Add(member.Id.ItemId)) throw Invalid();
                if (exact && !photos.Any(photo => photo.Id.ItemId == member.Id.ItemId)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                for (var index = 0; index < photos.Count; index++)
                {
                    var photo = photos[index]; if (photo.Id.ItemId != member.Id.ItemId) continue;
                    var owner = photo.AlbumContext?.OwnerUserId ?? (photo.Id.Space == SynologyPhotoSpace.Shared ? 0 : _currentUserId);
                    if (photo.Id != member.Id || member.AlbumContext?.OwnerUserId != owner) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                    found[index] = true;
                }
            }
            if (!page.HasMore) return found;
            if (page.NextOffset <= offset) throw Invalid(); offset = page.NextOffset;
        }
    }
}
