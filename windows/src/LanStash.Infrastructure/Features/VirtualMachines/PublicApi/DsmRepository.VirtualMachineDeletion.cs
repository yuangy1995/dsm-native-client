using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanDeleteMachines => HasAuthenticatedVirtualMachineSession && HasPublicVirtualMachineVersion(PublicGuestApi);
    public async Task<MutationResult> DeleteMachineAsync(VirtualMachineDeleteRequest request, CancellationToken cancellationToken = default)
    {
        const string operation = "virtualMachineDelete";
        if (cancellationToken.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (!CanDeleteMachines) return UnsupportedResult(operation);
        if (request is null || request.ProfileId != _profile.Id || request.RequestId == Guid.Empty || !request.RiskConfirmed || !VirtualMachineDeletionRules.CanRequest(request.Baseline))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var scope = ServiceScope(); var state = VmMutations;
        var signature = ServiceHash(JsonSerializer.Serialize(request.Baseline));
        try { if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (state.TaskCleanupOperations.ContainsKey(request.RequestId) || state.PowerOperations.ContainsKey(request.RequestId) || state.SettingsOperations.ContainsKey(request.RequestId) || state.CreationOperations.ContainsKey(request.RequestId))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.NetworkOperations.ContainsKey(request.RequestId) || state.ImageImportOperations.ContainsKey(request.RequestId)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.DeletionOperations.TryGetValue(request.RequestId, out var prior))
                return prior.Scope == scope && prior.Signature == signature ? prior.Final ?? await ReviewVirtualMachineDeletionAsync(prior, cancellationToken).ConfigureAwait(false)
                    : ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (HasPendingNetworkForMachine(scope, request.Baseline.Id)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.DeletionPending.ContainsKey((scope, request.Baseline.Id)) || state.PowerPending.ContainsKey((scope, request.Baseline.Id)) ||
                state.SettingsPending.ContainsKey((scope, request.Baseline.Id)) || HasPendingVirtualMachineCreation(scope, request.Baseline.Id, request.Baseline.Name))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                var current = await ReadVirtualMachinePowerTargetAsync(request.Baseline.Id, cancellationToken).ConfigureAwait(false);
                if (current.Name != request.Baseline.Name || current.Status != "shutdown") return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, VirtualMachinePowerError(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var pending = new VirtualMachineDeleteOperation(scope, signature, request.Baseline.Id, request.Baseline.Name);
            state.DeletionOperations.Add(request.RequestId, pending); state.DeletionPending.Add((scope, pending.Id), pending);
            try
            {
                // 官方 v1 删除是同步空成功响应，不拼接多个 ID，不启动 Task.Info 轮询。
                await SecurityCallAsync(_capabilities[PublicGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "delete",
                    new Dictionary<string, object> { ["guest_id"] = pending.Id }, cancellationToken).ConfigureAwait(false);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { pending.Rejection = VirtualMachinePowerError(error); }
            catch (Exception) { /* 回执不明，只允许后续只读核对。 */ }
            return await ReviewVirtualMachineDeletionAsync(pending, cancellationToken).ConfigureAwait(false);
        }
        finally { state.Gate.Release(); }
    }
    public async Task<IReadOnlyList<VirtualMachineDeleteRecovery>> GetDeletionRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations; await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return state.DeletionPending.Values.Where(item => item.Scope == scope).Select(item => new VirtualMachineDeleteRecovery(item.Id, item.Name)).ToArray(); }
        finally { state.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewDeletionAsync(string id, CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!VirtualMachinePowerRules.ValidId(id)) return ServicePreflightFailure("virtualMachineDelete", MutationErrorCategory.Validation);
        var state = VmMutations;
        try { if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("virtualMachineDelete", MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("virtualMachineDelete"); }
        try { return state.DeletionPending.TryGetValue((ServiceScope(), id), out var pending) ? await ReviewVirtualMachineDeletionAsync(pending, cancellationToken).ConfigureAwait(false) : null; }
        finally { state.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewVirtualMachineDeletionAsync(VirtualMachineDeleteOperation pending, CancellationToken token)
    {
        var operation = pending.IsImage ? "virtualMachineImageDelete" : "virtualMachineDelete";
        MutationResult Finish(MutationResult result) { pending.Final = result; VmMutations.DeletionPending.Remove((pending.Scope, pending.Id)); return result; }
        if (pending.Rejection is { } rejection)
            return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                operation, true, true, new(0, 1, 0), rejection));
        var category = MutationErrorCategory.Unknown;
        if (!token.IsCancellationRequested)
        try
        {
            var data = await CallPublicVirtualMachineAsync(pending.IsImage ? PublicImageApi : PublicGuestApi, "list", null, token).ConfigureAwait(false);
            var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in RequiredObjectArray(data, pending.IsImage ? "images" : "guests"))
                if (item[pending.IsImage ? "image_id" : "guest_id"] is not JsonValue value || !value.TryGetValue<string>(out var id) || !VirtualMachinePowerRules.ValidId(id) || !ids.Add(id))
                    throw InvalidVirtualMachineManagerResponse();
            token.ThrowIfCancellationRequested();
            if (!ids.Contains(pending.Id)) return Finish(new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0)));
        }
        catch (DsmException error) { category = VirtualMachinePowerError(error); }
        catch (Exception) { category = MutationErrorCategory.Network; }
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            operation, true, true, new(0, 0, 1), category);
    }
    private sealed class VirtualMachineDeleteOperation(string scope, string signature, string id, string name)
    {
        public string Scope { get; } = scope;
        public string Signature { get; } = signature;
        public string Id { get; } = id;
        public string Name { get; } = name;
        public bool IsImage { get; init; }
        public MutationErrorCategory? Rejection { get; set; }
        public MutationResult? Final { get; set; }
    }
}
