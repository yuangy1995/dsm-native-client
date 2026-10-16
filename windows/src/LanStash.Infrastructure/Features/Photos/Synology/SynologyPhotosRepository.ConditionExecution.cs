using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task<SynologyPhotoAlbum?> MatchingConditionAlbumAsync(PhotoAlbumChangeTask task, CancellationToken token)
    {
        var edit = task.Record.Edit; var id = AlbumCreates(edit.Kind) ? task.Record.CreatedId : edit.Album?.Id;
        if (id is null || edit.Kind == SynologyPhotoAlbumEditKind.Rebuild && id == edit.Album!.Id) return null;
        var actual = await AlbumConditionAsync(id.Value, token).ConfigureAwait(false); var album = actual.Album;
        if (!album.IsOwner || actual.Revision != task.Record.ConditionHash || actual.Condition.Space != edit.ConditionSpace) return null;
        if (AlbumCreates(edit.Kind)) return album.Shared == false && PhotoTextHash(album.Name) == task.Record.NameHash ? album : null;
        return album.OwnerUserId == edit.Album!.OwnerUserId && album.CurrentUserId == edit.Album.CurrentUserId && album.Name == edit.Album.Name ? album : null;
    }
    private async Task ReviewConditionAlbumAsync(PhotoAlbumChangeTask task, CancellationToken token)
    {
        if (task.Record.State is SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled || !task.Record.Accepted) return;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); var edit = task.Record.Edit;
            await FreshManagementAccessAsync(edit.ConditionSpace is { } space ? [space] : [], token).ConfigureAwait(false);
            SynologyPhotoAlbum? result;
            if (edit.Kind == SynologyPhotoAlbumEditKind.Unfreeze)
            {
                var raw = await ReadAlbumRawAsync(edit.Album!.Id, token).ConfigureAwait(false); if (raw is null) return;
                result = AlbumSnapshot(raw);
                if (raw["freeze_album"] is null || Boolean(raw, "freeze_album") || result.Conditional || !result.IsOwner ||
                    result.OwnerUserId != edit.Album.OwnerUserId || result.Name != edit.Album.Name || result.ItemCount is null || result.ItemCount != edit.Album.ItemCount) return;
            }
            else
            {
                result = await MatchingConditionAlbumAsync(task, token).ConfigureAwait(false); if (result is null) return;
                if (edit.Kind == SynologyPhotoAlbumEditKind.Rebuild)
                {
                    RequireGeneration(generation, token); CheckAlbumOwner(task.Record); task.Result = result;
                    task.Record = task.Record with { ReplacementVerified = true };
                    if (!task.Record.CleanupSent || task.Record.CleanupRejected)
                    {
                        // 恢复和定时查询只记录已建成的新相册，旧相册清理由显式继续动作提交。
                        task.Record = task.Record with { State = task.Record.CleanupRejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Ready };
                        await SaveAlbumChangeAsync(task).ConfigureAwait(false); return;
                    }
                    if (!task.Record.CleanupAccepted) { await SaveAlbumChangeAsync(task).ConfigureAwait(false); return; }
                    if (await ReadAlbumRawAsync(edit.Album!.Id, token).ConfigureAwait(false) is not null) return;
                }
            }
            RequireGeneration(generation, token); CheckAlbumOwner(task.Record); task.Result = result;
            task.Record = task.Record with { State = SynologyPhotoChangeState.Completed, Failure = null }; await SaveAlbumChangeAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
    private async Task SendFrozenCleanupAsync(PhotoAlbumChangeTask task, CancellationToken token)
    {
        if (!AlbumCanContinue(task) || !task.Record.ReplacementVerified || task.Record.Edit.Kind != SynologyPhotoAlbumEditKind.Rebuild) return;
        var sent = false;
        try
        {
            CheckAlbumOwner(task.Record); if (!AlbumSafety.Rebuild) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
            var generation = Volatile.Read(ref _accessGeneration);
            await FreshManagementAccessAsync([task.Record.Edit.ConditionSpace!.Value], token).ConfigureAwait(false);
            var created = await MatchingConditionAlbumAsync(task, token).ConfigureAwait(false) ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var original = task.Record.Edit.Album!; var old = await FrozenAlbumAsync(original.Id, token).ConfigureAwait(false);
            if (old.Album.Revision != original.Revision) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            await CheckAlbumConflictsAsync(task.Record, token).ConfigureAwait(false);
            await CheckAlbumBusyAsync(created.Id, token, task.Record.Id).ConfigureAwait(false);
            var capability = Capability("Browse.Album", 1, null);
            task.Record = task.Record with { State = SynologyPhotoChangeState.Submitting, CleanupSent = true, CleanupAccepted = false, CleanupRejected = false, Failure = null };
            await SaveAlbumChangeAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckAlbumOwner(task.Record);
            sent = true;
            var receipt = await _api.WritePhotoAsync(_profile, _session, capability, 1, "delete", Parameters(("id", new[] { original.Id })), token).ConfigureAwait(false);
            task.Record = task.Record with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                CleanupAccepted = receipt.Status == SynologyPhotoWriteStatus.Accepted, CleanupRejected = receipt.Status == SynologyPhotoWriteStatus.Rejected, Failure = receipt.Failure };
            await SaveAlbumChangeAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckAlbumOwner(task.Record);
            await ReviewConditionAlbumAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore(); task.Record = task.Record with { State = sent ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, Failure = UploadFailure(error) };
            await SaveAlbumChangeAsync(task).ConfigureAwait(false);
        }
    }
}
