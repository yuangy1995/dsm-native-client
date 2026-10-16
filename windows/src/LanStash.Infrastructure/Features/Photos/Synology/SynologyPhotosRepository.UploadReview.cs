using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public async Task<SynologyPhotoUploadBatch> ReviewUploadAsync(Guid batchId, CancellationToken cancellationToken = default)
    {
        await LoadUploadsAsync().ConfigureAwait(false); var task = OwnedUpload(batchId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return UploadSnapshot(task);
        try { await ReviewUploadCoreAsync(task, cancellationToken).ConfigureAwait(false); }
        finally { task.Gate.Release(); }
        return UploadSnapshot(task);
    }
    private async Task ReviewUploadCoreAsync(PhotoUploadTask task, CancellationToken token)
    {
        for (var index = 0; index < task.Record.Items.Length; index++)
            if (task.Record.Items[index].State == SynologyPhotoUploadState.PendingReview)
                await ReviewUploadEntryAsync(task, index, token).ConfigureAwait(false);
    }
    private async Task ReviewUploadEntryAsync(PhotoUploadTask task, int index, CancellationToken token)
    {
        var entry = task.Record.Items[index];
        if (entry.State != SynologyPhotoUploadState.PendingReview) return;
        try
        {
            if (task.Record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            switch (entry.Step)
            {
                case SynologyPhotoUploadStep.CreateFolder when entry.Accepted && entry.ReceiptId is { } id:
                    var folder = await WritableUploadFolderAsync(id, task.Record.Target.Space, token).ConfigureAwait(false);
                    if (folder.ParentId != entry.FolderParent || folder.Name != entry.FolderName) return;
                    var directory = new PhotoUploadFolder(entry.FolderParent!.Value, entry.FolderName!, id);
                    if (task.Record.Folders.Any(existing => existing.Parent == directory.Parent && existing.Name == directory.Name && existing.Id != id)) return;
                    task.Record = task.Record with { Folders = task.Record.Folders.Append(directory).Distinct().ToArray() };
                    await SetUploadEntryAsync(task, index, entry with { State = SynologyPhotoUploadState.Queued,
                        Step = SynologyPhotoUploadStep.None, FolderId = id, ReceiptId = null, Accepted = false }).ConfigureAwait(false);
                    break;
                case SynologyPhotoUploadStep.Upload when entry.Accepted && entry.ReceiptId is { } itemId:
                    var target = task.Record.Target;
                    var fields = Parameters(("id", new[] { itemId }), ("additional", new[] { "thumbnail", "resolution", "orientation", "provider_user_id" }));
                    if (target.DirectToAlbum) Add(fields, Parameters(("album_id", target.AlbumId!.Value)));
                    var payload = await ReadAsync("Browse.Item", 5, "get", fields, token, target.DirectToAlbum ? null : target.Space).ConfigureAwait(false);
                    var entries = List(payload);
                    if (entries.Length != 1) return;
                    var photo = Photo(entries[0], ProfileId, target.Space, target.DirectToAlbum ? target.AlbumId : null);
                    if (photo.Id.ItemId != itemId || photo.FolderId <= 0 || entry.FolderId is { } expectedFolder && photo.FolderId != expectedFolder) return;
                    var ignored = entry.UploadAction == "ignore";
                    if (ignored ? photo.Filename != entry.File.Name : photo.SizeBytes != entry.File.Length) return;
                    if (target.DirectToAlbum && !ignored && photo.AlbumContext?.ProviderUserId != _currentUserId) return;
                    // 恢复只保留目标身份与后续入册所需快照，不保存描述、位置或媒体缓存。
                    photo = new(photo.Id, photo.Filename, photo.SizeBytes, photo.TakenAt, photo.IndexedAt, photo.FolderId, photo.MediaType)
                        { AlbumContext = photo.AlbumContext };
                    var state = !target.DirectToAlbum && target.AlbumId is not null ? SynologyPhotoUploadState.Uploaded : UploadCompletedState(entry);
                    await SetUploadEntryAsync(task, index, entry with { State = state, Photo = photo, Step = SynologyPhotoUploadStep.None }).ConfigureAwait(false);
                    break;
                case SynologyPhotoUploadStep.AddToAlbum when entry.Accepted && entry.Photo is { } uploaded:
                    var present = await UploadAlbumContainsAsync(task.Record.Target.AlbumId!.Value, uploaded, token).ConfigureAwait(false);
                    if (present) await SetUploadEntryAsync(task, index, entry with { State = UploadCompletedState(entry), Step = SynologyPhotoUploadStep.None }).ConfigureAwait(false);
                    else if (entry.Rejected) await SetUploadEntryAsync(task, index, entry with { State = SynologyPhotoUploadState.Failed,
                        Failure = SynologyPhotoFailure.WriteFailed }).ConfigureAwait(false);
                    break;
            }
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception error) when (error is SynologyPhotoException or DsmException or IOException or HttpRequestException or ObjectDisposedException)
        { RequireUploadStore(); /* 读取失败保留先前事实；只读刷新不会补发任何写请求。 */ }
    }
    private async Task<bool> UploadAlbumContainsAsync(long albumId, SynologyPhoto photo, CancellationToken token)
    {
        var found = false; var seen = new HashSet<long>();
        for (var offset = 0; ;)
        {
            var page = await PhotosAsync(new SynologyPhotoQuery.Album(albumId), offset, 100, token).ConfigureAwait(false);
            foreach (var member in page.Items)
            {
                if (!seen.Add(member.Id.ItemId)) throw Invalid();
                if (member.Id != photo.Id) continue;
                var owner = photo.AlbumContext?.OwnerUserId ?? (photo.Id.Space == SynologyPhotoSpace.Shared ? 0 : _currentUserId);
                if (member.AlbumContext?.OwnerUserId != owner) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                found = true;
            }
            if (!page.HasMore) return found;
            if (page.NextOffset <= offset) throw Invalid(); offset = page.NextOffset;
        }
    }
}
