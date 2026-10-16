using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanDeleteVirtualMachineImages => HasAuthenticatedVirtualMachineSession && (HasPublicVirtualMachineVersion(PublicImageApi) ||
        _virtualMachineInternalWritesEnabled && HasInternalVirtualMachineVersion(InternalCreationImageApi, 2, 2));
    bool IVirtualMachineManagerRepository.CanDeleteImages => CanDeleteVirtualMachineImages;
    private static string ImageDeletionScope(string scope) => ServiceHash(scope + "\nimage-deletion");
    public async Task<IReadOnlyList<VirtualizationResourceSummary>> LoadImageDeletionTargetsAsync(CancellationToken cancellationToken = default)
        => await LoadImageDeletionTargetsAsync(HasPublicVirtualMachineVersion(PublicImageApi) ? VirtualMachineApiSource.Public : VirtualMachineApiSource.Internal, cancellationToken).ConfigureAwait(false);

    private async Task<IReadOnlyList<VirtualizationResourceSummary>> LoadImageDeletionTargetsAsync(VirtualMachineApiSource source, CancellationToken cancellationToken)
    {
        EnsureVirtualMachineManagerProfile();
        if (source == VirtualMachineApiSource.Internal) return await LoadInternalImageDeletionTargetsAsync(cancellationToken).ConfigureAwait(false);
        if (!HasPublicVirtualMachineVersion(PublicImageApi)) throw UnavailableVirtualMachineManagerError();
        var data = await CallPublicVirtualMachineAsync(PublicImageApi, "list", null, cancellationToken).ConfigureAwait(false);
        _ = ReadVirtualMachineDeletionIdentities(data, isImage: true);
        return ParseResources(data, "images", "image_id", "image_name", VirtualizationResourceKind.Image);
    }
    public async Task<MutationResult> DeleteImageAsync(VirtualMachineImageDeleteRequest request, CancellationToken cancellationToken = default)
    {
        const string operation = "virtualMachineImageDelete";
        if (cancellationToken.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (!CanDeleteVirtualMachineImages) return UnsupportedResult(operation);
        if (request is null || request.ProfileId != _profile.Id || request.RequestId == Guid.Empty || !request.RiskConfirmed || !VirtualMachineImageDeletionRules.CanRequest(request.Baseline))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        request = request with { Baseline = request.Baseline with { ImageReplicas = request.Baseline.ImageReplicas?.ToArray() } };
        var source = request.Baseline.Source;
        if (source == VirtualMachineApiSource.Internal ? !_virtualMachineInternalWritesEnabled || !HasInternalVirtualMachineVersion(InternalCreationImageApi, 2, 2) : !HasPublicVirtualMachineVersion(PublicImageApi))
            return UnsupportedResult(operation);
        var scope = ServiceScope(); var imageScope = ImageDeletionScope(scope); var state = VmMutations;
        var signature = VirtualMachineImageIdentity(request.Baseline);
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
                var images = await LoadImageDeletionTargetsAsync(source, cancellationToken).ConfigureAwait(false);
                if (!images.Any(item => VirtualMachineImageIdentity(item) == signature && VirtualMachineImageDeletionRules.CanRequest(item)))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, VirtualMachinePowerError(error)); }
            catch (CertificateTrustChallengeException) { return ServicePreflightFailure(operation, MutationErrorCategory.Authentication); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var pending = new VirtualMachineDeleteOperation(imageScope, signature, request.Baseline.Id, request.Baseline.Name) { IsImage = true, Source = source };
            state.DeletionOperations.Add(request.RequestId, pending); state.DeletionPending.Add((imageScope, pending.Id), pending);
            try
            {
                var version = source == VirtualMachineApiSource.Internal ? 2 : 1;
                var parameters = source == VirtualMachineApiSource.Internal
                    ? new Dictionary<string, object> { ["id"] = pending.Id, ["synovmm_ui_id"] = request.RequestId.ToString("D") }
                    : new Dictionary<string, object> { ["image_id"] = pending.Id };
                await SecurityCallAsync(_capabilities[source == VirtualMachineApiSource.Internal ? InternalCreationImageApi : PublicImageApi] with { MinVersion = version, MaxVersion = version },
                    "delete", parameters, cancellationToken).ConfigureAwait(false);
                pending.Accepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { pending.Rejection = VirtualMachinePowerError(error); }
            catch (DsmException error) when (IsMutationAuthenticationFailure(error)) { return VirtualMachineDeletionUnverified(operation, cancellationToken, MutationErrorCategory.Authentication); }
            catch (CertificateTrustChallengeException) { return VirtualMachineDeletionUnverified(operation, cancellationToken, MutationErrorCategory.Authentication); }
            catch (Exception) { /* 不重发未知删除，仅通过原 API 来源读取列表。 */ }
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

    private static string VirtualMachineImageIdentity(VirtualizationResourceSummary item) => ServiceHash(JsonSerializer.Serialize(new
    {
        item.Id, item.Name, item.Kind, item.Health, item.AllocatedBytes, item.CapacityBytes, item.Type, item.Source,
        Copies = item.ImageReplicas?.OrderBy(copy => copy.StorageId, StringComparer.Ordinal).ThenBy(copy => copy.HostId, StringComparer.Ordinal).ToArray(),
    }));

    private static IReadOnlyList<VirtualizationResourceSummary> StrictInternalImageDeletionInventory(JsonObject data)
    {
        _ = AdvancedBool(data, "is_freeze");
        foreach (var row in RequiredObjectArray(data, "images"))
        {
            foreach (var key in new[] { "id", "name", "type", "status", "status_type" }) _ = AdvancedText(row, key);
            if (!VirtualMachinePowerRules.ValidId(AdvancedText(row, "repo_id")) || !VirtualMachinePowerRules.ValidId(AdvancedText(row, "host_id")))
                throw InvalidVirtualMachineManagerResponse();
        }
        return ParseInternalVirtualMachineImages(data);
    }

    private async Task<IReadOnlyList<VirtualizationResourceSummary>> LoadInternalImageDeletionTargetsAsync(CancellationToken token)
    {
        var data = await CallInternalVirtualMachineAsync(InternalCreationImageApi, "list", null, 2, 2, token).ConfigureAwait(false);
        var images = StrictInternalImageDeletionInventory(data);
        if (AdvancedBool(data, "is_freeze") || !images.Any(item => item.Type == "iso")) return images;
        if (!HasInternalSettingsContract) throw UnavailableVirtualMachineManagerError();
        var guests = await CallInternalVirtualMachineAsync(InternalSettingsGuestApi, "list", null, 2, 2, token).ConfigureAwait(false);
        var guestIds = ReadVirtualMachineDeletionIdentities(guests, isImage: false);
        var used = new HashSet<string>(StringComparer.Ordinal);
        foreach (var id in guestIds)
        {
            // 已关机的虚拟机仍可挂载 ISO，不能只扫描正在运行的对象。
            var settings = await SecurityCallAsync(_capabilities[InternalSettingsGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "get_setting",
                new() { ["guest_id"] = id }, token).ConfigureAwait(false);
            foreach (var image in AdvancedStringArray(settings, "iso_images")) if (image != "unmounted") used.Add(image);
        }
        token.ThrowIfCancellationRequested();
        return images.Select(item => item.Type == "iso" ? item with { IsInUse = used.Contains(item.Id) } : item).ToArray();
    }
}
