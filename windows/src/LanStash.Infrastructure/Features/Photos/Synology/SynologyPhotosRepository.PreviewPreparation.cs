using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private readonly ISynologyPhotoPreviewConverter _previewConverter;
    private sealed record PreviewQueueEntry(long UnitId, string Filename, string Type);
    public bool SupportsPreviewGeneration(SynologyPhotoSpace space)
    {
        if (!SupportsManagement) return false;
        try { RequireAccess(space); _ = Capability("RegeneratePreview", 1, space); return true; }
        catch (SynologyPhotoException) { return false; }
    }
    private static PreviewQueueEntry[] PreviewQueue(JsonObject data)
    {
        var list = List(data).Select(value => new PreviewQueueEntry(Positive(value, "unit_id"), Text(value, "filename"), Text(value, "type"))).ToArray();
        if (list.Any(item => string.IsNullOrWhiteSpace(item.Filename) || item.Type is not ("photo" or "video" or "live")) ||
            list.DistinctBy(item => item.UnitId).Count() != list.Length) throw Invalid();
        return list;
    }
    private async Task<PreviewQueueEntry[]> PreviewQueueAsync(SynologyPhotoSpace space, CancellationToken token)
    {
        RequireAccess(space); var generation = Volatile.Read(ref _accessGeneration);
        var result = PreviewQueue(await ReadAsync("RegeneratePreview", 1, "list_regenerating", cancellationToken: token, space: space).ConfigureAwait(false));
        RequireGeneration(generation, token); return result;
    }
    private static void RequireQueuedPreview(SynologyPhoto photo, IReadOnlyList<PreviewQueueEntry> queue)
    {
        if (!queue.Any(item => item.UnitId == photo.Id.ItemId && item.Filename == photo.Filename && item.Type == photo.MediaType))
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
    }
    public async Task<IReadOnlyList<SynologyPhoto>> PendingPreviewGenerationsAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration); await FreshManagementAccessAsync([space], cancellationToken).ConfigureAwait(false);
        var queue = await PreviewQueueAsync(space, cancellationToken).ConfigureAwait(false); var result = new List<SynologyPhoto>();
        foreach (var item in queue)
        {
            var entries = List(await ReadAsync("Browse.Item", 5, "get", Parameters(("id", new[] { item.UnitId }),
                ("additional", new[] { "thumbnail", "resolution", "orientation" })), cancellationToken, space).ConfigureAwait(false));
            if (entries.Length != 1) throw Invalid();
            var photo = Photo(entries[0], ProfileId, space); RequireQueuedPreview(photo, [item]);
            if (photo.FolderId <= 0 || photo.SizeBytes < 0) throw Invalid();
            await AuthorizePreviewPhotoAsync(photo, cancellationToken).ConfigureAwait(false); result.Add(photo);
        }
        RequireGeneration(generation, cancellationToken); return result;
    }
    private async Task AuthorizePreviewPhotoAsync(SynologyPhoto photo, CancellationToken token)
    {
        RequirePhoto(photo); RequireAccess(photo.Id.Space);
        if (photo.AlbumContext is { } context)
        {
            var album = await ManagementAlbumAsync(context.AlbumId, token).ConfigureAwait(false);
            // 相册贡献资格与原件所有权分开。其他共享提供者只开放全空间管理角色。
            if (_currentUserId is not > 0) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            if (context.ProviderUserId == _currentUserId) return;
            if (photo.Id.Space == SynologyPhotoSpace.Shared)
            {
                if (!_managesSharedSpace) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            }
            else if (context.OwnerUserId != _currentUserId || Text(album, "type") != "condition" && !Permission(album, "freeze_album"))
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            _ = await ManagedPhotoFolderAsync(photo.FolderId, photo.Id.Space, true, token).ConfigureAwait(false); return;
        }
        if (photo.Id.Space == SynologyPhotoSpace.Personal)
        { _ = await ManagedPhotoFolderAsync(photo.FolderId, photo.Id.Space, true, token).ConfigureAwait(false); return; }
        var folder = await ReadPhotoFolderAsync(photo.FolderId, photo.Id.Space, PhotoFolderRight.View, token).ConfigureAwait(false);
        var access = OptionalObject(OptionalObject(folder, "additional") ?? new(), "access_permission");
        if (!_managesSharedSpace && !Permission(access, "manage") && !Permission(access, "download"))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private async Task<SynologyPhoto> PreviewOriginalAsync(SynologyPhoto original, CancellationToken token)
    {
        RequirePhoto(original); RequireAccess(original.Id.Space);
        var current = await DetailsAsync(original, token).ConfigureAwait(false);
        if (!original.IsSameDeletionTarget(current) || original.AlbumContext != current.AlbumContext)
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        await AuthorizePreviewPhotoAsync(current, token).ConfigureAwait(false); return current;
    }
    private PhotoPreviewRecord PreviewRecord(Guid id, SynologyPhotoPreviewGenerationRequest request)
    {
        if (id == Guid.Empty || request.Photos is not { Count: > 0 and <= 100 } || request.Photos.DistinctBy(photo => photo.Id).Count() != request.Photos.Count) throw Invalid();
        foreach (var photo in request.Photos)
        {
            RequirePhoto(photo); RequireAccess(photo.Id.Space);
            if (photo.FolderId <= 0 || photo.SizeBytes < 0 || string.IsNullOrWhiteSpace(photo.Filename) ||
                !photo.SupportsPreviewGeneration) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        }
        var items = request.Photos.Select(photo => new PhotoPreviewEntry(MinimalManagedPhoto(photo))).ToArray();
        var fingerprint = PhotoTextHash(JsonSerializer.Serialize(new { request.Resuming, Photos = items.Select(item => item.Original) }));
        return new(id, ProfileId, UploadOwner(), fingerprint, request.Resuming, items);
    }
    private async Task<PhotoPreviewRecord> PreparePreviewRecordAsync(PhotoPreviewRecord record, CancellationToken token)
    {
        CheckPreviewOwner(record); var generation = Volatile.Read(ref _accessGeneration);
        var spaces = record.Items.Select(item => item.Original.Id.Space).Distinct().ToArray();
        await FreshManagementAccessAsync(spaces, token).ConfigureAwait(false);
        if (spaces.Length > 1 && !_managesSharedSpace) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var items = record.Items.ToArray();
        for (var index = 0; index < items.Length; index++)
        {
            var entry = items[index]; if (!ActivePreview(entry)) continue;
            var photo = entry.Original; _ = Capability("RegeneratePreview", 1, photo.Id.Space);
            await CheckPreviewLocksAsync(record.Id, photo, token).ConfigureAwait(false);
            var current = await PreviewOriginalAsync(photo, token).ConfigureAwait(false);
            if (record.Resuming || entry.Marked) RequireQueuedPreview(photo, await PreviewQueueAsync(photo.Id.Space, token).ConfigureAwait(false));
            if (entry.State == SynologyPhotoChangeState.Ready && !entry.Marking && !entry.Marked)
                items[index] = entry with { Baseline = current.Thumbnail };
        }
        RequireGeneration(generation, token); CheckPreviewOwner(record); return record with { Items = items };
    }
    private async Task CheckPreviewLocksAsync(Guid except, SynologyPhoto photo, CancellationToken token)
    {
        if (photo.AlbumContext is { } album) await CheckAlbumBusyAsync(album.AlbumId, token, except).ConfigureAwait(false);
        if (PreviewPhotoBusy(photo.Id, except) || FilePhotoBusy(photo.Id) || AlbumPhotoBusy(photo.Id) || RecognitionPhotoBusy(photo.Id) ||
            _changes.Tasks.Values.Any(task => task.Record.Owner == UploadOwner() && task.Record.Items.Any(item => item.Original.Id == photo.Id &&
                item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled))))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        await CheckManagedFolderConflictsAsync(photo.FolderId, photo.Id.Space, null, token, exceptPreview: except).ConfigureAwait(false);
    }
}
