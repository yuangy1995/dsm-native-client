using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string ImportImageOperation = "virtualMachineImageImport";
    public bool CanImportImages => HasAuthenticatedVirtualMachineSession && HasPublicVirtualMachineVersion(PublicImageApi) &&
        HasPublicVirtualMachineVersion(PublicStorageApi) && HasPublicVirtualMachineVersion(PublicVirtualMachineTaskApi);
    public async Task<IReadOnlyList<VirtualizationResourceSummary>> LoadImageImportStoragesAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!HasPublicVirtualMachineVersion(PublicStorageApi)) throw UnavailableVirtualMachineManagerError();
        return ParseResources(await CallPublicVirtualMachineAsync(PublicStorageApi, "list", null, cancellationToken).ConfigureAwait(false),
            "storages", "storage_id", "storage_name", VirtualizationResourceKind.Storage);
    }
    public async Task<VirtualMachineImageImportResult> ImportImageAsync(VirtualMachineImageImportRequest request, CancellationToken cancellationToken = default)
    {
        VirtualMachineImageImportResult Reject(MutationErrorCategory category) => new(request?.RequestId ?? Guid.Empty, VirtualMachineImageImportStage.Rejected, ServicePreflightFailure(ImportImageOperation, category));
        if (cancellationToken.IsCancellationRequested) return new(request?.RequestId ?? Guid.Empty, VirtualMachineImageImportStage.Rejected, CancelledBeforeSubmissionResult(ImportImageOperation));
        if (!CanImportImages) return new(request?.RequestId ?? Guid.Empty, VirtualMachineImageImportStage.Rejected, UnsupportedResult(ImportImageOperation));
        if (!VirtualMachineImageImportRules.IsValid(request) || request!.ProfileId != _profile.Id || request.RequestId == Guid.Empty || !request.RiskConfirmed)
            return Reject(MutationErrorCategory.Validation);
        request = request with { Storages = request.Storages.ToArray() };
        var state = VmMutations; var scope = ServiceScope(); var signature = ServiceHash(JsonSerializer.Serialize(request));
        try { if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return Reject(MutationErrorCategory.Conflict); }
        catch (OperationCanceledException) { return new(request.RequestId, VirtualMachineImageImportStage.Rejected, CancelledBeforeSubmissionResult(ImportImageOperation)); }
        try
        {
            if (state.CreationOperations.ContainsKey(request.RequestId) || state.DeletionOperations.ContainsKey(request.RequestId) ||
                state.PowerOperations.ContainsKey(request.RequestId) || state.SettingsOperations.ContainsKey(request.RequestId) ||
                state.NetworkOperations.ContainsKey(request.RequestId) || state.TaskCleanupOperations.ContainsKey(request.RequestId)) return Reject(MutationErrorCategory.Conflict);
            if (state.ImageImportOperations.TryGetValue(request.RequestId, out var prior))
                return prior.Scope == scope && prior.Signature == signature ? prior.Final ?? await ReviewImageImportCoreAsync(prior, cancellationToken).ConfigureAwait(false) : Reject(MutationErrorCategory.Conflict);
            if (ImageImportPending(scope, null, request.Name)) return Reject(MutationErrorCategory.Conflict);
            HashSet<string> existingIds;
            try
            {
                var storages = await LoadImageImportStoragesAsync(cancellationToken).ConfigureAwait(false);
                if (request.Storages.Any(expected => !storages.Any(item => item.Id == expected.Id && item.Name == expected.Name && item.Health == VirtualizationResourceHealth.Healthy)))
                    return Reject(MutationErrorCategory.Conflict);
                var images = await LoadImageDeletionTargetsAsync(cancellationToken).ConfigureAwait(false);
                if (images.Any(item => string.Equals(item.Name, request.Name, StringComparison.OrdinalIgnoreCase))) return Reject(MutationErrorCategory.Conflict);
                existingIds = images.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return new(request.RequestId, VirtualMachineImageImportStage.Rejected, CancelledBeforeSubmissionResult(ImportImageOperation)); }
            catch (DsmException error) { return Reject(VirtualMachinePowerError(error)); }
            catch { return Reject(MutationErrorCategory.Network); }
            var pending = new VirtualMachineImageImportOperation(scope, signature, request, existingIds);
            state.ImageImportOperations.Add(request.RequestId, pending);
            try
            {
                var receipt = await SecurityCallAsync(_capabilities[PublicImageApi] with { MinVersion = 1, MaxVersion = 1 }, "create", new()
                {
                    ["image_name"] = request.Name, ["type"] = VirtualMachineImageImportRules.WireType(request.Type),
                    ["ds_file_path"] = request.SourcePath, ["storage_ids"] = request.Storages.Select(item => item.Id).ToArray(), ["auto_clean_task"] = false
                }, cancellationToken).ConfigureAwait(false);
                var id = CreationText(receipt, "task_id"); if (VirtualMachinePowerRules.ValidId(id)) pending.TaskId = id;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
            {
                return pending.Final = new(request.RequestId, VirtualMachineImageImportStage.Rejected,
                    new(1, MutationResultStatus.ConfirmedFailure, ImportImageOperation, true, true, new(0, 1, 0), VirtualMachinePowerError(error)));
            }
            catch { /* 已提交而回执不明，保留原确认且绝不重发。 */ }
            return await ReviewImageImportCoreAsync(pending, cancellationToken).ConfigureAwait(false);
        }
        finally { state.Gate.Release(); }
    }
    public async Task<IReadOnlyList<VirtualMachineImageImportRequest>> GetImageImportRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations; await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return state.ImageImportOperations.Values.Where(item => item.Scope == scope && item.Final is null)
            .Select(item => item.Request with { Storages = item.Request.Storages.ToArray(), RiskConfirmed = false }).ToArray(); }
        finally { state.Gate.Release(); }
    }
    public async Task<VirtualMachineImageImportResult?> ReviewImageImportAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations;
        await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return state.ImageImportOperations.TryGetValue(requestId, out var pending) && pending.Scope == ServiceScope()
            ? pending.Final ?? await ReviewImageImportCoreAsync(pending, cancellationToken).ConfigureAwait(false) : null; }
        finally { state.Gate.Release(); }
    }
    private bool ImageImportPending(string scope, string? id, string name) => VmMutations.ImageImportOperations.Values.Any(item =>
        item.Scope == scope && item.Final is null && (id is not null && item.ImageId == id || string.Equals(item.Request.Name, name, StringComparison.OrdinalIgnoreCase)));
    private async Task<VirtualMachineImageImportResult> ReviewImageImportCoreAsync(VirtualMachineImageImportOperation pending, CancellationToken token)
    {
        VirtualMachineImageImportResult Unknown(VirtualMachineImageImportStage stage, MutationErrorCategory category = MutationErrorCategory.Unknown) =>
            new(pending.Request.RequestId, stage, new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
                ImportImageOperation, true, true, new(0, 0, 1), category), pending.Progress, pending.ImageId);
        if (pending.TaskId is null) return Unknown(VirtualMachineImageImportStage.VerifyReceipt);
        if (token.IsCancellationRequested) return Unknown(VirtualMachineImageImportStage.Importing);
        if (!HasPublicVirtualMachineVersion(PublicImageApi) || !HasPublicVirtualMachineVersion(PublicVirtualMachineTaskApi))
            return Unknown(VirtualMachineImageImportStage.Importing, MutationErrorCategory.Unsupported);
        try
        {
            var task = await SecurityCallAsync(_capabilities[PublicVirtualMachineTaskApi] with { MinVersion = 1, MaxVersion = 1 }, "get", new() { ["task_id"] = pending.TaskId }, token).ConfigureAwait(false);
            if (task["finish"] is not JsonValue finish || !finish.TryGetValue<bool>(out var finished) || task["task_info"] is not JsonObject info)
                throw InvalidVirtualMachineManagerResponse();
            if (info.ContainsKey("progress"))
            {
                if (info["progress"] is not JsonValue number || !number.TryGetValue<int>(out var progress) || progress is < 0 or > 100) throw InvalidVirtualMachineManagerResponse();
                pending.Progress = progress;
            }
            if (!finished) return Unknown(VirtualMachineImageImportStage.Importing);
            var id = CreationText(info, "image_id");
            if (CreationText(info, "status") != "create" || !VirtualMachinePowerRules.ValidId(id) || pending.ExistingIds.Contains(id!) || pending.ImageId is not null && pending.ImageId != id)
                return Unknown(VirtualMachineImageImportStage.VerifyImage, MutationErrorCategory.Conflict);
            pending.ImageId = id;
            var data = await CallPublicVirtualMachineAsync(PublicImageApi, "list", null, token).ConfigureAwait(false);
            var images = ParseResources(data, "images", "image_id", "image_name", VirtualizationResourceKind.Image);
            var image = images.SingleOrDefault(item => item.Id == id);
            if (image is null || image.Name != pending.Request.Name || image.Type != VirtualMachineImageImportRules.WireType(pending.Request.Type))
                return Unknown(VirtualMachineImageImportStage.VerifyImage, MutationErrorCategory.Conflict);
            var raw = RequiredObjectArray(data, "images").Single(item => CreationText(item, "image_id") == id);
            var storageIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var storage in RequiredObjectArray(raw, "storages"))
            {
                var storageId = CreationText(storage, "storage_id");
                if (!VirtualMachinePowerRules.ValidId(storageId) || !storageIds.Add(storageId!) || CreationText(storage, "status") != "online")
                    return Unknown(VirtualMachineImageImportStage.VerifyImage, MutationErrorCategory.Conflict);
            }
            if (!storageIds.SetEquals(pending.Request.Storages.Select(item => item.Id))) return Unknown(VirtualMachineImageImportStage.VerifyImage, MutationErrorCategory.Conflict);
            token.ThrowIfCancellationRequested();
            return pending.Final = new(pending.Request.RequestId, VirtualMachineImageImportStage.Complete,
                new(1, MutationResultStatus.ConfirmedSuccess, ImportImageOperation, true, false, new(1, 0, 0)), pending.Progress, id);
        }
        catch (OperationCanceledException) { return Unknown(VirtualMachineImageImportStage.Importing); }
        catch (DsmException error) { return Unknown(VirtualMachineImageImportStage.VerifyImage, VirtualMachinePowerError(error)); }
        catch { return Unknown(VirtualMachineImageImportStage.VerifyImage, MutationErrorCategory.Network); }
    }
    private sealed class VirtualMachineImageImportOperation(string scope, string signature, VirtualMachineImageImportRequest request, HashSet<string> existingIds)
    {
        public string Scope { get; } = scope;
        public string Signature { get; } = signature;
        public VirtualMachineImageImportRequest Request { get; } = request;
        public HashSet<string> ExistingIds { get; } = existingIds;
        public string? TaskId, ImageId;
        public int? Progress;
        public VirtualMachineImageImportResult? Final;
    }
}
