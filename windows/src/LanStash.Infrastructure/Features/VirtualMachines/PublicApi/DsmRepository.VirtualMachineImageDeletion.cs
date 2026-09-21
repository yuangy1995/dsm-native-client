using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanDeleteVirtualMachineImages => HasAuthenticatedVirtualMachineSession && HasPublicVirtualMachineVersion(PublicImageApi);
    bool IVirtualMachineManagerRepository.CanDeleteImages => CanDeleteVirtualMachineImages;
    private static string ImageDeletionScope(string scope) => ServiceHash(scope + "\nimage-deletion");
    public async Task<IReadOnlyList<VirtualizationResourceSummary>> LoadImageDeletionTargetsAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!HasPublicVirtualMachineVersion(PublicImageApi)) throw UnavailableVirtualMachineManagerError();
        var data = await CallPublicVirtualMachineAsync(PublicImageApi, "list", null, cancellationToken).ConfigureAwait(false);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in RequiredObjectArray(data, "images"))
            if (item["image_id"] is not JsonValue value || !value.TryGetValue<string>(out var id) || !VirtualMachinePowerRules.ValidId(id) || !ids.Add(id))
                throw InvalidVirtualMachineManagerResponse();
        return ParseResources(data, "images", "image_id", "image_name", VirtualizationResourceKind.Image);
    }
    public async Task<MutationResult> DeleteImageAsync(VirtualMachineImageDeleteRequest request, CancellationToken cancellationToken = default)
    {
        const string operation = "virtualMachineImageDelete";
        if (cancellationToken.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (!CanDeleteVirtualMachineImages) return UnsupportedResult(operation);
        if (request is null || request.ProfileId != _profile.Id || request.RequestId == Guid.Empty || !request.RiskConfirmed || !VirtualMachineImageDeletionRules.CanRequest(request.Baseline))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var scope = ServiceScope(); var imageScope = ImageDeletionScope(scope); var state = VmMutations;
        var signature = ServiceHash(JsonSerializer.Serialize(request.Baseline));
        try { if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (state.TaskCleanupOperations.ContainsKey(request.RequestId) || state.PowerOperations.ContainsKey(request.RequestId) || state.SettingsOperations.ContainsKey(request.RequestId) || state.CreationOperations.ContainsKey(request.RequestId)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.NetworkOperations.ContainsKey(request.RequestId) || state.ImageImportOperations.ContainsKey(request.RequestId)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.DeletionOperations.TryGetValue(request.RequestId, out var prior))
                return prior.Scope == imageScope && prior.Signature == signature ? prior.Final ?? await ReviewVirtualMachineDeletionAsync(prior, cancellationToken).ConfigureAwait(false) : ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (ImageImportPending(scope, request.Baseline.Id, request.Baseline.Name) || state.DeletionPending.ContainsKey((imageScope, request.Baseline.Id)) || state.CreationPending.Values.Any(item => item.Scope == scope &&
                (item.Request.Advanced?.BootImage?.Id == request.Baseline.Id || item.Request.Disks.Any(disk => disk.Image?.Id == request.Baseline.Id))))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                var images = await LoadImageDeletionTargetsAsync(cancellationToken).ConfigureAwait(false);
                if (!images.Any(item => item == request.Baseline)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, VirtualMachinePowerError(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var pending = new VirtualMachineDeleteOperation(imageScope, signature, request.Baseline.Id, request.Baseline.Name) { IsImage = true };
            state.DeletionOperations.Add(request.RequestId, pending); state.DeletionPending.Add((imageScope, pending.Id), pending);
            try
            {
                await SecurityCallAsync(_capabilities[PublicImageApi] with { MinVersion = 1, MaxVersion = 1 }, "delete",
                    new() { ["image_id"] = pending.Id }, cancellationToken).ConfigureAwait(false);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { pending.Rejection = VirtualMachinePowerError(error); }
            catch (Exception) { /* 不重发未知删除，仅调用公共列表核对。 */ }
            return await ReviewVirtualMachineDeletionAsync(pending, cancellationToken).ConfigureAwait(false);
        }
        finally { state.Gate.Release(); }
    }
    Task<IReadOnlyList<VirtualMachineDeleteRecovery>> IVirtualMachineManagerRepository.GetImageDeletionRecoveriesAsync(CancellationToken cancellationToken) => GetVirtualMachineImageDeletionRecoveriesAsync(cancellationToken);
    public async Task<IReadOnlyList<VirtualMachineDeleteRecovery>> GetVirtualMachineImageDeletionRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations; await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ImageDeletionScope(ServiceScope()); return state.DeletionPending.Values.Where(item => item.Scope == scope).Select(item => new VirtualMachineDeleteRecovery(item.Id, item.Name)).ToArray(); }
        finally { state.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewImageDeletionAsync(string id, CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!VirtualMachinePowerRules.ValidId(id)) return ServicePreflightFailure("virtualMachineImageDelete", MutationErrorCategory.Validation);
        var state = VmMutations;
        try { if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("virtualMachineImageDelete", MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("virtualMachineImageDelete"); }
        try { return state.DeletionPending.TryGetValue((ImageDeletionScope(ServiceScope()), id), out var pending) ? await ReviewVirtualMachineDeletionAsync(pending, cancellationToken).ConfigureAwait(false) : null; }
        finally { state.Gate.Release(); }
    }
}
