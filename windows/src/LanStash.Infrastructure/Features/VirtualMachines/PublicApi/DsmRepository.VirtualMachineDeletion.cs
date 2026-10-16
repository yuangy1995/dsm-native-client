using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanDeleteMachines => HasAuthenticatedVirtualMachineSession &&
        (HasPublicVirtualMachineVersion(PublicGuestApi) || _virtualMachineInternalWritesEnabled && HasInternalSettingsContract);
    public async Task<MutationResult> DeleteMachineAsync(VirtualMachineDeleteRequest request, CancellationToken cancellationToken = default)
    {
        const string operation = "virtualMachineDelete";
        if (cancellationToken.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (!CanDeleteMachines) return UnsupportedResult(operation);
        if (request is null || request.ProfileId != _profile.Id || request.RequestId == Guid.Empty || !request.RiskConfirmed || !VirtualMachineDeletionRules.CanRequest(request.Baseline))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var source = request.Baseline.Source;
        if (source == VirtualMachineApiSource.Internal ? !_virtualMachineInternalWritesEnabled || !HasInternalSettingsContract : !HasPublicVirtualMachineVersion(PublicGuestApi))
            return UnsupportedResult(operation);
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
                var current = await ReadVirtualMachinePowerTargetAsync(request.Baseline.Id, cancellationToken, source).ConfigureAwait(false);
                if (current.Name != request.Baseline.Name || current.Status != "shutdown") return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                if (source == VirtualMachineApiSource.Internal && !(await ReadVirtualMachineInventoryAsync(source, cancellationToken).ConfigureAwait(false))
                    .Any(item => item.Id == request.Baseline.Id && item.Name == request.Baseline.Name && item.State == VirtualMachineOperationalState.Stopped))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, VirtualMachinePowerError(error)); }
            catch (CertificateTrustChallengeException) { return ServicePreflightFailure(operation, MutationErrorCategory.Authentication); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var pending = new VirtualMachineDeleteOperation(scope, signature, request.Baseline.Id, request.Baseline.Name) { Source = source };
            state.DeletionOperations.Add(request.RequestId, pending); state.DeletionPending.Add((scope, pending.Id), pending);
            try
            {
                // 官方 v1 删除是同步空成功响应，不拼接多个 ID，不启动 Task.Info 轮询。
                await SecurityCallAsync(_capabilities[source == VirtualMachineApiSource.Public ? PublicGuestApi : InternalSettingsGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "delete",
                    new Dictionary<string, object> { ["guest_id"] = pending.Id }, cancellationToken).ConfigureAwait(false);
                pending.Accepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { pending.Rejection = VirtualMachinePowerError(error); }
            catch (DsmException error) when (IsMutationAuthenticationFailure(error)) { return VirtualMachineDeletionUnverified(operation, cancellationToken, MutationErrorCategory.Authentication); }
            catch (CertificateTrustChallengeException) { return VirtualMachineDeletionUnverified(operation, cancellationToken, MutationErrorCategory.Authentication); }
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
            IReadOnlySet<string> ids;
            if (pending.Source == VirtualMachineApiSource.Public)
            {
                var data = await CallPublicVirtualMachineAsync(pending.IsImage ? PublicImageApi : PublicGuestApi, "list", null, token).ConfigureAwait(false);
                ids = ReadVirtualMachineDeletionIdentities(data, pending.IsImage);
            }
            else if (pending.IsImage)
            {
                var data = await CallInternalVirtualMachineAsync(InternalCreationImageApi, "list", null, 2, 2, token).ConfigureAwait(false);
                var images = StrictInternalImageDeletionInventory(data);
                if (AdvancedBool(data, "is_freeze")) return VirtualMachineDeletionUnverified(operation, token, MutationErrorCategory.Conflict);
                ids = images.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
            }
            else ids = (await ReadVirtualMachineInventoryAsync(pending.Source, token).ConfigureAwait(false)).Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
            token.ThrowIfCancellationRequested();
            // 目标消失也可能由其他客户端造成，必须保留本次删除的明确接受回执。
            if (pending.Accepted && !ids.Contains(pending.Id)) return Finish(new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0)));
        }
        catch (DsmException error) { category = VirtualMachinePowerError(error); }
        catch (CertificateTrustChallengeException) { category = MutationErrorCategory.Authentication; }
        catch (Exception) { category = MutationErrorCategory.Network; }
        return VirtualMachineDeletionUnverified(operation, token, category);
    }

    private static MutationResult VirtualMachineDeletionUnverified(string operation, CancellationToken token, MutationErrorCategory category) =>
        new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            operation, true, true, new(0, 0, 1), category);

    private static IReadOnlySet<string> ReadVirtualMachineDeletionIdentities(JsonObject data, bool isImage)
    {
        var rows = RequiredObjectArray(data, isImage ? "images" : "guests");
        // 公开清单允许省略分页信息；提供时必须是从零开始的完整集合，不能把缺页当作目标消失。
        RequireCompleteVirtualMachineList(data, rows.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in rows)
            if (item[isImage ? "image_id" : "guest_id"] is not JsonValue value || !value.TryGetValue<string>(out var id) ||
                !VirtualMachinePowerRules.ValidId(id) || !ids.Add(id))
                throw InvalidVirtualMachineManagerResponse();
        return ids;
    }
    private sealed class VirtualMachineDeleteOperation(string scope, string signature, string id, string name)
    {
        public string Scope { get; } = scope;
        public string Signature { get; } = signature;
        public string Id { get; } = id;
        public string Name { get; } = name;
        public bool IsImage { get; init; }
        public VirtualMachineApiSource Source { get; init; } = VirtualMachineApiSource.Public;
        public bool Accepted { get; set; }
        public MutationErrorCategory? Rejection { get; set; }
        public MutationResult? Final { get; set; }
    }
}
