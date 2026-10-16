using System.Globalization;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<DownloadActionInfo> StartDownloadActionAsync(DownloadTaskActionRequest request, CancellationToken cancellationToken = default)
    {
        if (request.ProfileId != ProfileId || _session.ProfileId != ProfileId || request.Id == Guid.Empty ||
            DownloadScope(request.Kind) != 3 || !Enum.IsDefined(request.Kind) || request.Tasks.Count == 0 ||
            request.Tasks.Any(task => !ValidDownloadId(task.Id)) || request.Tasks.Select(task => task.Id).Distinct().Count() != request.Tasks.Count ||
            (request.Kind == DownloadActionKind.EditDestination ? !ValidDownloadSettingsDestination(request.Destination) : request.Destination is not null))
            throw new ArgumentException("download.invalid-action");
        await EnterDownloadsAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (DownloadRecords.Entries.ContainsKey(request.Id))
            {
                var old = DownloadEntry(request.Id);
                if (old.Kind != request.Kind || !old.Steps.Select(step => step.Target).SequenceEqual(request.Tasks.Select(task => task.Id)) ||
                    old.Steps.Where((step, index) => step.Identity != DownloadIdentity(request.Tasks[index]) || step.Destination != request.Destination).Any())
                    throw new DownloadActionConflictException();
                await ReviewDownloadAsync(old, cancellationToken).ConfigureAwait(false);
                return DownloadInfo(old);
            }
            if (PendingDownload(request.Kind, request.Tasks.Select(task => task.Id)) is not null) throw new DownloadActionConflictException();
            var entry = NewDownload(request.Kind, request.Tasks.Select(task => new DownloadStep
            {
                Target = task.Id, Identity = DownloadIdentity(task), Location = DownloadLocation(task.Destination), Destination = request.Destination,
                ExpectedState = task.State, RawStatus = task.RawStatus, Current = task,
            }).ToArray(), request.Id);
            await SaveDownloadAsync(entry).ConfigureAwait(false);
            await ExecuteDownloadTasksAsync(entry, cancellationToken).ConfigureAwait(false);
            return DownloadInfo(entry);
        }
        finally { DownloadRecords.Gate.Release(); }
    }
    private async Task ExecuteDownloadTasksAsync(DownloadRecord entry, CancellationToken token)
    {
        foreach (var step in entry.Steps.Where(step => step.Stage == DownloadActionStage.NotStarted))
        {
            if (token.IsCancellationRequested || entry.Steps.Any(other => other.Stage == DownloadActionStage.Unknown)) break;
            try
            {
                if (!HasControllablePublicDownloadStationContract || entry.Kind == DownloadActionKind.EditDestination && !HasPublicDownloadVersion(PublicDownloadTaskApi, 2) ||
                    entry.Kind == DownloadActionKind.FinishIncomplete && !CanFinishIncomplete) throw new NotSupportedException();
                var current = await LoadExactDownloadTaskAsync(step.Target, token).ConfigureAwait(false);
                if (DownloadIdentity(current) != step.Identity || DownloadLocation(current.Destination) != step.Location ||
                    entry.Kind != DownloadActionKind.EditDestination && (current.State != step.ExpectedState || current.RawStatus != step.RawStatus) ||
                    entry.Kind == DownloadActionKind.Pause && !DownloadControlAccepts(DownloadTaskControlAction.Pause, current.State) ||
                    entry.Kind == DownloadActionKind.Resume && !DownloadControlAccepts(DownloadTaskControlAction.Resume, current.State) ||
                    entry.Kind == DownloadActionKind.EditDestination && current.Destination == step.Destination)
                    throw new DownloadActionConflictException();
                step.Current = current;
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { break; }
            catch (Exception error)
            {
                step.Stage = DownloadActionStage.Rejected; step.Error = DownloadActionError(error);
                await SaveDownloadAsync(entry).ConfigureAwait(false); continue;
            }
            step.Stage = DownloadActionStage.Unknown;
            await SaveDownloadAsync(entry).ConfigureAwait(false);
            if (token.IsCancellationRequested)
            {
                step.Stage = DownloadActionStage.NotStarted; step.Submitted = false;
                await SaveDownloadAsync(entry).ConfigureAwait(false); break;
            }
            var parameters = new Dictionary<string, string> { ["id"] = step.Target };
            var method = entry.Kind switch
            { DownloadActionKind.Pause => "pause", DownloadActionKind.Resume => "resume", DownloadActionKind.EditDestination => "edit", _ => "delete" };
            if (method == "delete") parameters["force_complete"] = entry.Kind == DownloadActionKind.FinishIncomplete ? "true" : "false";
            if (method == "edit") parameters["destination"] = step.Destination!;
            step.Submitted = true;
            var cancelled = false;
            try
            {
                var response = await CallPublicDownloadAsync(PublicDownloadTaskApi, method, parameters, token, method == "edit" ? 2 : 1).ConfigureAwait(false);
                VerifyDownloadActionResponse(response, step.Target);
                step.Accepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && DownloadStationErrors.IsKnownRejection(error.Code))
            { step.Stage = DownloadActionStage.Rejected; step.Error = DownloadActionError(error); }
            catch (DownloadTaskActionRejectedException error)
            { step.Stage = DownloadActionStage.Rejected; step.Error = error.Category; }
            catch (OperationCanceledException) { cancelled = true; }
            catch { /* 已保存发送边界；任何不明确响应都不能重发。 */ }
            await SaveDownloadAsync(entry).ConfigureAwait(false);
            await ReviewDownloadAsync(entry, token).ConfigureAwait(false);
            if (cancelled && step.Stage == DownloadActionStage.Unknown) entry.CancelledAfterSubmission = true;
        }
    }
    private async Task<DownloadActionInfo> SingleDownloadTaskAsync(DownloadTask task, DownloadActionKind kind, CancellationToken token)
    {
        // 旧单项入口也使用同一队列；同目标的未知操作只查询，动作不同不能绕过保护。
        var actions = await LoadDownloadActionsAsync(token).ConfigureAwait(false);
        var pending = actions.FirstOrDefault(action => action.IsPending && DownloadScope(action.Kind) == 3 && action.Items.Any(item => item.TargetId == task.Id && DownloadPending(item.Stage)));
        if (pending is not null)
        {
            if (pending.Kind != kind || pending.Items.Count != 1) throw new DownloadActionConflictException();
            return await ReviewDownloadActionAsync(pending.Id, token).ConfigureAwait(false);
        }
        return await StartDownloadActionAsync(new(ProfileId, Guid.NewGuid(), kind, [task]), token).ConfigureAwait(false);
    }
    public async Task<DownloadTaskControlOutcome> ControlTaskAsync(DownloadTaskControlRequest request, CancellationToken cancellationToken = default)
    {
        try
        {
            if (request.ProfileId != ProfileId || !Enum.IsDefined(request.Action)) throw new ArgumentException();
            var info = await SingleDownloadTaskAsync(request.Task, request.Action == DownloadTaskControlAction.Pause ? DownloadActionKind.Pause : DownloadActionKind.Resume, cancellationToken).ConfigureAwait(false);
            var item = info.Items.Single();
            return new(DownloadActionResult(info), item.TargetId, item.Task);
        }
        catch (Exception error) { return new(DownloadActionFailure(error, "downloadControl"), request.Task.Id, null); }
    }
    public async Task<DownloadTaskDeleteOutcome> DeleteTaskAsync(DownloadTaskDeleteRequest request, CancellationToken cancellationToken = default)
    {
        try
        {
            if (request.ProfileId != ProfileId) throw new ArgumentException();
            var info = await SingleDownloadTaskAsync(request.Task, request.ForceComplete ? DownloadActionKind.FinishIncomplete : DownloadActionKind.Remove, cancellationToken).ConfigureAwait(false);
            return new(DownloadActionResult(info), request.Task.Id);
        }
        catch (Exception error) { return new(DownloadActionFailure(error, "downloadTaskDelete"), request.Task.Id); }
    }
    public async Task<DownloadActionInfo> RefreshRssSiteAsync(DownloadRssSite site, CancellationToken cancellationToken = default)
    {
        await EnterDownloadsAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var target = site.Id.ToString(CultureInfo.InvariantCulture);
            if (PendingDownload(DownloadActionKind.RefreshRss, [target]) is { } pending)
            { await ReviewDownloadAsync(pending, cancellationToken).ConfigureAwait(false); return DownloadInfo(pending); }
            var current = (await ListRssSitesAsync(cancellationToken).ConfigureAwait(false)).SingleOrDefault(item => item.Id == site.Id);
            if (current is null || current != site || current.IsUpdating) throw new DownloadActionConflictException();
            cancellationToken.ThrowIfCancellationRequested();
            var step = new DownloadStep { Target = target, Identity = site.IdentityDigest, LastUpdate = site.LastUpdate,
                Stage = DownloadActionStage.Unknown };
            var entry = NewDownload(DownloadActionKind.RefreshRss, [step]);
            await SaveDownloadAsync(entry).ConfigureAwait(false);
            if (cancellationToken.IsCancellationRequested)
            { step.Stage = DownloadActionStage.Cancelled; await SaveDownloadAsync(entry).ConfigureAwait(false); return DownloadInfo(entry); }
            step.Submitted = true;
            try
            {
                await CallPublicDownloadAsync(PublicDownloadRssSiteApi, "refresh", new Dictionary<string, string> { ["id"] = target }, cancellationToken).ConfigureAwait(false);
                step.Accepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && DownloadStationErrors.IsKnownRejection(error.Code))
            { step.Stage = DownloadActionStage.Rejected; step.Error = DownloadActionError(error); }
            catch { }
            await SaveDownloadAsync(entry).ConfigureAwait(false);
            await ReviewDownloadAsync(entry, cancellationToken).ConfigureAwait(false);
            return DownloadInfo(entry);
        }
        finally { DownloadRecords.Gate.Release(); }
    }
    private static MutationErrorCategory DownloadActionError(Exception error) => error switch
    {
        DownloadActionConflictException => MutationErrorCategory.Conflict, NotSupportedException => MutationErrorCategory.Unsupported,
        ArgumentException => MutationErrorCategory.Validation, DownloadTaskActionRejectedException rejected => rejected.Category,
        DsmException dsm => DownloadControlErrorCategory(dsm), _ => MutationErrorCategory.Network,
    };
    private static MutationResult DownloadActionFailure(Exception error, string operation) => error is DownloadActionPersistenceException { Submitted: true }
        ? new(1, MutationResultStatus.SubmittedButUnverified, operation, true, true, new(0, 0, 1), MutationErrorCategory.Unknown) : new(1,
        error is OperationCanceledException ? MutationResultStatus.CancelledBeforeSubmission : error is NotSupportedException ? MutationResultStatus.Unsupported : MutationResultStatus.ConfirmedFailure,
        operation, false, false, new(0, error is OperationCanceledException ? 0 : 1, 0), DownloadActionError(error));
    private static MutationResult DownloadActionResult(DownloadActionInfo info)
    {
        var succeeded = info.Items.Count(item => item.Stage is DownloadActionStage.Confirmed or DownloadActionStage.Accepted);
        var unknown = info.Items.Count(item => item.Stage == DownloadActionStage.Unknown);
        var failed = info.Items.Count(item => item.Stage == DownloadActionStage.Rejected);
        var remaining = info.Items.Count(item => item.Stage is DownloadActionStage.NotStarted or DownloadActionStage.Cancelled);
        var status = unknown > 0 ? info.CancellationRequestedAfterSubmission ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified : failed > 0
            ? succeeded > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.ConfirmedFailure
            : info.Items.Any(item => item.Stage is DownloadActionStage.NotStarted or DownloadActionStage.Cancelled)
                ? succeeded > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.CancelledBeforeSubmission : MutationResultStatus.ConfirmedSuccess;
        if (status == MutationResultStatus.ConfirmedFailure && info.Items.Any(item => item.Error == MutationErrorCategory.Permission)) status = MutationResultStatus.PermissionDenied;
        if (status == MutationResultStatus.ConfirmedFailure && info.Items.All(item => item.Error == MutationErrorCategory.Unsupported)) status = MutationResultStatus.Unsupported;
        var operation = info.Kind switch { DownloadActionKind.CreateLink or DownloadActionKind.CreateFile => "downloadCreate",
            DownloadActionKind.Remove or DownloadActionKind.FinishIncomplete => "downloadTaskDelete", _ => "download" + info.Kind };
        return new(1, status, operation, succeeded > 0 || unknown > 0 || info.Items.Any(item => item.WasSubmitted), unknown > 0 || info.Items.Any(item => item.Stage == DownloadActionStage.Accepted), new(succeeded, failed + (succeeded > 0 ? remaining : 0), unknown),
            info.Items.FirstOrDefault(item => item.Error is not null)?.Error ?? (unknown > 0 ? MutationErrorCategory.Unknown : null),
            diagnosticTag: info.Items.Any(item => item.Stage == DownloadActionStage.Accepted) && operation == "downloadCreate" ? "download-station.create.accepted" : null);
    }
}
