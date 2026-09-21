using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public NasTaskCommandAvailability TaskCommandAvailability
    {
        get
        {
            var supported = _nasServiceSessionVerified && _nasServiceAdministrator && SecurityCapability("SYNO.Core.TaskScheduler", 3) is not null;
            return new(supported, supported, supported);
        }
    }
    public Task<MutationResult> ExecuteTaskCommandAsync(NasTaskCommandRequest request, CancellationToken cancellationToken = default)
    {
        var availability = TaskCommandAvailability;
        var allowed = request?.Command switch { NasTaskCommand.Enable or NasTaskCommand.Disable => availability.CanEnableDisable,
            NasTaskCommand.Run => availability.CanRun, NasTaskCommand.Delete => availability.CanDelete, _ => false };
        return allowed ? ExecuteTaskCommandCoreAsync(request!, cancellationToken) : Task.FromResult(UnsupportedResult("taskCommand"));
    }
    internal async Task<MutationResult> ExecuteTaskCommandCoreAsync(NasTaskCommandRequest request, CancellationToken token = default)
    {
        const string operation = "taskCommand";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || request.Baseline.Id < 0 || !StableTaskName(request.Baseline.Name) || !Enum.IsDefined(request.Command) ||
            request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id || request.RequestId == Guid.Empty || !request.RiskConfirmed || string.IsNullOrWhiteSpace(_session.Sid))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var baseline = request.Baseline;
        if (request.Command == NasTaskCommand.Run ? !baseline.CanRun : !baseline.CanEditScript)
            return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
        if (request.Command is NasTaskCommand.Enable or NasTaskCommand.Disable &&
            (baseline.IsEnabled is null || baseline.IsEnabled == (request.Command == NasTaskCommand.Enable))) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var inspectScript = baseline.Type == "script" && request.Command is NasTaskCommand.Enable or NasTaskCommand.Run;
        if (!NasTaskCommandRules.HasRequiredPreview(baseline, request.Command, request.DetailBaseline))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var capability = SecurityCapability("SYNO.Core.TaskScheduler", 3);
        if (capability is null || inspectScript && SecurityCapability("SYNO.Core.TaskScheduler", 4) is null) return UnsupportedResult(operation);
        var taskSignature = TaskEntrySignature(baseline);
        var detailSignature = inspectScript ? TaskDetailSignature(request.DetailBaseline!) : null;
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.Command, Task = taskSignature, Detail = detailSignature }));
        var scope = ServiceScope(); var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
                return previous.Scope == scope && previous.Signature == signature ? previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false) :
                    ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (shared.TaskPending.ContainsKey((scope, baseline.Id)) || shared.TaskSavePending.Values.Any(item => item.Scope == scope &&
                (item.Id == baseline.Id || item.Id is null && item.Name == baseline.Name && item.Owner == baseline.Owner)))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var current = (await LoadScheduledTasksAsync(token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == baseline.Id && NormalizeTaskOwner(item.RealOwner) == NormalizeTaskOwner(baseline.RealOwner));
                if (current is null || TaskEntrySignature(current) != taskSignature) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                if (inspectScript)
                {
                    var currentDetail = await LoadScheduledTaskDetailAsync(baseline.Id, NormalizeTaskOwner(baseline.RealOwner), token).ConfigureAwait(false);
                    if (TaskDetailSignature(currentDetail) != detailSignature) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                }
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new NasTaskCommandOperation(scope, signature, baseline.Id, baseline.Name, NormalizeTaskOwner(baseline.RealOwner), request.Command);
            shared.Operations.Add(request.RequestId, state); shared.TaskPending.Add((scope, state.Id), state);
            var parameters = new Dictionary<string, object> { ["id"] = baseline.Id };
            if (NormalizeTaskOwner(baseline.RealOwner) is { } realOwner) parameters["real_owner"] = realOwner;
            if (request.Command is NasTaskCommand.Enable or NasTaskCommand.Disable) parameters["enable"] = request.Command == NasTaskCommand.Enable;
            try
            {
                await SecurityCallAsync(capability, request.Command switch { NasTaskCommand.Run => "run", NasTaskCommand.Delete => "delete", _ => "set_enable" }, parameters, token).ConfigureAwait(false);
                state.Accepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && error.Code is (102 or 103 or 104 or 105 or 106 or 107 or 119 or 404 or 408 or 900))
            { state.Rejection = ServiceErrorCategory(error); }
            catch (Exception) { /* 运行或修改可能已提交，不能自动重发。 */ }
            return await ReviewTaskOperationAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }
    public async Task<IReadOnlyList<NasTaskRecoveryInfo>> GetTaskRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        if (_profile.Id != _session.ProfileId) throw InvalidNasServiceSettings();
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return Array.AsReadOnly(shared.TaskPending.Where(pair => pair.Key.Scope == scope)
            .Select(pair => new NasTaskRecoveryInfo(pair.Value.Id, pair.Value.Name, pair.Value.RealOwner, pair.Value.Command)).ToArray()); }
        finally { shared.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewTaskCommandAsync(int id, CancellationToken cancellationToken = default)
    {
        if (id < 0 || _profile.Id != _session.ProfileId) return ServicePreflightFailure("taskCommand", MutationErrorCategory.Validation);
        var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("taskCommand", MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("taskCommand"); }
        try { return shared.TaskPending.TryGetValue((ServiceScope(), id), out var state) ? await ReviewTaskOperationAsync(state, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewTaskOperationAsync(NasTaskCommandOperation state, CancellationToken token)
    {
        MutationResult Finish(MutationResult result) { state.Final = result; ServiceMutations.TaskPending.Remove((state.Scope, state.Id)); return result; }
        MutationResult Unknown() => new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            "taskCommand", true, true, new(0, 0, 1), MutationErrorCategory.Network, diagnosticTag: state.Command == NasTaskCommand.Run ? "task.run.unverified" : "task.command.unverified");
        if (state.Rejection is { } category) return Finish(new(1, category == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
            "taskCommand", true, false, new(0, 1, 0), category));
        if (state.Command == NasTaskCommand.Run)
        {
            // result_list 不含本次 run 的幂等关联标识，不能据新记录猜测脚本运行成功。
            return state.Accepted ? Finish(new(1, MutationResultStatus.ConfirmedSuccess, "taskCommand", true, false, new(1, 0, 0), diagnosticTag: "task.run.accepted")) : Unknown();
        }
        if (token.IsCancellationRequested) return Unknown();
        try
        {
            var tasks = await LoadScheduledTasksAsync(token).ConfigureAwait(false);
            if (state.Command == NasTaskCommand.Delete ? !tasks.Any(item => item.Id == state.Id) :
                tasks.Any(item => item.Id == state.Id && NormalizeTaskOwner(item.RealOwner) == state.RealOwner && item.IsEnabled == (state.Command == NasTaskCommand.Enable)))
                return Finish(new(1, MutationResultStatus.ConfirmedSuccess, "taskCommand", true, false, new(1, 0, 0), diagnosticTag: "task.command.verified"));
        }
        catch (Exception) { }
        return Unknown();
    }
    private static string? NormalizeTaskOwner(string? owner) => string.IsNullOrEmpty(owner) ? null : owner;
    private static string TaskEntrySignature(NasTaskEntry item) => JsonSerializer.Serialize(new { item.Id, item.Name, item.Owner, RealOwner = NormalizeTaskOwner(item.RealOwner), item.Type, item.Action, item.IsEnabled, item.RunAllowed, item.EditAllowed });
    private static string TaskDetailSignature(NasTaskDetail detail) => ServiceHash(JsonSerializer.Serialize(new
    {
        detail.Id, RequestedRealOwner = NormalizeTaskOwner(detail.RequestedRealOwner), detail.Name, detail.Owner, RealOwner = NormalizeTaskOwner(detail.RealOwner), detail.IsEnabled, detail.Schedule, detail.NotifyOnError,
        Script = detail.Script is null ? null : ServiceHash(detail.Script), Emails = detail.NotificationEmails is null ? null : ServiceHash(detail.NotificationEmails),
    }));
    private sealed class NasTaskCommandOperation(string scope, string signature, int id, string name, string? owner, NasTaskCommand command)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Tasks)
    {
        public int Id { get; } = id; public string Name { get; } = name; public string? RealOwner { get; } = owner;
        public NasTaskCommand Command { get; } = command; public bool Accepted { get; set; } public MutationErrorCategory? Rejection { get; set; }
    }
}
