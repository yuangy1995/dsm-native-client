using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanDeleteNetworks => CanCreateNetworks;
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
        if (!CanDeleteNetworks) return UnsupportedResult(operation);
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
            IReadOnlyList<ContainerNetworkDefinition> current;
            try
            {
                current = await LoadContainerNetworkDefinitionsAsync(token).ConfigureAwait(false);
                foreach (var target in validTargets)
                {
                    var match = current.SingleOrDefault(item => item.Summary.Id == target.Id);
                    if (match is null || !ContainerNetworkDeletionRules.CanDelete(match.Summary) || NetworkDeletionSignature(match.Summary) != NetworkDeletionSignature(target))
                        return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                }
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, NetworkCreationError(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new ContainerNetworkDeleteOperation(scope, signature, request.RequestId, validTargets);
            shared.Operations.Add(request.RequestId, state);
            foreach (var target in validTargets) shared.NetworkDeletions.Add((scope, target.Id), state);
            foreach (var target in validTargets)
            {
                if (token.IsCancellationRequested) break;
                try
                {
                    // 后续项重新读取原目标及占用，前一项失败或未知就停止，刷新绝不继续批次。
                    if (state.AttemptedIds.Count > 0) current = await LoadContainerNetworkDefinitionsAsync(token).ConfigureAwait(false);
                    var selected = current.SingleOrDefault(item => item.Summary.Id == target.Id);
                    if (selected is null || !ContainerNetworkDeletionRules.CanDelete(selected.Summary) ||
                        NetworkDeletionSignature(selected.Summary) != NetworkDeletionSignature(target))
                    { state.Rejections[target.Id] = MutationErrorCategory.Conflict; break; }
                    token.ThrowIfCancellationRequested();
                    var payload = new[] { NetworkRemovalObject(selected) };
                    var capability = _capabilities[InternalObservedNetworkApi] with { MinVersion = 1, MaxVersion = 1 };
                    state.AttemptedIds.Add(target.Id);
                    var response = await SecurityCallAsync(capability, "remove", new Dictionary<string, object> { ["networks"] = payload }, token).ConfigureAwait(false);
                    if (response["failed"] is JsonArray { Count: 0 }) state.AcceptedIds.Add(target.Id);
                    else if (response["failed"] is JsonArray { Count: > 0 }) state.Rejections[target.Id] = MutationErrorCategory.Server;
                    else break;
                    if (state.Rejections.ContainsKey(target.Id)) break;
                    await RefreshContainerNetworkDeletionAsync(state, token).ConfigureAwait(false);
                    if (!state.VerifiedIds.Contains(target.Id)) break;
                }
                catch (DsmException error) when (state.AttemptedIds.Contains(target.Id) && DsmApiClient.IsExplicitApiRejection(error))
                {
                    // 只有写请求的明确拒绝能判定删除失败；回读错误不能改写已接受事实。
                    if (!state.AcceptedIds.Contains(target.Id)) state.Rejections[target.Id] = NetworkCreationError(error);
                    else state.ReadError = NetworkCreationError(error);
                    break;
                }
                catch (DsmException error) { state.ReadError = NetworkCreationError(error); break; }
                catch (Exception) { state.ReadError = MutationErrorCategory.Network; break; }
            }
            foreach (var target in validTargets.Where(target => !state.AttemptedIds.Contains(target.Id) || state.Rejections.ContainsKey(target.Id)))
                shared.NetworkDeletions.Remove((scope, target.Id));
            return await ReviewContainerNetworkDeletionAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }
    public async Task<IReadOnlyList<ContainerNetworkDeletionRecovery>> GetNetworkDeletionRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile(); var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return Array.AsReadOnly(shared.NetworkDeletions.Where(pair => pair.Key.Scope == scope)
            .Select(pair => new ContainerNetworkDeletionRecovery(pair.Key.Id, pair.Value.Targets.Single(target => target.Id == pair.Key.Id).Name)
                { RequestId = pair.Value.RequestId }).ToArray()); }
        finally { shared.Gate.Release(); }
    }
    public async Task<IReadOnlyList<ContainerNetworkDeletionItem>> GetNetworkDeletionItemsAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile(); var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return shared.Operations.TryGetValue(requestId, out var previous) && previous is ContainerNetworkDeleteOperation state && state.Scope == ServiceScope()
                ? state.Targets.Select(target => new ContainerNetworkDeletionItem(state.RequestId, target.Id, target.Name,
                    state.VerifiedIds.Contains(target.Id) ? ContainerNetworkDeletionStage.Deleted :
                    state.Rejections.ContainsKey(target.Id) ? ContainerNetworkDeletionStage.Rejected :
                    state.AcceptedIds.Contains(target.Id) ? ContainerNetworkDeletionStage.Accepted :
                    state.AttemptedIds.Contains(target.Id) ? ContainerNetworkDeletionStage.Submitted : ContainerNetworkDeletionStage.NotSubmitted,
                    state.Rejections.TryGetValue(target.Id, out var error) ? error : null)).ToArray() : [];
        }
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
        if (state.Final is not null) return state.Final;
        MutationResult Finish(MutationResult result)
        {
            state.Final = result;
            foreach (var target in state.Targets) ServiceMutations.NetworkDeletions.Remove((state.Scope, target.Id));
            return result;
        }
        var category = state.ReadError ?? MutationErrorCategory.Unknown;
        if (!token.IsCancellationRequested)
        try
        {
            await RefreshContainerNetworkDeletionAsync(state, token).ConfigureAwait(false);
        }
        catch (DsmException error) { category = NetworkCreationError(error); }
        catch (Exception) { category = MutationErrorCategory.Network; }
        var succeeded = state.VerifiedIds.Count;
        var unknown = state.AttemptedIds.Count(id => !state.VerifiedIds.Contains(id) && !state.Rejections.ContainsKey(id));
        var failed = state.Rejections.Count;
        var notSubmitted = state.Targets.Count - succeeded - unknown - failed;
        if (unknown == 0)
        {
            if (state.AttemptedIds.Count == 0 && failed == 0) return Finish(CancelledBeforeSubmissionResult("deleteContainerNetworks"));
            var status = failed + notSubmitted == 0 ? MutationResultStatus.ConfirmedSuccess : succeeded > 0 ? MutationResultStatus.PartialSuccess :
                state.Rejections.Values.Any(error => error == MutationErrorCategory.Permission) ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure;
            return Finish(new(1, status, "deleteContainerNetworks", state.AttemptedIds.Count > 0, false,
                new(succeeded, failed + (succeeded > 0 ? notSubmitted : 0), 0), state.Rejections.Values.Cast<MutationErrorCategory?>().FirstOrDefault(),
                diagnosticTag: status == MutationResultStatus.ConfirmedSuccess ? "container.network.deleted" : "container.network.delete.stopped"));
        }
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission :
            succeeded > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified,
            "deleteContainerNetworks", true, true, new(succeeded, failed + (succeeded > 0 ? notSubmitted : 0), unknown), category,
            diagnosticTag: "container.network.delete.unverified");
    }
    private async Task RefreshContainerNetworkDeletionAsync(ContainerNetworkDeleteOperation state, CancellationToken token)
    {
        if (!state.AcceptedIds.Except(state.VerifiedIds).Any()) return;
        var current = await LoadContainerNetworkDefinitionsAsync(token).ConfigureAwait(false);
        foreach (var id in state.AcceptedIds)
            if (!current.Any(item => item.Summary.Id == id))
            { state.VerifiedIds.Add(id); ServiceMutations.NetworkDeletions.Remove((state.Scope, id)); }
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
    private sealed class ContainerNetworkDeleteOperation(string scope, string signature, Guid requestId, IReadOnlyList<ContainerResourceSummary> targets)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.ContainerNetworks)
    {
        public Guid RequestId { get; } = requestId;
        public IReadOnlyList<ContainerResourceSummary> Targets { get; } = targets;
        public HashSet<string> VerifiedIds { get; } = new(StringComparer.Ordinal);
        public HashSet<string> AttemptedIds { get; } = new(StringComparer.Ordinal);
        public HashSet<string> AcceptedIds { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, MutationErrorCategory> Rejections { get; } = new(StringComparer.Ordinal);
        public MutationErrorCategory? ReadError { get; set; }
    }
}
