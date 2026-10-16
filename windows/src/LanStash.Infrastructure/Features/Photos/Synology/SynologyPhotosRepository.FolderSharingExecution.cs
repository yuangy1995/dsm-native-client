using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task SendFolderSharingStageAsync(PhotoFolderSharingTask task, CancellationToken token)
    {
        var sent = false;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); var record = task.Record;
            _ = await PrepareFolderSharingCoreAsync(record, task.Edit, token).ConfigureAwait(false);
            var method = record.Stage == SynologyPhotoFolderSharingStage.Permissions ? "update" : "set_config";
            var fields = Parameters(("set_to_subfolder", record.Apply));
            if (record.Stage == SynologyPhotoFolderSharingStage.Permissions)
            {
                var edit = task.Edit ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                Add(fields, Parameters(("folder_id", record.FolderId), ("privacy_type", edit.Access switch
                { SynologyPhotoFolderAccess.Management => "management", SynologyPhotoFolderAccess.Invited => "private", SynologyPhotoFolderAccess.View => "public-view", _ => "public-download" })));
                var delta = FolderPermissionDelta(edit); if (delta.Count > 0) Add(fields, Parameters(("permission", delta)));
                if (edit.PasswordChange != SynologyPhotoPasswordChange.Keep)
                    Add(fields, Parameters(("password", edit.PasswordChange == SynologyPhotoPasswordChange.Clear ? "" : edit.Password!)));
            }
            task.Record = record with { State = SynologyPhotoChangeState.Submitting, Accepted = false, Failure = null };
            await SaveFolderSharingAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckFolderSharingOwner(record);
            _ = await PrepareFolderSharingCoreAsync(record, task.Edit, token).ConfigureAwait(false);
            sent = true;
            var receipt = await _api.WritePhotoAsync(_profile, _session, Capability("Sharing.FolderPermission", 1, SynologyPhotoSpace.Shared), 1, method, fields, token).ConfigureAwait(false);
            task.Record = task.Record with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted, Failure = receipt.Failure };
            await SaveFolderSharingAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckFolderSharingOwner(record);
            await ReviewFolderSharingCoreAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore(); task.Record = task.Record with { State = sent ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, Failure = UploadFailure(error) };
            await SaveFolderSharingAsync(task).ConfigureAwait(false);
        }
    }
    private async Task ReviewFolderSharingCoreAsync(PhotoFolderSharingTask task, CancellationToken token)
    {
        CheckFolderSharingOwner(task.Record); var record = task.Record;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration);
            await FreshManagementAccessAsync([SynologyPhotoSpace.Shared], token).ConfigureAwait(false);
            var current = await ReadFolderSharingAsync(record.FolderId, token).ConfigureAwait(false);
            if (FolderSharingIdentity(current) != record.IdentityHash || current.ParentIsShared != record.ParentIsShared) return;
            RequireGeneration(generation, token); CheckFolderSharingOwner(record); task.Result = current;
            if (record.State is not (SynologyPhotoChangeState.PendingReview or SynologyPhotoChangeState.Submitting) || !record.Accepted ||
                FolderPermissionHash(current) != record.ExpectedHash) return;
            if (record.Stage == SynologyPhotoFolderSharingStage.DefaultOption && current.AppliesToSubfolders != record.Apply) return;
            // update 回执只证明 NAS 接受了子目录操作；不声称逐后代行为已经验收。
            var next = record.Stage == SynologyPhotoFolderSharingStage.Permissions && record.Apply != record.PreviousApply
                ? SynologyPhotoFolderSharingStage.DefaultOption : SynologyPhotoFolderSharingStage.Finished;
            if (next == SynologyPhotoFolderSharingStage.DefaultOption && current.AppliesToSubfolders != record.PreviousApply) return;
            task.Record = record with { Stage = next, CurrentRevision = current.Revision, PermissionsSaved = true,
                State = next == SynologyPhotoFolderSharingStage.Finished ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Ready, Accepted = false, Failure = null };
            task.Edit = null; await SaveFolderSharingAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
}
