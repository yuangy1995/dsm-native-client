using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanControlTask(FileBackgroundTaskSummary task, FileBackgroundTaskAction action)
    {
        var (api, version) = FileTaskApi(task.Kind);
        return IsFileBackgroundTaskAvailable && Enum.IsDefined(action) && Enum.IsDefined(task.Kind) &&
            NormalizeFileBackgroundTaskId(task.Id) == task.Id && task.CreationTimestamp is > 0 && task.Method == "start" &&
            task.ApiVersion == version && (action == FileBackgroundTaskAction.Clear
                ? task.State == FileBackgroundTaskState.Finished : task.State == FileBackgroundTaskState.Active && HasFixedCapability(api, version));
    }

    public async Task<FileBackgroundTaskProgress> ControlTaskAsync(FileBackgroundTaskChange change, CancellationToken token = default)
    {
        FileBackgroundTaskProgress Reject(MutationErrorCategory error, bool sent = false) => FileTaskResult(change,
            error == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : error == MutationErrorCategory.Unsupported ? MutationResultStatus.Unsupported : MutationResultStatus.ConfirmedFailure, sent, error);
        if (change.RequestId == Guid.Empty || change.ProfileId != ProfileId || !change.Confirmed) return Reject(MutationErrorCategory.Validation);
        if (token.IsCancellationRequested) return FileTaskResult(change, MutationResultStatus.CancelledBeforeSubmission, false);
        var shared = ServiceMutations;
        if (!await shared.Gate.WaitAsync(0, CancellationToken.None).ConfigureAwait(false)) return Reject(MutationErrorCategory.Conflict);
        try
        {
            var scope = ServiceScope();
            if (shared.FileBackgroundControls.TryGetValue((scope, change.RequestId), out var prior))
                return prior.Change == change ? await ReviewFileTaskCore(prior, token).ConfigureAwait(false) : Reject(MutationErrorCategory.Conflict);
            if (shared.FileBackgroundControls.Any(p => p.Key.Scope == scope && !p.Value.Complete && p.Value.Change.Task.Id == change.Task.Id)) return Reject(MutationErrorCategory.Conflict);
            if (!CanControlTask(change.Task, change.Action)) return Reject(MutationErrorCategory.Unsupported);
            try
            {
                // 当前账号可见的完整列表与原身份一起作为操作范围；不额外要求管理员。
                var tasks = await ReadCompleteFileTasks(token).ConfigureAwait(false);
                var current = tasks.SingleOrDefault(t => t.Id == change.Task.Id);
                if (current is null || !change.Task.SameIdentity(current) || current.State != change.Task.State)
                    return Reject(MutationErrorCategory.Conflict);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return FileTaskResult(change, MutationResultStatus.CancelledBeforeSubmission, false); }
            catch (DsmException e) { return Reject(ServiceErrorCategory(e)); }
            catch (InvalidDataException) { return Reject(MutationErrorCategory.Conflict); }
            catch { return Reject(MutationErrorCategory.Network); }
            var pending = new PendingFileBackgroundControl(change);
            shared.FileBackgroundControls.Add((scope, change.RequestId), pending);
            var clear = change.Action == FileBackgroundTaskAction.Clear;
            var (api, version) = clear ? (FileBackgroundTaskApi, 3) : FileTaskApi(change.Task.Kind);
            try
            {
                await _api.CallAsync(_profile, _session, FixedCapability(api, version), clear ? "clear_finished" : "stop",
                    new Dictionary<string, string> { ["taskid"] = clear ? JsonSerializer.Serialize(new[] { change.Task.Id }) : ShareParameterString(api, change.Task.Id) }, token).ConfigureAwait(false);
                pending.Accepted = true;
            }
            catch (DsmException e) when (DsmApiClient.IsExplicitApiRejection(e))
            { shared.FileBackgroundControls.Remove((scope, change.RequestId)); return Reject(ServiceErrorCategory(e), true); }
            catch { /* 请求可能已经到达；保留原身份，不重发。 */ }
            return await ReviewFileTaskCore(pending, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<IReadOnlyList<FileBackgroundTaskProgress>> GetTaskOperationsAsync(CancellationToken token = default)
    {
        var shared = ServiceMutations; await shared.Gate.WaitAsync(token).ConfigureAwait(false);
        try { var scope = ServiceScope(); return shared.FileBackgroundControls.Where(p => p.Key.Scope == scope && !p.Value.Complete).Select(p => FileTaskResult(p.Value.Change, MutationResultStatus.SubmittedButUnverified, true)).ToArray(); }
        finally { shared.Gate.Release(); }
    }
    public async Task<FileBackgroundTaskProgress?> ReviewTaskAsync(Guid requestId, CancellationToken token = default)
    {
        var shared = ServiceMutations; await shared.Gate.WaitAsync(token).ConfigureAwait(false);
        try { return shared.FileBackgroundControls.TryGetValue((ServiceScope(), requestId), out var pending) ? await ReviewFileTaskCore(pending, token).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }
    private async Task<FileBackgroundTaskProgress> ReviewFileTaskCore(PendingFileBackgroundControl pending, CancellationToken token)
    {
        if (!pending.Complete)
        {
            try
            {
                var tasks = await ReadCompleteFileTasks(token).ConfigureAwait(false);
                var current = tasks.SingleOrDefault(t => t.Id == pending.Change.Task.Id);
                pending.Complete = pending.Accepted && (pending.Change.Action == FileBackgroundTaskAction.Clear ? current is null :
                    current is { State: FileBackgroundTaskState.Finished } && pending.Change.Task.SameIdentity(current));
            }
            catch { /* 读取失败或身份不符不改变提交事实。 */ }
        }
        return FileTaskResult(pending.Change, pending.Complete ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified, true);
    }
    private async Task<IReadOnlyList<FileBackgroundTaskSummary>> ReadCompleteFileTasks(CancellationToken token)
    {
        var result = new List<FileBackgroundTaskSummary>(); var seen = new HashSet<string>(StringComparer.Ordinal); int? total = null;
        for (var offset = 0; ;)
        {
            var page = await ListFileBackgroundTasksAsync(offset, FileBackgroundTaskMaximumPageSize, token, strict: true).ConfigureAwait(false);
            if (total is not null && total != page.Total) throw new InvalidDataException("file.tasks.changed");
            total = page.Total;
            foreach (var task in page.Tasks) { if (!seen.Add(task.Id)) throw new InvalidDataException("file.tasks.duplicate"); result.Add(task); }
            if (!page.HasMore) return result;
            offset = page.NextOffset;
        }
    }
    private static (string Api, int Version) FileTaskApi(FileBackgroundTaskKind kind) => kind switch
    {
        FileBackgroundTaskKind.CopyOrMove => ("SYNO.FileStation.CopyMove", 3),
        FileBackgroundTaskKind.Delete => ("SYNO.FileStation.Delete", 2),
        FileBackgroundTaskKind.Extract => ("SYNO.FileStation.Extract", 2),
        FileBackgroundTaskKind.Compress => ("SYNO.FileStation.Compress", 3),
        _ => ("", 0),
    };
    private static FileBackgroundTaskProgress FileTaskResult(FileBackgroundTaskChange change, MutationResultStatus status, bool sent, MutationErrorCategory? error = null) =>
        new(change, new(1, status, "fileBackgroundTask", sent, status == MutationResultStatus.SubmittedButUnverified,
            new(status == MutationResultStatus.ConfirmedSuccess ? 1 : 0, status is MutationResultStatus.ConfirmedFailure or MutationResultStatus.PermissionDenied or MutationResultStatus.Unsupported ? 1 : 0,
                status == MutationResultStatus.SubmittedButUnverified ? 1 : 0), error, diagnosticTag: "file.tasks"));
    private sealed class PendingFileBackgroundControl(FileBackgroundTaskChange change)
    { public FileBackgroundTaskChange Change { get; } = change; public bool Accepted { get; set; } public bool Complete { get; set; } }
}
