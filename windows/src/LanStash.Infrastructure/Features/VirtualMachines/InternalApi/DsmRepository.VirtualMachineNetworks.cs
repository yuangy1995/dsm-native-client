using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string ManagedNetworkApi = "SYNO.Virtualization.Network";
    private const string NetworkOperation = "virtualMachineNetwork";
    public bool CanReadNetworkManagement => HasAuthenticatedVirtualMachineSession && HasInternalVirtualMachineVersion(ManagedNetworkApi, 2, 2);
    public bool CanManageNetworks => CanReadNetworkManagement && HasInternalVirtualMachineVersion(ManagedNetworkApi, 1, 1);

    private Task<JsonObject> CallManagedNetworkAsync(string method, int version, Dictionary<string, object>? parameters, CancellationToken token) =>
        SecurityCallAsync(_capabilities[ManagedNetworkApi] with { MinVersion = version, MaxVersion = version }, method, parameters ?? new(), token);

    public async Task<VirtualMachineNetworkInventory> LoadNetworkManagementAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        if (!CanReadNetworkManagement) throw UnavailableVirtualMachineManagerError();
        var inventory = await ReadNetworkListAsync(cancellationToken).ConfigureAwait(false);
        var networks = new List<VirtualMachineNetwork>();
        foreach (var (network, count) in inventory.Networks)
            networks.Add(await ReadNetworkGuestsAsync(network, count, cancellationToken).ConfigureAwait(false));
        return new(inventory.Frozen, networks.AsReadOnly());
    }

    private async Task<(bool Frozen, IReadOnlyList<(VirtualMachineNetwork Network, int GuestCount)> Networks)> ReadNetworkListAsync(CancellationToken token)
    {
        var data = await CallManagedNetworkAsync("list", 2, null, token).ConfigureAwait(false);
        var frozen = NetworkBoolean(data, "is_freeze");
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var networks = new List<(VirtualMachineNetwork, int)>();
        foreach (var item in RequiredObjectArray(data, "networks"))
        {
            var interfaces = RequiredObjectArray(item, "interfaces").Select(value =>
                new VirtualMachineNetworkInterface(NetworkText(value, "host_id"), NetworkText(value, "interface_id"))).ToArray();
            var network = new VirtualMachineNetwork(NetworkText(item, "network_id"), NetworkText(item, "name"),
                NetworkText(item, "type"), NetworkText(item, "host_id", true), NetworkNumber(item, "vlan_id"), interfaces, []);
            var guestCount = NetworkNumber(item, "num_guests");
            if (!VirtualMachineNetworkRules.Valid(network) || !ids.Add(network.Id) || !names.Add(network.Name) ||
                NetworkNumber(item, "num_interfaces") != interfaces.Length) throw InvalidVirtualMachineManagerResponse();
            networks.Add((VirtualMachineNetworkRules.Freeze(network), guestCount));
        }
        token.ThrowIfCancellationRequested();
        return (frozen, networks);
    }

    private async Task<VirtualMachineNetwork> ReadNetworkGuestsAsync(VirtualMachineNetwork network, int count, CancellationToken token)
    {
        var detail = await CallManagedNetworkAsync("get", 2, new() { ["network_id"] = network.Id }, token).ConfigureAwait(false);
        if (NetworkText(detail, "name") != network.Name) throw InvalidVirtualMachineManagerResponse();
        var guests = RequiredObjectArray(detail, "guests").Select(item => new VirtualMachineNetworkGuest(
            NetworkText(item, "guest_id"), NetworkText(item, "name"), NetworkBoolean(item, "running"),
            NetworkBoolean(item, "prefer_sriov"), NetworkBoolean(item, "use_vf"))).ToArray();
        var result = network with { Guests = guests };
        if (guests.Length != count || !VirtualMachineNetworkRules.Valid(result)) throw InvalidVirtualMachineManagerResponse();
        token.ThrowIfCancellationRequested();
        return VirtualMachineNetworkRules.Freeze(result);
    }

    public async Task<MutationResult> MutateNetworkAsync(VirtualMachineNetworkRequest request, CancellationToken cancellationToken = default)
    {
        if (cancellationToken.IsCancellationRequested) return CancelledBeforeSubmissionResult(NetworkOperation);
        if (!CanManageNetworks) return UnsupportedResult(NetworkOperation);
        if (request is null || request.ProfileId != _profile.Id || request.RequestId == Guid.Empty || !request.RiskConfirmed ||
            !VirtualMachineNetworkRules.Valid(request.Baseline) || !Enum.IsDefined(request.Action) ||
            request.Action == VirtualMachineNetworkAction.Rename && (!VirtualMachineNetworkRules.ValidName(request.NewName) || request.NewName == request.Baseline.Name) ||
            request.Action == VirtualMachineNetworkAction.Delete && request.NewName is not null)
            return ServicePreflightFailure(NetworkOperation, MutationErrorCategory.Validation);
        request = request with { Baseline = VirtualMachineNetworkRules.Freeze(request.Baseline) };
        var state = VmMutations; var scope = ServiceScope();
        var signature = ServiceHash(JsonSerializer.Serialize(new { request.Baseline, request.Action, request.NewName }));
        try { if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure(NetworkOperation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(NetworkOperation); }
        try
        {
            if (state.ImageImportOperations.ContainsKey(request.RequestId) || state.PowerOperations.ContainsKey(request.RequestId) || state.SettingsOperations.ContainsKey(request.RequestId) ||
                state.CreationOperations.ContainsKey(request.RequestId) || state.DeletionOperations.ContainsKey(request.RequestId) || state.TaskCleanupOperations.ContainsKey(request.RequestId))
                return ServicePreflightFailure(NetworkOperation, MutationErrorCategory.Conflict, true);
            if (state.NetworkOperations.TryGetValue(request.RequestId, out var prior))
                return prior.Scope == scope && prior.Signature == signature ? prior.Final ?? await ReviewNetworkCoreAsync(prior, cancellationToken).ConfigureAwait(false) :
                    ServicePreflightFailure(NetworkOperation, MutationErrorCategory.Conflict, true);
            if (state.NetworkPending.ContainsKey((scope, request.Baseline.Id)) ||
                state.CreationPending.Values.Any(item => item.Scope == scope && item.Request.Networks.Any(nic => nic.Network?.Id == request.Baseline.Id)) ||
                request.Baseline.Guests.Any(guest => state.PowerPending.ContainsKey((scope, guest.Id)) || state.SettingsPending.ContainsKey((scope, guest.Id)) || state.DeletionPending.ContainsKey((scope, guest.Id))))
                return ServicePreflightFailure(NetworkOperation, MutationErrorCategory.Conflict, true);
            try
            {
                var inventory = await ReadNetworkListAsync(cancellationToken).ConfigureAwait(false);
                var target = inventory.Networks.SingleOrDefault(item => item.Network.Id == request.Baseline.Id);
                if (inventory.Frozen || target.Network is null ||
                    request.Action == VirtualMachineNetworkAction.Rename && inventory.Networks.Any(item => item.Network.Id != target.Network.Id && string.Equals(item.Network.Name, request.NewName, StringComparison.OrdinalIgnoreCase)))
                    return ServicePreflightFailure(NetworkOperation, MutationErrorCategory.Conflict, true);
                var current = await ReadNetworkGuestsAsync(target.Network, target.GuestCount, cancellationToken).ConfigureAwait(false);
                if (!VirtualMachineNetworkRules.Same(current, request.Baseline)) return ServicePreflightFailure(NetworkOperation, MutationErrorCategory.Conflict, true);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(NetworkOperation); }
            catch (DsmException error) { return ServicePreflightFailure(NetworkOperation, VirtualMachinePowerError(error)); }
            catch { return ServicePreflightFailure(NetworkOperation, MutationErrorCategory.Network); }
            var operation = new VirtualMachineNetworkOperation(scope, signature, request);
            state.NetworkOperations.Add(request.RequestId, operation); state.NetworkPending.Add((scope, request.Baseline.Id), operation);
            var parameters = new Dictionary<string, object> { ["network_id"] = request.Baseline.Id };
            if (request.Action == VirtualMachineNetworkAction.Rename)
            {
                parameters["name"] = request.NewName!;
                if (request.Baseline.Type == "external")
                {
                    parameters["interfaces_add"] = Array.Empty<object>(); parameters["interfaces_remove"] = Array.Empty<object>();
                }
                else parameters["host_id"] = request.Baseline.HostId;
            }
            try { await CallManagedNetworkAsync(request.Action == VirtualMachineNetworkAction.Delete ? "delete" : "set", 1, parameters, cancellationToken).ConfigureAwait(false); }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { operation.Rejection = VirtualMachinePowerError(error); }
            catch { /* 写后不明只核查，不重放；取消也不回滚已提交的网络操作。 */ }
            return await ReviewNetworkCoreAsync(operation, cancellationToken).ConfigureAwait(false);
        }
        finally { state.Gate.Release(); }
    }

    public async Task<IReadOnlyList<VirtualMachineNetworkRecovery>> GetNetworkRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations; await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return state.NetworkPending.Values.Where(item => item.Scope == scope).Select(item => new VirtualMachineNetworkRecovery(item.Request.Baseline.Id, item.Request.Baseline.Name, item.Request.Action)).ToArray(); }
        finally { state.Gate.Release(); }
    }

    public async Task<MutationResult?> ReviewNetworkAsync(string id, CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); if (!CanReadNetworkManagement) return UnsupportedResult(NetworkOperation);
        var state = VmMutations;
        try { if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure(NetworkOperation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(NetworkOperation); }
        try { return state.NetworkPending.TryGetValue((ServiceScope(), id), out var pending) ? await ReviewNetworkCoreAsync(pending, cancellationToken).ConfigureAwait(false) : null; }
        finally { state.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewNetworkCoreAsync(VirtualMachineNetworkOperation pending, CancellationToken token)
    {
        MutationResult Finish(MutationResult result) { pending.Final = result; VmMutations.NetworkPending.Remove((pending.Scope, pending.Request.Baseline.Id)); return result; }
        if (pending.Rejection is { } rejection) return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
            NetworkOperation, true, true, new(0, 1, 0), rejection));
        var category = MutationErrorCategory.Unknown;
        if (!token.IsCancellationRequested)
        try
        {
            var inventory = await ReadNetworkListAsync(token).ConfigureAwait(false);
            var actual = inventory.Networks.SingleOrDefault(item => item.Network.Id == pending.Request.Baseline.Id);
            var baseline = pending.Request.Baseline;
            var confirmed = pending.Request.Action == VirtualMachineNetworkAction.Delete ? actual.Network is null :
                actual.Network is not null && actual.Network.Name == pending.Request.NewName &&
                actual.Network.Type == baseline.Type && actual.Network.HostId == baseline.HostId && actual.Network.VlanId == baseline.VlanId && actual.Network.Interfaces.SequenceEqual(baseline.Interfaces);
            if (!inventory.Frozen && confirmed) return Finish(new(1, MutationResultStatus.ConfirmedSuccess, NetworkOperation, true, false, new(1, 0, 0)));
        }
        catch (DsmException error) { category = VirtualMachinePowerError(error); }
        catch { category = MutationErrorCategory.Network; }
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            NetworkOperation, true, true, new(0, 0, 1), category, diagnosticTag: "virtual-machine.network.unverified");
    }

    private bool HasPendingNetworkForMachine(string scope, string id) => VmMutations.NetworkPending.Values.Any(item => item.Scope == scope && item.Request.Baseline.Guests.Any(guest => guest.Id == id));
    private static string NetworkText(JsonObject value, string key, bool allowEmpty = false) => value[key] is JsonValue node && node.TryGetValue<string>(out var text) &&
        (allowEmpty || !string.IsNullOrWhiteSpace(text)) ? text : throw InvalidVirtualMachineManagerResponse();
    private static int NetworkNumber(JsonObject value, string key) => value[key] is JsonValue node && node.TryGetValue<int>(out var number) && number >= 0 ? number : throw InvalidVirtualMachineManagerResponse();
    private static bool NetworkBoolean(JsonObject value, string key) => value[key] is JsonValue node && node.TryGetValue<bool>(out var boolean) ? boolean : throw InvalidVirtualMachineManagerResponse();
    private sealed class VirtualMachineNetworkOperation(string scope, string signature, VirtualMachineNetworkRequest request)
    {
        public string Scope { get; } = scope; public string Signature { get; } = signature; public VirtualMachineNetworkRequest Request { get; } = request;
        public MutationResult? Final { get; set; } public MutationErrorCategory? Rejection { get; set; }
    }
}
