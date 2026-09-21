using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanSaveScheduledTasks => _nasServiceSessionVerified && _nasServiceAdministrator &&
        SecurityCapability("SYNO.Core.TaskScheduler", 3) is not null && SecurityCapability("SYNO.Core.TaskScheduler", 4) is not null;
    public Task<MutationResult> SaveScheduledTaskAsync(NasTaskSaveRequest request, CancellationToken cancellationToken = default) =>
        CanSaveScheduledTasks ? ExecuteTaskSaveCoreAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("saveTask"));

    internal async Task<MutationResult> ExecuteTaskSaveCoreAsync(NasTaskSaveRequest request, CancellationToken token = default)
    {
        const string operation = "saveTask";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id || request.RequestId == Guid.Empty ||
            !request.RiskConfirmed || string.IsNullOrWhiteSpace(_session.Sid) || !NasTaskSaveRules.IsValid(request)) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var capability = SecurityCapability("SYNO.Core.TaskScheduler", 4);
        if (capability is null || SecurityCapability("SYNO.Core.TaskScheduler", 3) is null) return UnsupportedResult(operation);
        static NasTaskDetail Copy(NasTaskDetail detail) => detail with { Schedule = detail.Schedule is null ? null : detail.Schedule with
            { MonthlyWeek = detail.Schedule.MonthlyWeek is null ? null : Array.AsReadOnly(detail.Schedule.MonthlyWeek.ToArray()) } };
        request = request with { BaselineDetail = Copy(request.BaselineDetail), Desired = Copy(request.Desired) };
        var desired = request.Desired;
        var baselineSignature = TaskDetailSignature(request.BaselineDetail);
        var includeMonthly = desired.Schedule!.MonthlyWeek is not null;
        var includeDate = !string.IsNullOrEmpty(desired.Schedule.Date);
        var desiredSignature = TaskSaveFingerprint(desired, includeMonthly, includeDate);
        if (request.BaselineTask is not null && TaskSaveFingerprint(request.BaselineDetail, includeMonthly, includeDate) == desiredSignature)
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var taskSignature = request.BaselineTask is null ? null : TaskEntrySignature(request.BaselineTask);
        var signature = ServiceHash(JsonSerializer.Serialize(new { baselineSignature, desiredSignature, taskSignature }));
        var scope = ServiceScope(); var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
                return previous.Scope == scope && previous.Signature == signature ? previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false) :
                    ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (desired.Id is int id && shared.TaskPending.ContainsKey((scope, id)) || shared.TaskSavePending.Values.Any(item => item.Scope == scope &&
                (desired.Id is not null && item.Id == desired.Id || item.Name == desired.Name && item.Owner == desired.Owner))) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var tasks = await LoadScheduledTasksAsync(token).ConfigureAwait(false);
                if (request.BaselineTask is null)
                {
                    if (tasks.Any(item => item.Name == desired.Name && item.Owner == desired.Owner)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                }
                else
                {
                    var current = tasks.SingleOrDefault(item => item.Id == request.BaselineTask.Id && NormalizeTaskOwner(item.RealOwner) == NormalizeTaskOwner(request.BaselineTask.RealOwner));
                    if (current is null || !current.CanEditScript || TaskEntrySignature(current) != taskSignature) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                }
                var detail = await LoadScheduledTaskDetailAsync(request.BaselineDetail.Id, request.BaselineDetail.RequestedRealOwner, token).ConfigureAwait(false);
                if (TaskDetailSignature(detail) != baselineSignature) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }

            var state = new NasTaskSaveOperation(scope, signature, request.RequestId, desired.Id, desired.Name!, desired.Owner!,
                NormalizeTaskOwner(desired.RequestedRealOwner ?? desired.RealOwner), desiredSignature, includeMonthly, includeDate);
            shared.Operations.Add(request.RequestId, state); shared.TaskSavePending.Add(request.RequestId, state);
            var parameters = TaskSaveParameters(desired, includeMonthly, includeDate, redact: false);
            if (desired.Id is int existingId) parameters["id"] = existingId;
            if (NormalizeTaskOwner(desired.RequestedRealOwner) is { } realOwner) parameters["real_owner"] = realOwner;
            try { await SecurityCallAsync(capability, desired.Id is null ? "create" : "set", parameters, token).ConfigureAwait(false); }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && error.Code is (102 or 103 or 104 or 105 or 106 or 107 or 119 or 404 or 408 or 900))
            { state.Rejection = ServiceErrorCategory(error); }
            catch (Exception) { /* 可能已经保存，不重发含脚本的请求。 */ }
            finally { parameters.Clear(); }
            return await ReviewTaskSaveOperationAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<IReadOnlyList<NasTaskSaveRecoveryInfo>> GetTaskSaveRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        if (_profile.Id != _session.ProfileId) throw InvalidNasServiceSettings();
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return shared.TaskSavePending.Values.Where(item => item.Scope == scope)
            .Select(item => new NasTaskSaveRecoveryInfo(item.RequestId, item.Id, item.Name, item.RealOwner)).ToArray(); }
        finally { shared.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewTaskSaveAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        if (requestId == Guid.Empty || _session.ProfileId != _profile.Id) return ServicePreflightFailure("saveTask", MutationErrorCategory.Validation);
        var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("saveTask", MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("saveTask"); }
        try { return shared.TaskSavePending.TryGetValue(requestId, out var state) && state.Scope == ServiceScope()
            ? await ReviewTaskSaveOperationAsync(state, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewTaskSaveOperationAsync(NasTaskSaveOperation state, CancellationToken token)
    {
        MutationResult Finish(MutationResult result) { state.Final = result; ServiceMutations.TaskSavePending.Remove(state.RequestId); return result; }
        if (state.Rejection is { } category) return Finish(new(1, category == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
            "saveTask", true, false, new(0, 1, 0), category));
        if (!token.IsCancellationRequested)
        try
        {
            var candidates = (await LoadScheduledTasksAsync(token).ConfigureAwait(false)).Where(item =>
                (state.Id is null ? item.Name == state.Name && item.Owner == state.Owner : item.Id == state.Id) &&
                (state.RealOwner is null || NormalizeTaskOwner(item.RealOwner) == state.RealOwner)).ToArray();
            if (candidates.Length == 1 && candidates[0].Type == "script")
            {
                var current = candidates[0]; var detail = await LoadScheduledTaskDetailAsync(current.Id, current.RealOwner, token).ConfigureAwait(false);
                if (TaskSaveFingerprint(detail, state.IncludeMonthly, state.IncludeDate) == state.DesiredSignature)
                    return Finish(new(1, MutationResultStatus.ConfirmedSuccess, "saveTask", true, false, new(1, 0, 0), diagnosticTag: "task.save.verified"));
            }
        }
        catch (Exception) { }
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            "saveTask", true, true, new(0, 0, 1), MutationErrorCategory.Network, diagnosticTag: "task.save.unverified");
    }
    private static string TaskSaveFingerprint(NasTaskDetail detail, bool includeMonthly, bool includeDate) => ServiceHash(JsonSerializer.Serialize(TaskSaveParameters(detail, includeMonthly, includeDate, redact: true)));
    private static Dictionary<string, object> TaskSaveParameters(NasTaskDetail detail, bool includeMonthly, bool includeDate, bool redact)
    {
        var value = detail.Schedule ?? throw InvalidNasServiceSettings();
        var schedule = new Dictionary<string, object>
        {
            ["date_type"] = value.DateType ?? throw InvalidNasServiceSettings(), ["week_day"] = value.WeekDays ?? throw InvalidNasServiceSettings(),
            ["repeat_date"] = value.RepeatDate ?? throw InvalidNasServiceSettings(), ["hour"] = value.Hour ?? throw InvalidNasServiceSettings(), ["minute"] = value.Minute ?? throw InvalidNasServiceSettings(),
            ["repeat_hour"] = value.RepeatHour ?? throw InvalidNasServiceSettings(), ["repeat_min"] = value.RepeatMinute ?? throw InvalidNasServiceSettings(),
            ["last_work_hour"] = value.LastWorkHour ?? throw InvalidNasServiceSettings(), ["repeat_min_store_config"] = new[] { 1, 5, 10, 15, 20, 30 }, ["repeat_hour_store_config"] = Enumerable.Range(1, 23).ToArray(),
        };
        if (includeMonthly) schedule["monthly_week"] = value.MonthlyWeek ?? throw InvalidNasServiceSettings();
        if (includeDate) schedule["date"] = value.Date ?? throw InvalidNasServiceSettings();
        var script = detail.Script ?? throw InvalidNasServiceSettings(); var mail = detail.NotificationEmails ?? throw InvalidNasServiceSettings();
        var notify = detail.NotifyOnError ?? throw InvalidNasServiceSettings();
        return new()
        {
            ["name"] = detail.Name ?? throw InvalidNasServiceSettings(), ["owner"] = detail.Owner ?? throw InvalidNasServiceSettings(),
            ["type"] = "script", ["enable"] = detail.IsEnabled ?? throw InvalidNasServiceSettings(), ["schedule"] = schedule,
            ["extra"] = new Dictionary<string, object> { ["script"] = redact ? ServiceHash(script) : script, ["notify_enable"] = notify || mail.Length > 0,
                ["notify_if_error"] = notify, ["notify_mail"] = redact ? ServiceHash(mail) : mail },
        };
    }
    private sealed class NasTaskSaveOperation(string scope, string signature, Guid requestId, int? id, string name, string owner, string? realOwner,
        string desiredSignature, bool includeMonthly, bool includeDate) : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Tasks)
    {
        public Guid RequestId { get; } = requestId; public int? Id { get; } = id; public string Name { get; } = name; public string Owner { get; } = owner;
        public string? RealOwner { get; } = realOwner; public string DesiredSignature { get; } = desiredSignature;
        public bool IncludeMonthly { get; } = includeMonthly; public bool IncludeDate { get; } = includeDate;
        public MutationErrorCategory? Rejection { get; set; }
    }
}
