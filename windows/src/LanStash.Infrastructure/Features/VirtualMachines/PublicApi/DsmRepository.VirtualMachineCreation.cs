using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string CreateVmOperation = "createVirtualMachine";
    public bool CanCreateMachine => HasAuthenticatedVirtualMachineSession && HasCreationContract;
    private bool HasCreationContract => HasPublicVirtualMachineVersion(PublicGuestApi) && HasPublicVirtualMachineVersion(PublicStorageApi) && HasPublicVirtualMachineVersion(PublicVirtualMachineTaskApi);
    public Task<VirtualMachineCreationResult> CreateMachineAsync(VirtualMachineCreationRequest request, CancellationToken cancellationToken = default) =>
        CanCreateMachine ? CreateVirtualMachineCoreAsync(request, cancellationToken) : Task.FromResult(new VirtualMachineCreationResult(request?.RequestId ?? Guid.Empty, VirtualMachineCreationStage.Rejected, UnsupportedResult(CreateVmOperation)));
    public Task<VirtualMachineCreationResult?> ContinueCreationAsync(Guid requestId, bool riskConfirmed, CancellationToken cancellationToken = default) =>
        CanCreateMachine && riskConfirmed ? ContinueVirtualMachineCreationCoreAsync(requestId, true, cancellationToken) :
            Task.FromResult<VirtualMachineCreationResult?>(new(requestId, VirtualMachineCreationStage.Rejected, UnsupportedResult(CreateVmOperation)));
    public Task<VirtualMachineCreationResult?> ReviewCreationAsync(Guid requestId, CancellationToken cancellationToken = default) =>
        ContinueVirtualMachineCreationCoreAsync(requestId, false, cancellationToken);

    public async Task<IReadOnlyList<VirtualMachineCreationRecovery>> GetCreationRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations;
        await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var scope = ServiceScope();
            // 恢复展示不能修改在途配置，也不能复用旧勾选自动继续写入。
            return state.CreationPending.Values.Where(operation => operation.Scope == scope).Select(operation => new VirtualMachineCreationRecovery(
                operation.Request with { Disks = operation.Request.Disks.ToArray(), Networks = operation.Request.Networks.ToArray(), RiskConfirmed = false })).ToArray();
        }
        finally { state.Gate.Release(); }
    }

    internal async Task<VirtualMachineCreationResult> CreateVirtualMachineCoreAsync(VirtualMachineCreationRequest request, CancellationToken token = default)
    {
        VirtualMachineCreationResult Reject(MutationErrorCategory category, bool refresh = false) => new(request?.RequestId ?? Guid.Empty, VirtualMachineCreationStage.Rejected, ServicePreflightFailure(CreateVmOperation, category, refresh));
        if (token.IsCancellationRequested) return new(request?.RequestId ?? Guid.Empty, VirtualMachineCreationStage.Rejected, CancelledBeforeSubmissionResult(CreateVmOperation));
        if (!VirtualMachineCreationRules.IsValid(request!) || !request!.RiskConfirmed || request.RequestId == Guid.Empty ||
            request.ProfileId != _profile.Id || request.ProfileId != _session.ProfileId || string.IsNullOrWhiteSpace(_session.Sid)) return Reject(MutationErrorCategory.Validation);
        // 调用者可传入可变列表；任何等待前固定已确认配置。
        request = request with { Disks = request.Disks.ToArray(), Networks = request.Networks.ToArray() };
        if (!HasCreationContract || request.Advanced is not null && !CanCreateAdvancedMachine || request.PowerOnAfterCreation && !CanControlPower || request.Disks.Any(disk => disk.Image is not null) && !HasPublicVirtualMachineVersion(PublicImageApi) ||
            request.Networks.Any(nic => nic.Network is not null) && !HasPublicVirtualMachineVersion(PublicNetworkApi))
            return new(request.RequestId, VirtualMachineCreationStage.Rejected, UnsupportedResult(CreateVmOperation));
        var state = VmMutations; var scope = ServiceScope(); var signature = ServiceHash(JsonSerializer.Serialize(request));
        try { if (!await state.Gate.WaitAsync(0, token).ConfigureAwait(false)) return Reject(MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return new(request.RequestId, VirtualMachineCreationStage.Rejected, CancelledBeforeSubmissionResult(CreateVmOperation)); }
        try
        {
            if (state.TaskCleanupOperations.ContainsKey(request.RequestId) || state.DeletionOperations.ContainsKey(request.RequestId) || state.PowerOperations.ContainsKey(request.RequestId) || state.SettingsOperations.ContainsKey(request.RequestId)) return Reject(MutationErrorCategory.Conflict, true);
            if (state.NetworkOperations.ContainsKey(request.RequestId) || state.ImageImportOperations.ContainsKey(request.RequestId)) return Reject(MutationErrorCategory.Conflict, true);
            if (state.CreationOperations.TryGetValue(request.RequestId, out var prior))
                return prior.Scope == scope && prior.Signature == signature ? prior.Final ?? await ReviewVirtualMachineCreationCoreAsync(prior, false, token).ConfigureAwait(false) : Reject(MutationErrorCategory.Conflict, true);
            var nameKey = (scope, request.Settings.Name.ToUpperInvariant());
            if (request.Networks.Any(nic => nic.Network is { } network && state.NetworkPending.ContainsKey((scope, network.Id))))
                return Reject(MutationErrorCategory.Conflict, true);
            if (request.Disks.Any(disk => disk.Image is { } image && (state.DeletionPending.ContainsKey((ImageDeletionScope(scope), image.Id)) || ImageImportPending(scope, image.Id, image.Name))) ||
                state.DeletionPending.Values.Any(item => item.Scope == scope && string.Equals(item.Name, request.Settings.Name, StringComparison.OrdinalIgnoreCase)) || state.CreationPending.ContainsKey(nameKey) || state.SettingsPending.Values.Any(item => item.Scope == scope && string.Equals(item.Name, request.Settings.Name, StringComparison.OrdinalIgnoreCase)))
                return Reject(MutationErrorCategory.Conflict, true);
            HashSet<string> existingIds;
            VirtualMachineCreationStorage? advancedStorage = null;
            try
            {
                var guests = ParseMachines(await CallPublicVirtualMachineAsync(PublicGuestApi, "list", null, token).ConfigureAwait(false));
                if (guests.Any(guest => string.Equals(guest.Name, request.Settings.Name, StringComparison.OrdinalIgnoreCase))) return Reject(MutationErrorCategory.Conflict, true);
                existingIds = guests.Select(guest => guest.Id).ToHashSet(StringComparer.Ordinal);
                if (request.Advanced is not null)
                {
                    advancedStorage = await ValidateAdvancedCreationResourcesAsync(request, token).ConfigureAwait(false);
                    if (advancedStorage is null) return Reject(MutationErrorCategory.Conflict, true);
                }
                else
                {
                    var storageData = await CallPublicVirtualMachineAsync(PublicStorageApi, "list", null, token).ConfigureAwait(false);
                    var storages = ParseResources(storageData, "storages", "storage_id", "storage_name", VirtualizationResourceKind.Storage);
                    if (!storages.Any(item => item.Id == request.Storage.Id && item.Name == request.Storage.Name && item.Health == VirtualizationResourceHealth.Healthy)) return Reject(MutationErrorCategory.Conflict, true);
                }
                if (request.Networks.Any(nic => nic.Network is not null))
                {
                    var networkData = await CallPublicVirtualMachineAsync(PublicNetworkApi, "list", null, token).ConfigureAwait(false);
                    var networks = ParseResources(networkData, "networks", "network_id", "network_name", VirtualizationResourceKind.Network);
                    if (request.Networks.Any(nic => nic.Network is { } expected && !networks.Any(item => item.Id == expected.Id && item.Name == expected.Name))) return Reject(MutationErrorCategory.Conflict, true);
                }
                if (request.Disks.Any(disk => disk.Image is not null))
                {
                    var images = ParseResources(await CallPublicVirtualMachineAsync(PublicImageApi, "list", null, token).ConfigureAwait(false), "images", "image_id", "image_name", VirtualizationResourceKind.Image);
                    if (request.Disks.Any(disk => disk.Image is { } expected && !images.Any(item => item.Id == expected.Id && item.Name == expected.Name && item.Type == "disk"))) return Reject(MutationErrorCategory.Conflict, true);
                }
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return new(request.RequestId, VirtualMachineCreationStage.Rejected, CancelledBeforeSubmissionResult(CreateVmOperation)); }
            catch (DsmException error) { return Reject(VirtualMachinePowerError(error)); }
            catch (Exception) { return Reject(MutationErrorCategory.Network); }
            var pending = new VirtualMachineCreationOperation(scope, signature, request, existingIds);
            if (advancedStorage is not null) pending.AdvancedParameters = BuildAdvancedCreationParameters(request, advancedStorage);
            state.CreationOperations.Add(request.RequestId, pending); state.CreationPending.Add(nameKey, pending);
            try
            {
                var reply = pending.AdvancedParameters is { } advancedParameters
                    ? await SecurityCallAsync(_capabilities[InternalSettingsGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "create", AdvancedWireParameters(advancedParameters), token).ConfigureAwait(false)
                    : await SecurityCallAsync(_capabilities[PublicGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "create", new()
                {
                    ["guest_name"] = request.Settings.Name, ["storage_id"] = request.Storage.Id, ["auto_clean_task"] = false,
                    ["vdisks"] = request.Disks.Select(disk => disk.Image is { } image
                        ? new Dictionary<string, object> { ["create_type"] = 1, ["image_id"] = image.Id }
                        : new Dictionary<string, object> { ["create_type"] = 0, ["vdisk_size"] = disk.SizeMiB!.Value }).ToArray(),
                    ["vnics"] = request.Networks.Select(nic =>
                    {
                        var values = new Dictionary<string, object> { ["network_id"] = nic.Network?.Id ?? "" };
                        if (nic.MacAddress is not null) values["mac"] = nic.MacAddress; return values;
                    }).ToArray()
                }, token).ConfigureAwait(false);
                pending.TaskId = CreationText(reply, "task_id");
                if (!VirtualMachinePowerRules.ValidId(pending.TaskId)) pending.TaskId = null;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
            { return FinishVirtualMachineCreation(pending, new(request.RequestId, VirtualMachineCreationStage.Rejected, new(1, MutationResultStatus.ConfirmedFailure, CreateVmOperation, true, true, new(0, 1, 0), VirtualMachinePowerError(error)))); }
            catch (Exception) { /* 回执可能丢失，不能按同名 VM 猜测任务或重建。 */ }
            return await ReviewVirtualMachineCreationCoreAsync(pending, true, token).ConfigureAwait(false);
        }
        finally { state.Gate.Release(); }
    }

    internal async Task<VirtualMachineCreationResult?> ContinueVirtualMachineCreationCoreAsync(Guid requestId, bool allowConfiguration, CancellationToken token = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations;
        try { if (!await state.Gate.WaitAsync(0, token).ConfigureAwait(false)) return new(requestId, VirtualMachineCreationStage.Creating, ServicePreflightFailure(CreateVmOperation, MutationErrorCategory.Conflict, true)); }
        catch (OperationCanceledException) { return new(requestId, VirtualMachineCreationStage.Creating, CancelledBeforeSubmissionResult(CreateVmOperation)); }
        try
        {
            if (!state.CreationOperations.TryGetValue(requestId, out var operation) || operation.Scope != ServiceScope()) return null;
            return operation.Final ?? await ReviewVirtualMachineCreationCoreAsync(operation, allowConfiguration, token).ConfigureAwait(false);
        }
        finally { state.Gate.Release(); }
    }

    private async Task<VirtualMachineCreationResult> ReviewVirtualMachineCreationCoreAsync(VirtualMachineCreationOperation pending, bool allowConfiguration, CancellationToken token)
    {
        if (pending.Request.Advanced is not null) return await ReviewAdvancedCreationAsync(pending, allowConfiguration, token).ConfigureAwait(false);
        var request = pending.Request;
        VirtualMachineCreationResult Unknown(VirtualMachineCreationStage stage, MutationErrorCategory category = MutationErrorCategory.Unknown, bool canContinue = false) =>
            new(request.RequestId, stage, new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : pending.GuestId is null ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.PartialSuccess,
                CreateVmOperation, true, true, new(pending.GuestId is null ? 0 : 1, 0, 1), category), pending.Progress, pending.GuestId, canContinue);
        if (pending.TaskId is null) return Unknown(VirtualMachineCreationStage.VerifyReceipt);
        if (token.IsCancellationRequested) return Unknown(VirtualMachineCreationStage.Creating);
        if (!HasPublicVirtualMachineVersion(PublicGuestApi) || !HasPublicVirtualMachineVersion(PublicVirtualMachineTaskApi) || allowConfiguration && !HasCreationContract)
            return Unknown(VirtualMachineCreationStage.Creating, MutationErrorCategory.Unsupported);
        try
        {
            if (!pending.PublicTaskSucceeded)
            {
                var task = await SecurityCallAsync(_capabilities[PublicVirtualMachineTaskApi] with { MinVersion = 1, MaxVersion = 1 }, "get", new() { ["task_id"] = pending.TaskId }, token).ConfigureAwait(false);
                if (task["finish"] is not JsonValue finishValue || !finishValue.TryGetValue<bool>(out var finished) || task["task_info"] is not JsonObject info) throw InvalidVirtualMachineManagerResponse();
                int? observedProgress = null;
                if (info.ContainsKey("progress"))
                {
                    if (info["progress"] is not JsonValue progressValue || !progressValue.TryGetValue<int>(out var progress) || progress is < 0 or > 100) throw InvalidVirtualMachineManagerResponse();
                    observedProgress = pending.Progress = progress;
                }
                if (!finished) return Unknown(VirtualMachineCreationStage.Creating);
                if (CreationText(info, "status") != "create" || observedProgress != 100) return Unknown(VirtualMachineCreationStage.Creating, MutationErrorCategory.Conflict);
                var createdId = CreationText(info, "guest_id");
                if (!VirtualMachinePowerRules.ValidId(createdId) || pending.ExistingIds.Contains(createdId!) || pending.GuestId is not null && pending.GuestId != createdId) return Unknown(VirtualMachineCreationStage.Creating, MutationErrorCategory.Conflict);
                // 源映像绑定于冻结的 create 请求，结果绑定于该请求返回的 task_id；不按同名 VM 或大小认领。
                pending.GuestId = createdId; pending.PublicTaskSucceeded = true;
            }
            var id = pending.GuestId!;
            var guest = await SecurityCallAsync(_capabilities[PublicGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "get", new() { ["guest_id"] = id! }, token).ConfigureAwait(false);
            if (!CreatedVirtualMachineMatches(guest, id!, request)) return Unknown(VirtualMachineCreationStage.Creating, MutationErrorCategory.Conflict);
            var hardware = CreatedHardwareIdentity(guest);
            if (pending.PublicHardware is null) pending.PublicHardware = hardware;
            else if (!JsonNode.DeepEquals(pending.PublicHardware, hardware)) return Unknown(VirtualMachineCreationStage.VerifyConfiguration, MutationErrorCategory.Conflict);
            var current = ParseVirtualMachineSettings(guest, id!);
            if (current.Configuration == request.Settings) return await FinishVerifiedVirtualMachineCreationAsync(pending, current, allowConfiguration, token).ConfigureAwait(false);
            if (pending.SettingsSubmitted || pending.ConfigurationVerified) return Unknown(VirtualMachineCreationStage.VerifyConfiguration);
            if (VirtualMachineSettingsRules.Validate(current, request.Settings) != VirtualMachineSettingsValidation.None) return Unknown(VirtualMachineCreationStage.Configure, MutationErrorCategory.Conflict);
            if (!allowConfiguration) return Unknown(VirtualMachineCreationStage.Configure, canContinue: true);
            token.ThrowIfCancellationRequested();
            var settings = ChangedVirtualMachineFields(current.Configuration, request.Settings); settings["guest_id"] = id!;
            pending.SettingsSubmitted = true;
            try { await SecurityCallAsync(_capabilities[PublicGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "set", settings, token).ConfigureAwait(false); }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
            { return FinishVirtualMachineCreation(pending, new(request.RequestId, VirtualMachineCreationStage.Rejected, new(1, MutationResultStatus.PartialSuccess, CreateVmOperation, true, true, new(1, 1, 0), VirtualMachinePowerError(error)), pending.Progress, id)); }
            catch (Exception) { /* 配置可能已经写入，后续仅核查，不再次 set。 */ }
            token.ThrowIfCancellationRequested();
            var finalGuest = await SecurityCallAsync(_capabilities[PublicGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "get", new() { ["guest_id"] = id! }, token).ConfigureAwait(false);
            if (!CreatedVirtualMachineMatches(finalGuest, id!, request) || !JsonNode.DeepEquals(pending.PublicHardware, CreatedHardwareIdentity(finalGuest)))
                return Unknown(VirtualMachineCreationStage.VerifyConfiguration, MutationErrorCategory.Conflict);
            var verified = ParseVirtualMachineSettings(finalGuest, id!);
            return verified.Configuration == request.Settings ? await FinishVerifiedVirtualMachineCreationAsync(pending, verified, allowConfiguration, token).ConfigureAwait(false) : Unknown(VirtualMachineCreationStage.VerifyConfiguration);
        }
        catch (DsmException error) { return Unknown(pending.SettingsSubmitted ? VirtualMachineCreationStage.VerifyConfiguration : VirtualMachineCreationStage.Creating, VirtualMachinePowerError(error)); }
        catch (Exception) { return Unknown(pending.SettingsSubmitted ? VirtualMachineCreationStage.VerifyConfiguration : VirtualMachineCreationStage.Creating, token.IsCancellationRequested ? MutationErrorCategory.Unknown : MutationErrorCategory.Network); }
    }

    private async Task<VirtualMachineCreationResult> FinishVerifiedVirtualMachineCreationAsync(VirtualMachineCreationOperation operation,
        VirtualMachineSettings current, bool allowWrite, CancellationToken token)
    {
        operation.ConfigurationVerified = true;
        var completedSteps = operation.Request.Advanced is null ? 2 : 1;
        if (operation.Request.PowerOnAfterCreation)
        {
            VirtualMachineCreationResult Pending(VirtualMachineCreationStage stage, MutationErrorCategory category = MutationErrorCategory.Unknown, bool canContinue = false) =>
                new(operation.Request.RequestId, stage, new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.PartialSuccess,
                    CreateVmOperation, true, true, new(completedSteps, 0, 1), category), operation.Progress, operation.GuestId, canContinue);
            MutationResult? power = null;
            if (operation.Power is { } existing)
                power = existing.Final ?? await ReviewVirtualMachinePowerAsync(existing, token).ConfigureAwait(false);
            else if (current.State != VirtualMachineOperationalState.Running)
            {
                if (!CanControlPower) return Pending(VirtualMachineCreationStage.PowerOn, MutationErrorCategory.Unsupported);
                if (current.State != VirtualMachineOperationalState.Stopped) return Pending(VirtualMachineCreationStage.PowerOn, MutationErrorCategory.Conflict);
                if (!allowWrite || token.IsCancellationRequested) return Pending(VirtualMachineCreationStage.PowerOn, canContinue: !token.IsCancellationRequested);
                operation.Power = new(operation.Scope, operation.Signature, current.Id, current.Configuration.Name, VirtualMachinePowerAction.PowerOn);
                power = await StartVirtualMachinePowerAsync(operation.Power, token).ConfigureAwait(false);
            }
            if (power is { Status: not MutationResultStatus.ConfirmedSuccess })
            {
                if (power.Status is MutationResultStatus.ConfirmedFailure or MutationResultStatus.PermissionDenied)
                    return FinishVirtualMachineCreation(operation, new(operation.Request.RequestId, VirtualMachineCreationStage.Rejected,
                        new(1, MutationResultStatus.PartialSuccess, CreateVmOperation, true, true, new(completedSteps, 1, 0), power.ErrorCategory), operation.Progress, operation.GuestId));
                return Pending(VirtualMachineCreationStage.VerifyPower, power.ErrorCategory ?? MutationErrorCategory.Unknown);
            }
        }
        return FinishVirtualMachineCreation(operation, new(operation.Request.RequestId, VirtualMachineCreationStage.Complete,
            new(1, MutationResultStatus.ConfirmedSuccess, CreateVmOperation, true, false, new(completedSteps + (operation.Request.PowerOnAfterCreation ? 1 : 0), 0, 0)), operation.Progress, operation.GuestId));
    }
    private VirtualMachineCreationResult FinishVirtualMachineCreation(VirtualMachineCreationOperation operation, VirtualMachineCreationResult result)
    { operation.Final = result; VmMutations.CreationPending.Remove((operation.Scope, operation.Request.Settings.Name.ToUpperInvariant())); return result; }
    private bool HasPendingVirtualMachineCreation(string scope, string id, string name) =>
        VmMutations.CreationPending.Values.Any(operation => operation.Scope == scope && (operation.GuestId == id || string.Equals(operation.Request.Settings.Name, name, StringComparison.OrdinalIgnoreCase)));
    private static string? CreationText(JsonObject value, string key) => value[key] is JsonValue node && node.TryGetValue<string>(out var text) ? text : null;
    private static JsonObject CreatedHardwareIdentity(JsonObject guest)
    {
        var disks = RequiredObjectArray(guest, "vdisks").Select(disk => (JsonNode)new JsonObject
        {
            ["id"] = disk["vdisk_id"]!.DeepClone(), ["size"] = disk["vdisk_size"]!.DeepClone(),
            ["controller"] = disk["controller"]?.DeepClone(), ["unmap"] = disk["unmap"]?.DeepClone()
        }).ToArray();
        var nics = RequiredObjectArray(guest, "vnics").Select(nic =>
        {
            var mac = CreationText(nic, "mac");
            if (!VirtualMachinePowerRules.ValidId(mac)) throw InvalidVirtualMachineManagerResponse();
            return (JsonNode)new JsonObject { ["id"] = nic["vnic_id"]!.DeepClone(), ["network"] = nic["network_id"]!.DeepClone(),
                ["mac"] = mac!.ToUpperInvariant(), ["model"] = nic["model"]?.DeepClone() };
        }).ToArray();
        return new() { ["disks"] = new JsonArray(disks), ["nics"] = new JsonArray(nics) };
    }
    private static bool CreatedVirtualMachineMatches(JsonObject guest, string id, VirtualMachineCreationRequest request)
    {
        if (CreationText(guest, "guest_id") != id || CreationText(guest, "guest_name") != request.Settings.Name || CreationText(guest, "storage_id") != request.Storage.Id ||
            guest["vdisks"] is not JsonArray disks || disks.Count != request.Disks.Count || guest["vnics"] is not JsonArray nics || nics.Count != request.Networks.Count) return false;
        var diskIds = new HashSet<string>(StringComparer.Ordinal); var nicIds = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < disks.Count; index++)
        {
            if (disks[index] is not JsonObject disk || CreationText(disk, "vdisk_id") is not { } diskId || !VirtualMachinePowerRules.ValidId(diskId) || !diskIds.Add(diskId) ||
                disk["vdisk_size"] is not JsonValue sizeValue || !sizeValue.TryGetValue<long>(out var size) || size <= 0 || request.Disks[index].SizeMiB is { } expected && size != expected) return false;
        }
        for (var index = 0; index < nics.Count; index++)
        {
            var expected = request.Networks[index];
            if (nics[index] is not JsonObject nic || CreationText(nic, "vnic_id") is not { } nicId || !VirtualMachinePowerRules.ValidId(nicId) || !nicIds.Add(nicId) ||
                CreationText(nic, "network_id") != (expected.Network?.Id ?? "") || expected.MacAddress is not null && !string.Equals(CreationText(nic, "mac"), expected.MacAddress, StringComparison.OrdinalIgnoreCase)) return false;
        }
        return true;
    }
    private sealed class VirtualMachineCreationOperation(string scope, string signature, VirtualMachineCreationRequest request, HashSet<string> existingIds)
    {
        public string Scope { get; } = scope; public string Signature { get; } = signature; public VirtualMachineCreationRequest Request { get; } = request;
        public HashSet<string> ExistingIds { get; } = existingIds;
        public string? TaskId { get; set; } public string? GuestId { get; set; } public int? Progress { get; set; }
        public bool SettingsSubmitted { get; set; } public bool ConfigurationVerified { get; set; } public VirtualMachineCreationResult? Final { get; set; }
        public VirtualMachinePowerOperation? Power { get; set; }
        public JsonObject? AdvancedParameters { get; set; }
        public bool AdvancedTaskSucceeded { get; set; }
        public bool PublicTaskSucceeded { get; set; }
        public JsonObject? PublicHardware { get; set; }
    }
}
