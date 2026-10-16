using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private bool SupportsSimilar(SynologyPhotoSpace space)
    {
        try { foreach (var name in new[] { "Browse.Similar", "Browse.SimilarItem", "Browse.SimilarTimeline" }) _ = Capability(name, 1, space); return true; }
        catch (SynologyPhotoException error) when (error.Failure == SynologyPhotoFailure.Unavailable) { return false; }
    }
    private void RequireSimilarAccess(SynologyPhotoSpace space)
    {
        RequireCategoryAccess(SynologyPhotoCategory.Similar, space);
        if (!SupportsSimilar(space)) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
    }
    public bool SupportsSimilarManagement(SynologyPhotoSpace space)
    {
        try { RequireSimilarAccess(space); return SupportsRecognitionManagement; }
        catch (SynologyPhotoException) { return false; }
    }
    private async Task FreshSimilarAccessAsync(SynologyPhotoSpace space, CancellationToken token)
    {
        RequireSimilarAccess(space);
        var info = await ReadAsync("UserInfo", 1, "me", cancellationToken: token, space: null).ConfigureAwait(false);
        var user = await ReadAsync("Setting.User", 1, "get", cancellationToken: token, space: null).ConfigureAwait(false);
        if (!Boolean(info, "enabled") || Positive(info, "id") != _currentUserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (space == SynologyPhotoSpace.Personal)
        {
            if (!Boolean(user, "enable_home_service") || !Permission(user, "enable_similar")) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
        else
        {
            var team = await ReadAsync("Setting.TeamSpace", 1, "get", cancellationToken: token, space: null).ConfigureAwait(false);
            if (!Boolean(team, "enabled") || !Permission(team, "enable_similar") || Text(user, "team_space_permission") != "management") throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
        if (!(await CategoriesAsync(token, space).ConfigureAwait(false)).Contains(SynologyPhotoCategory.Similar)) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
    }
    public async Task<SynologyPhotoSimilarStatus> SimilarStatusAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        RequireSimilarAccess(space);
        var data = await ReadAsync("Browse.Similar", 1, "get_status", cancellationToken: cancellationToken, space: space).ConfigureAwait(false);
        var count = Int(data, "waiting_count"); var stage = Text(data, "similar_clustering_stage");
        if (count < 0 || string.IsNullOrWhiteSpace(stage)) throw Invalid();
        return new(count, stage, Boolean(data, "is_similar_hash_migration_done"));
    }
    private async Task<SynologyPhotoSimilarGroup?> CurrentSimilarAsync(long id, SynologyPhotoSpace space, CancellationToken token)
    {
        RequirePositive(id); RequireSimilarAccess(space);
        var values = List(await ReadAsync("Browse.Similar", 1, "get", Parameters(("id", new[] { id })), token, space).ConfigureAwait(false));
        if (values.Length > 1 || values.Length == 1 && Positive(values[0], "id") != id) throw Invalid();
        return values.Length == 0 ? null : SimilarGroup(values[0], space);
    }
    private async Task<SynologyPhoto[]> SimilarOriginalsAsync(SynologyPhotoSimilarGroup group, bool memberships, CancellationToken token)
    {
        RequireSimilarAccess(group.Space);
        var data = await ReadAsync(memberships ? "Browse.SimilarItem" : "Browse.Item", memberships ? 1 : 5, "get",
            Parameters(("id", group.PhotoIds), ("additional", memberships ? new[] { "thumbnail", "resolution", "orientation" } :
                new[] { "folder", "thumbnail", "resolution", "orientation", "video_convert", "video_meta" })), token, group.Space).ConfigureAwait(false);
        var photos = List(data).Select(raw => Photo(raw, ProfileId, group.Space)).ToArray();
        if (photos.Length != group.Count || photos.DistinctBy(photo => photo.Id).Count() != group.Count ||
            !photos.Select(photo => photo.Id.ItemId).ToHashSet().SetEquals(group.PhotoIds)) throw Invalid();
        return group.PhotoIds.Select(id => photos.Single(photo => photo.Id.ItemId == id)).ToArray();
    }
    public async Task<SynologyPhotoSimilarDetail?> SimilarGroupAsync(long id, SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration); RequireSimilarAccess(space);
        var group = await CurrentSimilarAsync(id, space, cancellationToken).ConfigureAwait(false);
        if (group is null) return null;
        var photos = await SimilarOriginalsAsync(group, false, cancellationToken).ConfigureAwait(false);
        if (!group.Matches(await CurrentSimilarAsync(id, space, cancellationToken).ConfigureAwait(false))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        RequireGeneration(generation, cancellationToken);
        return new(group, photos.Select(photo => photo with { SimilarGroup = group }).ToArray());
    }
    public async Task<IReadOnlyList<SynologyPhoto>> SimilarCleanupAsync(SynologyPhotoSimilarDetail detail, IReadOnlyList<long> keep, CancellationToken cancellationToken = default)
    {
        if (!CanDeleteOriginals || keep.Count == 0 || keep.Count >= detail.Group.Count || keep.Distinct().Count() != keep.Count || keep.Any(id => !detail.Group.PhotoIds.Contains(id)))
            throw new SynologyPhotoException(SynologyPhotoFailure.DeleteDenied);
        var edit = new SynologyPhotoRecognitionEdit(SynologyPhotoRecognitionKind.SimilarUngroup, []) { Space = detail.Group.Space, SimilarGroups = [detail] };
        var record = SimilarRecognitionRecord(Guid.NewGuid(), edit); await LoadChangesAsync().ConfigureAwait(false);
        await PrepareSimilarStepAsync(record, record.Similar![0], cancellationToken, requireWriteSafety: false).ConfigureAwait(false);
        return detail.Photos.Where(photo => !keep.Contains(photo.Id.ItemId)).ToArray();
    }
}
