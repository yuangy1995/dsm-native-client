using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string PublicGuestActionApi = "SYNO.Virtualization.API.Guest.Action";
    // 用户已授权开放已实现功能供实测；会话、接口与每次操作的确认/预检仍必须通过。
    private bool HasAuthenticatedVirtualMachineSession => _profile.Id == _session.ProfileId && !string.IsNullOrWhiteSpace(_session.Sid);
    // VMM 写操作的唯一模块协调器；后续创建/编辑沿用同一目标互斥，不扩张 NAS 设置枚举。
    private static readonly ConditionalWeakTable<IDsmApiClient, VirtualMachineMutationState> VmMutationStates = new();
    private VirtualMachineMutationState VmMutations => VmMutationStates.GetValue(_api, _ => new());
    public bool CanControlPower => HasAuthenticatedVirtualMachineSession && HasPublicVirtualMachineVersion(PublicGuestApi) && HasPublicVirtualMachineVersion(PublicGuestActionApi);
    public Task<MutationResult> ControlPowerAsync(VirtualMachinePowerRequest request, CancellationToken cancellationToken = default) =>
        CanControlPower ? ControlVirtualMachinePowerCoreAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("virtualMachinePower"));

    internal async Task<MutationResult> ControlVirtualMachinePowerCoreAsync(VirtualMachinePowerRequest request, CancellationToken token = default)
    {
        const string operation = "virtualMachinePower";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.ProfileId != _profile.Id || request.ProfileId != _session.ProfileId ||
            string.IsNullOrWhiteSpace(_session.Sid) || request.RequestId == Guid.Empty || !request.RiskConfirmed || !VirtualMachinePowerRules.CanRequest(request.Baseline, request.Action))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        if (!HasPublicVirtualMachineVersion(PublicGuestApi) || !HasPublicVirtualMachineVersion(PublicGuestActionApi)) return UnsupportedResult(operation);
        var scope = ServiceScope(); var state = VmMutations;
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.Baseline.Id, request.Baseline.Name, request.Baseline.State, request.Action }));
        try { if (!await state.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (state.TaskCleanupOperations.ContainsKey(request.RequestId) || state.DeletionOperations.ContainsKey(request.RequestId) || state.SettingsOperations.ContainsKey(request.RequestId) || state.CreationOperations.ContainsKey(request.RequestId)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.NetworkOperations.ContainsKey(request.RequestId) || state.ImageImportOperations.ContainsKey(request.RequestId)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.PowerOperations.TryGetValue(request.RequestId, out var prior))
                return prior.Scope == scope && prior.Signature == signature ? prior.Final ?? await ReviewVirtualMachinePowerAsync(prior, token).ConfigureAwait(false) :
                    ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (HasPendingNetworkForMachine(scope, request.Baseline.Id)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.DeletionPending.ContainsKey((scope, request.Baseline.Id)) || state.PowerPending.ContainsKey((scope, request.Baseline.Id)) || state.SettingsPending.ContainsKey((scope, request.Baseline.Id)) || HasPendingVirtualMachineCreation(scope, request.Baseline.Id, request.Baseline.Name)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                var current = await ReadVirtualMachinePowerTargetAsync(request.Baseline.Id, token).ConfigureAwait(false);
                var expected = request.Action == VirtualMachinePowerAction.PowerOn ? "shutdown" : "running";
                if (current.Name != request.Baseline.Name || current.Status != expected)
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, VirtualMachinePowerError(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var pending = new VirtualMachinePowerOperation(scope, signature, request.Baseline.Id, request.Baseline.Name, request.Action);
            state.PowerOperations.Add(request.RequestId, pending); state.PowerPending.Add((scope, pending.Id), pending);
            return await StartVirtualMachinePowerAsync(pending, token).ConfigureAwait(false);
        }
        finally { state.Gate.Release(); }
    }
    // 调用者在模块互斥内登记未知操作后调用一次；创建流程复用相同的公开请求和结果核查。
    private async Task<MutationResult> StartVirtualMachinePowerAsync(VirtualMachinePowerOperation pending, CancellationToken token)
    {
        try
        {
            var method = pending.Action switch { VirtualMachinePowerAction.PowerOn => "poweron", VirtualMachinePowerAction.Shutdown => "shutdown", _ => "poweroff" };
            await SecurityCallAsync(_capabilities[PublicGuestActionApi] with { MinVersion = 1, MaxVersion = 1 }, method,
                new Dictionary<string, object> { ["guest_id"] = pending.Id }, token).ConfigureAwait(false);
            pending.Accepted = true;
        }
        catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { pending.Rejection = VirtualMachinePowerError(error); }
        catch (Exception) { /* 接受情况不明，随后只读取状态，绝不重发电源请求。 */ }
        return await ReviewVirtualMachinePowerAsync(pending, token, waitForTransition: true).ConfigureAwait(false);
    }
    public async Task<IReadOnlyList<VirtualMachinePowerRecovery>> GetPowerRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations; await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return state.PowerPending.Values.Where(item => item.Scope == scope).Select(item => new VirtualMachinePowerRecovery(item.Id, item.Name, item.Action)).ToArray(); }
        finally { state.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewPowerAsync(string id, CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!VirtualMachinePowerRules.ValidId(id)) return ServicePreflightFailure("virtualMachinePower", MutationErrorCategory.Validation);
        var state = VmMutations;
        try { if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("virtualMachinePower", MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("virtualMachinePower"); }
        try { return state.PowerPending.TryGetValue((ServiceScope(), id), out var pending) ? await ReviewVirtualMachinePowerAsync(pending, cancellationToken).ConfigureAwait(false) : null; }
        finally { state.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewVirtualMachinePowerAsync(VirtualMachinePowerOperation pending, CancellationToken token, bool waitForTransition = false)
    {
        MutationResult Finish(MutationResult result) { pending.Final = result; VmMutations.PowerPending.Remove((pending.Scope, pending.Id)); return result; }
        if (pending.Rejection is { } rejection)
            return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                "virtualMachinePower", true, true, new(0, 1, 0), rejection));
        var category = MutationErrorCategory.Unknown;
        if (!token.IsCancellationRequested)
        try
        {
            var delay = 100;
            while (true)
            {
                var current = await ReadVirtualMachinePowerTargetAsync(pending.Id, token).ConfigureAwait(false);
                var desired = pending.Action == VirtualMachinePowerAction.PowerOn ? "running" : "shutdown";
                if (current.Status == desired)
                    return Finish(new(1, MutationResultStatus.ConfirmedSuccess, "virtualMachinePower", true, false, new(1, 0, 0), diagnosticTag: "virtual-machine.power.verified"));
                var transitioning = pending.Action == VirtualMachinePowerAction.PowerOn
                    ? current.Status is "shutdown" or "booting" : current.Status is "running" or "shutting_down";
                if (!waitForTransition || !pending.Accepted || !transitioning) break;
                await Task.Delay(delay, token).ConfigureAwait(false); delay = Math.Min(1000, delay * 2);
            }
        }
        catch (DsmException error) { category = VirtualMachinePowerError(error); }
        catch (Exception) { category = MutationErrorCategory.Network; }
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            "virtualMachinePower", true, true, new(0, 0, 1), category, diagnosticTag: "virtual-machine.power.unverified");
    }
    private async Task<VirtualMachinePowerTarget> ReadVirtualMachinePowerTargetAsync(string id, CancellationToken token)
    {
        EnsureVirtualMachineManagerProfile(); if (!HasPublicVirtualMachineVersion(PublicGuestApi)) throw UnavailableVirtualMachineManagerError();
        var data = await SecurityCallAsync(_capabilities[PublicGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "get",
            new Dictionary<string, object> { ["guest_id"] = id }, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        string Required(string key) => data[key] is JsonValue value && value.TryGetValue<string>(out var text) &&
            !string.IsNullOrWhiteSpace(text) && !text.Any(char.IsControl) ? text : throw InvalidVirtualMachineManagerResponse();
        if (Required("guest_id") != id) throw InvalidVirtualMachineManagerResponse();
        return new(Required("guest_name"), Required("status"));
    }
    private static MutationErrorCategory VirtualMachinePowerError(DsmException error) => IsMutationAuthenticationFailure(error) ? MutationErrorCategory.Authentication :
        error.Code == 105 ? MutationErrorCategory.Permission : error.Code is 102 or 103 or 104 ? MutationErrorCategory.Unsupported : error.Code is null ? MutationErrorCategory.Unknown : MutationErrorCategory.Server;
    private sealed record VirtualMachinePowerTarget(string Name, string Status);
    private sealed class VirtualMachineMutationState
    {
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public Dictionary<Guid, VirtualMachineImageImportOperation> ImageImportOperations { get; } = [];
        public Dictionary<Guid, VirtualMachineNetworkOperation> NetworkOperations { get; } = [];
        public Dictionary<(string Scope, string Id), VirtualMachineNetworkOperation> NetworkPending { get; } = [];
        public Dictionary<Guid, TaskCleanupOperation> TaskCleanupOperations { get; } = [];
        public Dictionary<Guid, VirtualMachineDeleteOperation> DeletionOperations { get; } = [];
        public Dictionary<(string Scope, string Id), VirtualMachineDeleteOperation> DeletionPending { get; } = [];
        public Dictionary<Guid, VirtualMachinePowerOperation> PowerOperations { get; } = [];
        public Dictionary<(string Scope, string Id), VirtualMachinePowerOperation> PowerPending { get; } = [];
        public Dictionary<Guid, VirtualMachineSettingsOperation> SettingsOperations { get; } = [];
        public Dictionary<(string Scope, string Id), VirtualMachineSettingsOperation> SettingsPending { get; } = [];
        public Dictionary<Guid, VirtualMachineCreationOperation> CreationOperations { get; } = [];
        public Dictionary<(string Scope, string Name), VirtualMachineCreationOperation> CreationPending { get; } = [];
    }
    private sealed class VirtualMachinePowerOperation(string scope, string signature, string id, string name, VirtualMachinePowerAction action)
    {
        public string Scope { get; } = scope;
        public string Signature { get; } = signature;
        public string Id { get; } = id;
        public string Name { get; } = name;
        public VirtualMachinePowerAction Action { get; } = action;
        public bool Accepted { get; set; }
        public MutationErrorCategory? Rejection { get; set; }
        public MutationResult? Final { get; set; }
    }
}
