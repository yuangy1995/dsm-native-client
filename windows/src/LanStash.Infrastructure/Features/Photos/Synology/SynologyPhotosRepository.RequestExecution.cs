using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task SendRequestAsync(PhotoRequestTask task, CancellationToken token)
    {
        var sent = false;
        try
        {
            var record = task.Record; var generation = Volatile.Read(ref _accessGeneration);
            var (current, _) = await PrepareRequestCoreAsync(record, task.Edit, token).ConfigureAwait(false);
            var fields = record.Kind switch
            {
                SynologyPhotoRequestEditKind.Create => RequestParameters(task.Edit!.Settings!),
                SynologyPhotoRequestEditKind.Update => RequestDelta(current!.Settings, task.Edit!.Settings!),
                _ => Parameters(("passphrase", new[] { current!.Id })),
            };
            if (record.Kind == SynologyPhotoRequestEditKind.Update && fields.Count == 0)
            {
                if (!current!.IsFolderValid) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                task.Record = record with { State = SynologyPhotoChangeState.Completed, Failure = null }; task.Result = current; task.Edit = null;
                await SaveRequestAsync(task).ConfigureAwait(false); return;
            }
            if (record.Kind != SynologyPhotoRequestEditKind.Delete) Add(fields, Parameters(("passphrase", current?.Id ?? "")));
            task.Record = record with { State = SynologyPhotoChangeState.Submitting, Accepted = false, Failure = null };
            await SaveRequestAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckRequestOwner(record);
            _ = await PrepareRequestCoreAsync(record, task.Edit, token).ConfigureAwait(false);
            sent = true;
            var receipt = await _api.WritePhotoAsync(_profile, _session, Capability("PhotoRequest", 1, null), 1,
                record.Kind switch { SynologyPhotoRequestEditKind.Create => "create", SynologyPhotoRequestEditKind.Update => "update", _ => "delete" }, fields, token).ConfigureAwait(false);
            task.Record = task.Record with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted, Failure = receipt.Failure };
            if (record.Kind == SynologyPhotoRequestEditKind.Create && receipt.Status == SynologyPhotoWriteStatus.Accepted &&
                receipt.Data is { } data && OptionalText(data, "passphrase") is { Length: > 0 } id)
                task.Record = task.Record with { TargetHash = PhotoTextHash(id) };
            await SaveRequestAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckRequestOwner(record);
            await ReviewRequestCoreAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore(); task.Record = task.Record with { State = sent ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, Failure = UploadFailure(error) };
            await SaveRequestAsync(task).ConfigureAwait(false);
        }
    }
    private async Task ReviewRequestCoreAsync(PhotoRequestTask task, CancellationToken token)
    {
        var record = task.Record; CheckRequestOwner(record);
        if (record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
        {
            if (record.TargetHash is not null && task.Result is null)
            {
                try
                {
                    var original = await FindPhotoRequestAsync(record.TargetHash, token).ConfigureAwait(false);
                    if (original is not null && RequestSnapshotHash(original) == record.OriginalHash) task.Result = original;
                }
                catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
            }
            return;
        }
        var completed = record.State == SynologyPhotoChangeState.Completed;
        if (completed ? task.Result is not null || record.Kind == SynologyPhotoRequestEditKind.Delete :
            record.State is not (SynologyPhotoChangeState.PendingReview or SynologyPhotoChangeState.Submitting) || !record.Accepted) return;
        if (record.TargetHash is null) return;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration);
            await FreshManagementAccessAsync([_personalAllowed ? SynologyPhotoSpace.Personal : SynologyPhotoSpace.Shared], token).ConfigureAwait(false);
            var current = await FindPhotoRequestAsync(record.TargetHash, token).ConfigureAwait(false);
            if (record.Kind == SynologyPhotoRequestEditKind.Delete ? current is not null : current is null || !current.IsFolderValid ||
                RequestSettingsHash(current.Settings, record.IgnoreFolderId) != record.ExpectedHash || record.Kind == SynologyPhotoRequestEditKind.Create && current.Url is null) return;
            RequireGeneration(generation, token); CheckRequestOwner(record);
            task.Record = record with { State = SynologyPhotoChangeState.Completed, Failure = null }; task.Result = current; task.Edit = null;
            await SaveRequestAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
    private async Task CheckRequestFolderLocksAsync(SynologyPhotoFolder folder, CancellationToken token)
    {
        var records = _changes.Requests.Values.Where(task => task.Record.Owner == UploadOwner() && ActiveRequest(task.Record)).Select(task => task.Record).ToArray();
        // 默认目录可能已经随未知创建出现；仅保存路径祖先摘要，也要阻止其被改名或清理。
        var pathHash = PhotoTextHash(folder.Path);
        if (records.SelectMany(record => record.Paths).Any(path => path.Space == folder.Space && path.Ancestors.Contains(pathHash)))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        var ids = records.SelectMany(record => record.Folders).Where(target => target.Space == folder.Space).Select(target => target.Id).Distinct();
        foreach (var id in ids)
        {
            if (id == folder.Id) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            var current = PhotoFolder(await ReadPhotoFolderAsync(id, folder.Space, PhotoFolderRight.View, token).ConfigureAwait(false), folder.Space);
            if (FolderContains(folder.Path, current.Path)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        }
    }
}
