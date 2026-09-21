using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanEditSettings => HasAuthenticatedVirtualMachineSession && HasPublicVirtualMachineVersion(PublicGuestApi);
    public async Task<VirtualMachineSettings> LoadSettingsAsync(string id, CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!VirtualMachinePowerRules.ValidId(id)) throw new ArgumentException("vm.settings.id.invalid", nameof(id));
        if (!HasPublicVirtualMachineVersion(PublicGuestApi)) throw UnavailableVirtualMachineManagerError();
        var data = await SecurityCallAsync(_capabilities[PublicGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "get",
            new Dictionary<string, object> { ["guest_id"] = id }, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        return await AddVirtualMachinePriorityAsync(ParseVirtualMachineSettings(data, id), cancellationToken).ConfigureAwait(false);
    }
    private static VirtualMachineSettings ParseVirtualMachineSettings(JsonObject data, string id)
    {
        string Text(string key, bool empty = false) => data[key] is JsonValue value && value.TryGetValue<string>(out var text) &&
            (empty || !string.IsNullOrWhiteSpace(text)) ? text : throw InvalidVirtualMachineManagerResponse();
        int Number(string key) => data[key] is JsonValue value && value.TryGetValue<int>(out var number) ? number : throw InvalidVirtualMachineManagerResponse();
        if (Text("guest_id") != id) throw InvalidVirtualMachineManagerResponse();
        var cpu = Number("vcpu_num"); var memory = Number("vram_size"); var startup = Number("autorun");
        if (cpu <= 0 || memory <= 0 || startup is < 0 or > 2) throw InvalidVirtualMachineManagerResponse();
        return new(id, ParseMachineState(Text("status")), new(Text("guest_name"), Text("description", true), cpu, memory, (VirtualMachineAutoStart)startup));
    }
    public Task<MutationResult> SaveSettingsAsync(VirtualMachineSettingsRequest request, CancellationToken cancellationToken = default) =>
        CanEditSettings ? SaveVirtualMachineSettingsCoreAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("saveVirtualMachineSettings"));

    internal async Task<MutationResult> SaveVirtualMachineSettingsCoreAsync(VirtualMachineSettingsRequest request, CancellationToken token = default)
    {
        const string operation = "saveVirtualMachineSettings";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.ProfileId != _profile.Id || request.ProfileId != _session.ProfileId || string.IsNullOrWhiteSpace(_session.Sid) ||
            !request.RiskConfirmed || request.RequestId == Guid.Empty || VirtualMachineSettingsRules.Validate(request.Baseline, request.Desired) != VirtualMachineSettingsValidation.None ||
            request.Baseline.Configuration == request.Desired) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        if (!HasPublicVirtualMachineVersion(PublicGuestApi)) return UnsupportedResult(operation);
        var useInternal = request.Desired.CpuWeight != request.Baseline.Configuration.CpuWeight;
        if (useInternal && !CanEditPriority) return UnsupportedResult(operation);
        var state = VmMutations; var scope = ServiceScope(); var signature = ServiceHash(JsonSerializer.Serialize(new { request.Baseline, request.Desired }));
        try { if (!await state.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (state.TaskCleanupOperations.ContainsKey(request.RequestId) || state.DeletionOperations.ContainsKey(request.RequestId) || state.PowerOperations.ContainsKey(request.RequestId) || state.CreationOperations.ContainsKey(request.RequestId)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.NetworkOperations.ContainsKey(request.RequestId) || state.ImageImportOperations.ContainsKey(request.RequestId)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.SettingsOperations.TryGetValue(request.RequestId, out var prior))
                return prior.Scope == scope && prior.Signature == signature ? prior.Final ?? await ReviewVirtualMachineSettingsAsync(prior, token).ConfigureAwait(false) :
                    ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (HasPendingNetworkForMachine(scope, request.Baseline.Id)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (state.DeletionPending.ContainsKey((scope, request.Baseline.Id)) || state.PowerPending.ContainsKey((scope, request.Baseline.Id)) || state.SettingsPending.ContainsKey((scope, request.Baseline.Id)) ||
                HasPendingVirtualMachineCreation(scope, request.Baseline.Id, request.Baseline.Configuration.Name) || HasPendingVirtualMachineCreation(scope, request.Baseline.Id, request.Desired.Name))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                var current = await LoadSettingsAsync(request.Baseline.Id, token).ConfigureAwait(false);
                if (!useInternal) current = current with { Configuration = current.Configuration with { CpuWeight = request.Baseline.Configuration.CpuWeight } };
                if (current != request.Baseline) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                if (current.Configuration.Name != request.Desired.Name)
                {
                    var data = await CallPublicVirtualMachineAsync(PublicGuestApi, "list", null, token).ConfigureAwait(false);
                    var machines = ParseMachines(data);
                    if (machines.Any(machine => machine.Id != current.Id && string.Equals(machine.Name, request.Desired.Name, StringComparison.OrdinalIgnoreCase)))
                        return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                }
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, VirtualMachinePowerError(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var changes = ChangedVirtualMachineFields(request.Baseline.Configuration, request.Desired);
            var pending = new VirtualMachineSettingsOperation(scope, signature, request.Baseline.Id, request.Desired.Name, changes, useInternal);
            state.SettingsOperations.Add(request.RequestId, pending); state.SettingsPending.Add((scope, pending.Id), pending);
            var parameters = useInternal ? InternalVirtualMachineChanges(changes, request.RequestId) : new Dictionary<string, object>(changes);
            parameters["guest_id"] = pending.Id;
            try
            {
                await SecurityCallAsync(_capabilities[useInternal ? InternalSettingsGuestApi : PublicGuestApi] with { MinVersion = 1, MaxVersion = 1 }, "set", parameters, token).ConfigureAwait(false);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { pending.Rejection = VirtualMachinePowerError(error); }
            catch (Exception) { /* 请求可能已保存，随后只读核查。 */ }
            return await ReviewVirtualMachineSettingsAsync(pending, token).ConfigureAwait(false);
        }
        finally { state.Gate.Release(); }
    }
    public async Task<IReadOnlyList<VirtualMachineSettingsRecovery>> GetSettingsRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations; await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return state.SettingsPending.Values.Where(item => item.Scope == scope).Select(item => new VirtualMachineSettingsRecovery(item.Id, item.Name)).ToArray(); }
        finally { state.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewSettingsAsync(string id, CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); if (!VirtualMachinePowerRules.ValidId(id)) return ServicePreflightFailure("saveVirtualMachineSettings", MutationErrorCategory.Validation);
        var state = VmMutations;
        try { if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("saveVirtualMachineSettings", MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("saveVirtualMachineSettings"); }
        try { return state.SettingsPending.TryGetValue((ServiceScope(), id), out var pending) ? await ReviewVirtualMachineSettingsAsync(pending, cancellationToken).ConfigureAwait(false) : null; }
        finally { state.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewVirtualMachineSettingsAsync(VirtualMachineSettingsOperation pending, CancellationToken token)
    {
        MutationResult Finish(MutationResult result) { pending.Final = result; VmMutations.SettingsPending.Remove((pending.Scope, pending.Id)); return result; }
        if (pending.Rejection is { } rejection)
            return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                "saveVirtualMachineSettings", true, true, new(0, pending.Changes.Count, 0), rejection));
        var succeeded = 0; var category = MutationErrorCategory.Unknown;
        if (!token.IsCancellationRequested)
        try
        {
            var readback = pending.UseInternal ? await ReadInternalVirtualMachineSettingsAsync(pending.Id, token).ConfigureAwait(false) : await LoadSettingsAsync(pending.Id, token).ConfigureAwait(false);
            var actual = VirtualMachineFields(readback.Configuration);
            succeeded = pending.Changes.Count(pair => actual.TryGetValue(pair.Key, out var value) && Equals(value, pair.Value));
        }
        catch (DsmException error) { category = VirtualMachinePowerError(error); }
        catch (Exception) { category = MutationErrorCategory.Network; }
        var unknown = pending.Changes.Count - succeeded;
        if (unknown == 0) return Finish(new(1, MutationResultStatus.ConfirmedSuccess, "saveVirtualMachineSettings", true, false, new(succeeded, 0, 0)));
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : succeeded > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified,
            "saveVirtualMachineSettings", true, true, new(succeeded, 0, unknown), category, diagnosticTag: "virtual-machine.settings.unverified");
    }
    private static Dictionary<string, object> VirtualMachineFields(VirtualMachineConfiguration value)
    {
        var fields = new Dictionary<string, object> { ["new_guest_name"] = value.Name, ["description"] = value.Description, ["vcpu_num"] = value.CpuCount, ["vram_size"] = value.MemoryMiB, ["autorun"] = (int)value.AutoStart };
        if (value.CpuWeight is { } weight) fields["cpu_weight"] = weight;
        return fields;
    }
    private static Dictionary<string, object> ChangedVirtualMachineFields(VirtualMachineConfiguration baseline, VirtualMachineConfiguration desired)
    {
        var previous = VirtualMachineFields(baseline);
        return VirtualMachineFields(desired).Where(pair => !previous.TryGetValue(pair.Key, out var value) || !Equals(value, pair.Value)).ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);
    }
    private sealed class VirtualMachineSettingsOperation(string scope, string signature, string id, string name, Dictionary<string, object> changes, bool useInternal)
    {
        public string Scope { get; } = scope; public string Signature { get; } = signature;
        public string Id { get; } = id; public string Name { get; } = name;
        public Dictionary<string, object> Changes { get; } = changes;
        public bool UseInternal { get; } = useInternal;
        public MutationErrorCategory? Rejection { get; set; }
        public MutationResult? Final { get; set; }
    }
}
