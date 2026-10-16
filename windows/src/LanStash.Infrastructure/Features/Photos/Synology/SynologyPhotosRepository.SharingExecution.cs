using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task SendSharingStageAsync(PhotoSharingTask task, CancellationToken token)
    {
        var sent = false;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); var record = task.Record;
            var current = await PrepareSharingCoreAsync(record, task.Edit, token).ConfigureAwait(false);
            if (record.Stage == SynologyPhotoSharingStage.Close && !record.Configure && current.Access == record.Access &&
                (record.Access == SynologyPhotoLinkAccess.Disabled || current.Url is not null))
            {
                task.Record = record with { Stage = SynologyPhotoSharingStage.Finished, State = SynologyPhotoChangeState.Completed, Failure = null };
                task.Result = current; task.Edit = null; await SaveSharingAsync(task).ConfigureAwait(false); return;
            }
            var method = record.Stage == SynologyPhotoSharingStage.Configure ? "update" : "set_shared";
            Dictionary<string, string> fields;
            if (record.Stage == SynologyPhotoSharingStage.Configure)
            {
                var edit = task.Edit ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                var raw = await ReadAlbumRawAsync(record.AlbumId, token).ConfigureAwait(false) ?? throw Invalid();
                if (SharingSnapshot(raw).Revision != record.CurrentRevision) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                var info = OptionalObject(OptionalObject(raw, "additional") ?? new(), "sharing_info");
                var passphrase = OptionalText(info ?? new(), "passphrase") ?? task.Passphrase;
                if (string.IsNullOrEmpty(passphrase)) throw Invalid();
                fields = Parameters(("passphrase", passphrase)); var delta = SharingMemberDelta(edit);
                if (delta.Count > 0) Add(fields, Parameters(("permission", delta)));
                if (edit.Expiration is { } expiration && expiration != edit.Original.Expiration) Add(fields, Parameters(("expiration", expiration)));
                if (edit.PasswordChange != SynologyPhotoPasswordChange.Keep) Add(fields, Parameters(("password", edit.PasswordChange == SynologyPhotoPasswordChange.Clear ? "" : edit.Password!)));
            }
            else fields = Parameters(("policy", "album"), ("album_id", record.AlbumId), ("enabled", record.Stage == SynologyPhotoSharingStage.Open));
            task.Record = record with { State = SynologyPhotoChangeState.Submitting, Accepted = false, Failure = null };
            await SaveSharingAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckSharingOwner(record);
            // 持久化与读取之后再读当前身份/权限，防止取消、权限撤回或网页同时修改穿过提交边界。
            _ = await PrepareSharingCoreAsync(record, task.Edit, token).ConfigureAwait(false);
            sent = true;
            var receipt = await _api.WritePhotoAsync(_profile, _session, Capability("Sharing.Passphrase", 1, null), 1, method, fields, token).ConfigureAwait(false);
            task.Record = task.Record with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted, Failure = receipt.Failure };
            if (receipt.Status == SynologyPhotoWriteStatus.Accepted && record.Stage == SynologyPhotoSharingStage.Close)
                task.Passphrase = receipt.Data is { } data ? OptionalText(data, "passphrase") : null;
            await SaveSharingAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckSharingOwner(record);
            await ReviewSharingCoreAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore(); task.Record = task.Record with { State = sent ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, Failure = UploadFailure(error) };
            await SaveSharingAsync(task).ConfigureAwait(false);
        }
    }
    private async Task ReviewSharingCoreAsync(PhotoSharingTask task, CancellationToken token)
    {
        CheckSharingOwner(task.Record); var record = task.Record;
        if (record.State is not (SynologyPhotoChangeState.PendingReview or SynologyPhotoChangeState.Submitting) || !record.Accepted) return;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration);
            await FreshManagementAccessAsync([SynologyPhotoSpace.Personal], token).ConfigureAwait(false);
            var current = await AlbumSharingAsync(record.AlbumId, token).ConfigureAwait(false);
            if (ShareAlbumIdentity(current) != record.IdentityHash) return;
            var onlyClose = record.Access == SynologyPhotoLinkAccess.Disabled && !record.Configure;
            var expectedAccess = record.Stage == SynologyPhotoSharingStage.Open ? record.Access : SynologyPhotoLinkAccess.Disabled;
            if (current.Access != expectedAccess || !onlyClose && ShareConfigHash(current) !=
                (record.Stage == SynologyPhotoSharingStage.Close ? record.OriginalConfig : record.ExpectedConfig) ||
                record.Stage == SynologyPhotoSharingStage.Open && current.Url is null) return;
            var next = record.Stage switch
            {
                SynologyPhotoSharingStage.Close when record.Configure => SynologyPhotoSharingStage.Configure,
                SynologyPhotoSharingStage.Close or SynologyPhotoSharingStage.Configure when record.Access != SynologyPhotoLinkAccess.Disabled => SynologyPhotoSharingStage.Open,
                _ => SynologyPhotoSharingStage.Finished,
            };
            RequireGeneration(generation, token); CheckSharingOwner(record); task.Result = current;
            task.Record = record with { Stage = next, CurrentRevision = current.Revision, State = next == SynologyPhotoSharingStage.Finished ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Ready, Accepted = false, Failure = null };
            if (next is SynologyPhotoSharingStage.Open or SynologyPhotoSharingStage.Finished) { task.Edit = null; task.Passphrase = null; }
            await SaveSharingAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
}
