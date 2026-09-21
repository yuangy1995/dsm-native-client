using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanDeleteNetworks => _nasServiceSessionVerified &&
        HasInternalObservedContainerVersion(InternalObservedNetworkApi);
    public Task<MutationResult> DeleteNetworksAsync(ContainerNetworkDeleteRequest request, CancellationToken cancellationToken = default) =>
        CanDeleteNetworks ? DeleteContainerNetworksCoreAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("deleteContainerNetworks"));

    internal async Task<MutationResult> DeleteContainerNetworksCoreAsync(ContainerNetworkDeleteRequest request, CancellationToken token = default)
    {
        const string operation = "deleteContainerNetworks";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baselines is null || request.Baselines.Count == 0 || !request.RiskConfirmed || request.RequestId == Guid.Empty ||
            request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id || string.IsNullOrWhiteSpace(_session.Sid))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var targets = request.Baselines.Select(target => target is null ? null : target with
        {
            Network = target.Network is null ? null : target.Network with
            { ConnectedContainerNames = target.Network.ConnectedContainerNames is null ? null : Array.AsReadOnly(target.Network.ConnectedContainerNames.ToArray()) }
        }).ToArray();
        if (targets.Any(target => target is null || !ContainerNetworkDeletionRules.CanDelete(target)) ||
            targets.Select(target => target!.Id).Distinct(StringComparer.Ordinal).Count() != targets.Length)
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var validTargets = targets.Select(target => target!).ToArray();
        if (!HasInternalObservedContainerVersion(InternalObservedNetworkApi)) return UnsupportedResult(operation);
        var scope = ServiceScope(); var shared = ServiceMutations;
        var signature = ServiceHash(JsonSerializer.Serialize(new { Operation = operation, Targets = validTargets.OrderBy(target => target.Id, StringComparer.Ordinal).Select(NetworkDeletionSignature) }));
        try { if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var prior))
                return prior.Scope == scope && prior.Signature == signature ? prior.Final ?? await ReviewNasSettingsOperationAsync(prior, token).ConfigureAwait(false) :
                    ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (validTargets.Any(target => shared.NetworkDeletions.ContainsKey((scope, target.Id)) || shared.NetworkCreations.ContainsKey((scope, target.Name))))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            Dictionary<string, object>[] payload;
            try
            {
                await PrepareNetworkManagementAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                var current = await LoadContainerNetworkDefinitionsAsync(token).ConfigureAwait(false);
                var selected = new List<ContainerNetworkDefinition>();
                foreach (var target in validTargets)
                {
                    var match = current.SingleOrDefault(item => item.Summary.Id == target.Id);
                    if (match is null || !ContainerNetworkDeletionRules.CanDelete(match.Summary) || NetworkDeletionSignature(match.Summary) != NetworkDeletionSignature(target))
                        return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                    selected.Add(match);
                }
                payload = selected.Select(NetworkRemovalObject).ToArray();
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, NetworkCreationError(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new ContainerNetworkDeleteOperation(scope, signature, validTargets);
            shared.Operations.Add(request.RequestId, state);
            foreach (var target in validTargets) shared.NetworkDeletions.Add((scope, target.Id), state);
            try
            {
                var capability = _capabilities[InternalObservedNetworkApi] with { MinVersion = 1, MaxVersion = 1 };
                var response = await SecurityCallAsync(capability, "remove", new Dictionary<string, object> { ["networks"] = payload }, token).ConfigureAwait(false);
                // 非空或畸形 failed 不提供可靠逐项归属，只按完整回读确认消失的原 ID。
                state.EmptyFailureList = response["failed"] is JsonArray { Count: 0 };
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { state.Rejection = NetworkCreationError(error); }
            catch (Exception) { /* 可能已删除，后续只读核对，不重放。 */ }
            return await ReviewContainerNetworkDeletionAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }
    public async Task<IReadOnlyList<ContainerNetworkDeletionRecovery>> GetNetworkDeletionRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile(); var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return Array.AsReadOnly(shared.NetworkDeletions.Where(pair => pair.Key.Scope == scope)
            .Select(pair => pair.Value.Targets.Single(target => target.Id == pair.Key.Id)).Select(target => new ContainerNetworkDeletionRecovery(target.Id, target.Name)).ToArray()); }
        finally { shared.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewNetworkDeletionAsync(string id, CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile();
        if (string.IsNullOrWhiteSpace(id)) return ServicePreflightFailure("deleteContainerNetworks", MutationErrorCategory.Validation);
        var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("deleteContainerNetworks", MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("deleteContainerNetworks"); }
        try { return shared.NetworkDeletions.TryGetValue((ServiceScope(), id), out var state) ? await ReviewContainerNetworkDeletionAsync(state, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewContainerNetworkDeletionAsync(ContainerNetworkDeleteOperation state, CancellationToken token)
    {
        MutationResult Finish(MutationResult result)
        {
            state.Final = result;
            foreach (var target in state.Targets) ServiceMutations.NetworkDeletions.Remove((state.Scope, target.Id));
            return result;
        }
        if (state.Rejection is { } rejection)
            return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                "deleteContainerNetworks", true, true, new(0, state.Targets.Count, 0), rejection));
        var category = MutationErrorCategory.Unknown;
        if (!token.IsCancellationRequested)
        try
        {
            var current = await LoadContainerNetworkDefinitionsAsync(token).ConfigureAwait(false);
            foreach (var target in state.Targets)
                if (!current.Any(item => item.Summary.Id == target.Id))
                {
                    state.VerifiedIds.Add(target.Id);
                    ServiceMutations.NetworkDeletions.Remove((state.Scope, target.Id));
                }
        }
        catch (DsmException error) { category = NetworkCreationError(error); }
        catch (Exception) { category = MutationErrorCategory.Network; }
        var succeeded = state.VerifiedIds.Count; var unknown = state.Targets.Count - succeeded;
        if (unknown == 0) return Finish(new(1, MutationResultStatus.ConfirmedSuccess, "deleteContainerNetworks", true, false, new(succeeded, 0, 0), diagnosticTag: "container.network.deleted"));
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission :
            succeeded > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified,
            "deleteContainerNetworks", true, true, new(succeeded, 0, unknown), category,
            diagnosticTag: state.EmptyFailureList ? "container.network.delete.unverified" : "container.network.delete.response-unverified");
    }
    private static string NetworkDeletionSignature(ContainerResourceSummary target) => JsonSerializer.Serialize(new
    {
        target.Id, target.Name, target.Network!.Driver, target.Network.ConnectedContainerCount,
        target.Network.ConnectedContainerNames, target.Network.Subnet, target.Network.Gateway, target.Network.IpRange, target.Network.IsIpv6Enabled
    });
    private static Dictionary<string, object> NetworkRemovalObject(ContainerNetworkDefinition definition)
    {
        var network = definition.Summary; var raw = definition.Raw;
        var result = new Dictionary<string, object>
        {
            ["id"] = network.Id, ["_key"] = network.Id, ["name"] = network.Name, ["driver"] = network.Network!.Driver!,
            ["containers"] = Array.Empty<string>(), ["enable_ipv6"] = network.Network.IsIpv6Enabled!.Value,
            ["disable_masquerade"] = DirectoryBoolean(raw["disable_masquerade"]) ?? false
        };
        foreach (var key in new[] { "subnet", "gateway", "iprange", "ipv6_subnet", "ipv6_gateway", "ipv6_iprange" })
            result[key] = DirectoryText(raw[key]) ?? "";
        return result;
    }
    private sealed class ContainerNetworkDeleteOperation(string scope, string signature, IReadOnlyList<ContainerResourceSummary> targets)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.ContainerNetworks)
    {
        public IReadOnlyList<ContainerResourceSummary> Targets { get; } = targets;
        public HashSet<string> VerifiedIds { get; } = new(StringComparer.Ordinal);
        public bool EmptyFailureList { get; set; }
        public MutationErrorCategory? Rejection { get; set; }
    }
}
