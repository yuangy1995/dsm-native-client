using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanMutateContainers => _profile.Id != Guid.Empty && _profile.Id == _session.ProfileId &&
        !string.IsNullOrWhiteSpace(_session.Sid) && HasInternalObservedContainerVersion(InternalObservedContainerApi) &&
        NasServiceFormatAndPathSupported(_capabilities[InternalObservedContainerApi]);

    public async Task<MutationResult> MutateContainerAsync(ContainerMutationRequest request, CancellationToken cancellationToken = default)
    {
        const string invalidOperation = "containerMutation";
        if (cancellationToken.IsCancellationRequested) return CancelledBeforeSubmissionResult(invalidOperation);
        if (request is null || request.Baseline is null || request.ProfileId != _profile.Id || request.RequestId == Guid.Empty ||
            !request.RiskConfirmed || !Enum.IsDefined(request.Action) || !ValidContainerMutationText(request.Baseline.Id) ||
            !ValidContainerMutationText(request.Baseline.Name)) return ServicePreflightFailure(invalidOperation, MutationErrorCategory.Validation);
        var operation = ContainerOperationName(request.Action);
        if (!CanMutateContainers) return UnsupportedResult(operation);
        var shared = ServiceMutations; var scope = ServiceScope();
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.Baseline, request.Action }));
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
                return previous is ContainerMutationOperation existing && existing.Scope == scope && existing.Signature == signature
                    ? existing.Final ?? await ReviewContainerOperationAsync(existing, cancellationToken).ConfigureAwait(false)
                    : ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (shared.ContainerPending.Any(pair => pair.Key.Scope == scope &&
                    (pair.Key.Id == request.Baseline.Id || pair.Value.Target.Summary.Name == request.Baseline.Name)))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            ContainerMutationTarget? target;
            try
            {
                target = (await LoadContainerMutationTargetsAsync(request.Baseline.Id, cancellationToken).ConfigureAwait(false)).SingleOrDefault(item => item.Summary.Id == request.Baseline.Id);
                if (target?.ManagedByPackage != false)
                    return ServicePreflightFailure(operation, target?.ManagedByPackage == true ? MutationErrorCategory.Permission : MutationErrorCategory.Unsupported, true);
                if (target is null || target.Summary != request.Baseline || !ContainerActionAllowed(target, request.Action))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new ContainerMutationOperation(scope, signature, request.RequestId, target, request.Action);
            shared.Operations.Add(request.RequestId, state);
            shared.ContainerPending.Add((scope, target.Summary.Id), state);
            try
            {
                // 内部 v1 按新鲜 ID 绑定出的名称提交；普通删除明确禁止强制删除及重置语义。
                var parameters = new Dictionary<string, object> { ["name"] = target.Summary.Name };
                if (request.Action == ContainerMutationAction.Delete)
                { parameters["force"] = false; parameters["preserve_profile"] = false; }
                var capability = _capabilities[InternalObservedContainerApi] with { MinVersion = 1, MaxVersion = 1 };
                await SecurityCallAsync(capability, request.Action.ToString().ToLowerInvariant(), parameters, cancellationToken).ConfigureAwait(false);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { state.Rejection = ServiceErrorCategory(error); }
            catch (Exception) { /* 可能已执行，保留目标锁，只通过后续状态核查，不重放。 */ }
            return await ReviewContainerOperationAsync(state, cancellationToken).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<IReadOnlyList<ContainerMutationRecovery>> GetContainerMutationRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile();
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var scope = ServiceScope();
            return shared.ContainerPending.Where(pair => pair.Key.Scope == scope).Select(pair =>
                new ContainerMutationRecovery(pair.Value.RequestId, pair.Value.Target.Summary, pair.Value.Action)).ToArray();
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<MutationResult?> ReviewContainerMutationAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        if (!CanMutateContainers) return UnsupportedResult("containerMutation");
        var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("containerMutation", MutationErrorCategory.Conflict); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("containerMutation"); }
        try
        {
            return shared.Operations.TryGetValue(requestId, out var previous) && previous is ContainerMutationOperation state && state.Scope == ServiceScope()
                ? state.Final ?? await ReviewContainerOperationAsync(state, cancellationToken).ConfigureAwait(false) : null;
        }
        finally { shared.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewContainerOperationAsync(ContainerMutationOperation state, CancellationToken token)
    {
        if (state.Final is not null) return state.Final;
        var operation = ContainerOperationName(state.Action);
        MutationResult Finish(MutationResult result)
        {
            state.Final = result;
            ServiceMutations.ContainerPending.Remove((state.Scope, state.Target.Summary.Id));
            return result;
        }
        if (state.Rejection is { } rejection)
            return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                operation, true, true, new(0, 1, 0), rejection));
        var category = MutationErrorCategory.Unknown;
        if (!token.IsCancellationRequested)
        try
        {
            var targets = await LoadContainerMutationTargetsAsync(state.Target.Summary.Id, token).ConfigureAwait(false);
            var current = targets.SingleOrDefault(item => item.Summary.Id == state.Target.Summary.Id);
            var verified = state.Action == ContainerMutationAction.Delete ? current is null :
                current is not null && current.Summary.Name == state.Target.Summary.Name && current.Summary.Image == state.Target.Summary.Image &&
                current.ManagedByPackage == false && ContainerStateConsistent(current) && current.Paused == false && current.Restarting == false && (state.Action switch
                {
                    ContainerMutationAction.Start => current.Running == true,
                    ContainerMutationAction.Stop => current.Running == false,
                    ContainerMutationAction.Restart => current.Running == true && current.StartedAt is { } after && state.Target.StartedAt is { } before && after > before,
                    _ => false,
                });
            if (verified) return Finish(new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0)));
        }
        catch (DsmException error) { category = ServiceErrorCategory(error); }
        catch (Exception) { category = MutationErrorCategory.Network; }
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            operation, true, true, new(0, 0, 1), category, diagnosticTag: "container.operation.unverified");
    }

    private async Task<IReadOnlyList<ContainerMutationTarget>> LoadContainerMutationTargetsAsync(string targetId, CancellationToken token)
    {
        var data = await CallInternalObservedContainerAsync(InternalObservedContainerApi, "list",
            new Dictionary<string, string> { ["offset"] = "0", ["limit"] = "-1", ["type"] = "all" }, token).ConfigureAwait(false);
        var summaries = ParseInternalObservedContainers(data);
        if (ContainerPageNumber(data, "offset") is { } offset && offset != 0 ||
            ContainerPageNumber(data, "total") is { } total && total != summaries.Count ||
            summaries.Select(item => item.Name).Distinct(StringComparer.Ordinal).Count() != summaries.Count) throw InvalidContainerManagerResponse();
        var raw = (JsonArray)data["containers"]!;
        var result = summaries.Select((summary, index) =>
        {
            var runtime = raw[index]?["State"] as JsonObject;
            bool? Flag(string name) => runtime?[name] is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : null;
            DateTimeOffset? startedAt = null;
            if (runtime?["StartedAt"] is JsonValue textNode && textNode.TryGetValue<string>(out var text) && text.Contains('T') &&
                DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.None, out var parsed) && parsed > DateTimeOffset.UnixEpoch) startedAt = parsed;
            bool? managed = raw[index]?["is_package"] is JsonValue package && package.TryGetValue<bool>(out var isPackage) ? isPackage : null;
            string? projectName = null;
            if (raw[index]?["Labels"] is JsonObject labels)
            {
                if (labels.ContainsKey("com.docker.compose.project"))
                {
                    if (labels["com.docker.compose.project"] is JsonValue label && label.TryGetValue<string>(out var name) && ValidContainerMutationText(name)) projectName = name;
                    else if (managed != true) managed = null;
                }
            }
            else if (raw[index]?["Labels"] is not null && managed != true) managed = null;
            return new ContainerMutationTarget(summary, Flag("Running"), Flag("Paused"), Flag("Restarting"), startedAt, managed, projectName);
        }).ToArray();
        var selectedIndex = Array.FindIndex(result, item => item.Summary.Id == targetId);
        if (selectedIndex >= 0 && result[selectedIndex] is { ManagedByPackage: false, ProjectName: { } project })
        {
            if (!HasInternalObservedContainerVersion(InternalObservedProjectApi)) throw InvalidContainerManagerResponse();
            var projects = await CallInternalObservedContainerAsync(InternalObservedProjectApi, "list", null, token).ConfigureAwait(false);
            var ownership = new Dictionary<string, bool>(StringComparer.Ordinal);
            foreach (var entry in projects)
            {
                if (entry.Value is not JsonObject value || value["name"] is not JsonValue nameNode || !nameNode.TryGetValue<string>(out var name) || !ValidContainerMutationText(name)) throw InvalidContainerManagerResponse();
                var managed = false;
                // 官方项目状态的 is_package 缺省为 false；错误类型不能当作未托管。
                if (value.ContainsKey("is_package") && (value["is_package"] is not JsonValue package || !package.TryGetValue<bool>(out managed))) throw InvalidContainerManagerResponse();
                if (!ownership.TryAdd(name, managed)) throw InvalidContainerManagerResponse();
            }
            result[selectedIndex] = result[selectedIndex] with { ManagedByPackage = ownership.GetValueOrDefault(project) };
        }
        return result;
    }

    private static bool ContainerActionAllowed(ContainerMutationTarget target, ContainerMutationAction action) =>
        target.ManagedByPackage == false && ContainerStateConsistent(target) && target.Paused == false && (action switch
        {
            ContainerMutationAction.Start or ContainerMutationAction.Delete => target.Running == false && target.Restarting == false,
            ContainerMutationAction.Stop => target.Running == true || target.Restarting == true,
            ContainerMutationAction.Restart => (target.Running == true || target.Restarting == true) && target.StartedAt is not null,
            _ => false,
        });
    private static bool ContainerStateConsistent(ContainerMutationTarget target) => target.Running is { } running && target.Restarting is { } restarting &&
        target.Summary.State == (restarting ? ContainerOperationalState.Restarting : running ? ContainerOperationalState.Running : ContainerOperationalState.Stopped);
    private static bool ValidContainerMutationText(string value) => !string.IsNullOrWhiteSpace(value) && value == value.Trim() && value.Length <= 256 && !value.Any(char.IsControl);
    private static string ContainerOperationName(ContainerMutationAction action) => action switch
    { ContainerMutationAction.Start => "containerStart", ContainerMutationAction.Stop => "containerStop", ContainerMutationAction.Restart => "containerRestart", _ => "containerDelete" };
    private sealed record ContainerMutationTarget(ContainerSummary Summary, bool? Running, bool? Paused, bool? Restarting, DateTimeOffset? StartedAt,
        bool? ManagedByPackage, string? ProjectName);
    private sealed class ContainerMutationOperation(string scope, string signature, Guid requestId, ContainerMutationTarget target, ContainerMutationAction action)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.ContainerLifecycle)
    {
        public Guid RequestId { get; } = requestId;
        public ContainerMutationTarget Target { get; } = target;
        public ContainerMutationAction Action { get; } = action;
        public MutationErrorCategory? Rejection { get; set; }
    }
}
