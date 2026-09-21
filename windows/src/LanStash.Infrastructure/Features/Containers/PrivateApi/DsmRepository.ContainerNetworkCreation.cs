using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanCreateNetworks => _nasServiceSessionVerified &&
        HasInternalObservedContainerVersion(InternalObservedNetworkApi);
    public async Task PrepareNetworkManagementAsync(CancellationToken cancellationToken = default) =>
        _ = await PrepareServiceSettingsAsync(cancellationToken).ConfigureAwait(false);
    public Task<MutationResult> CreateNetworkAsync(ContainerNetworkCreateRequest request, CancellationToken cancellationToken = default) =>
        CanCreateNetworks ? CreateContainerNetworkCoreAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("createContainerNetwork"));

    internal async Task<MutationResult> CreateContainerNetworkCoreAsync(ContainerNetworkCreateRequest request, CancellationToken token = default)
    {
        const string operation = "createContainerNetwork";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Configuration is null || request.Configuration.ValidationIssue != ContainerNetworkValidationIssue.None ||
            request.RequestId == Guid.Empty || !request.RiskConfirmed || request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id || string.IsNullOrWhiteSpace(_session.Sid))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        if (!HasInternalObservedContainerVersion(InternalObservedNetworkApi)) return UnsupportedResult(operation);
        var configuration = request.Configuration;
        var shared = ServiceMutations; var scope = ServiceScope();
        var signature = ServiceHash(JsonSerializer.Serialize(new { Kind = NasServiceSettingsKind.ContainerNetworks, configuration }));
        try { if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
                return previous.Scope == scope && previous.Signature == signature ? previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false) :
                    ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (shared.NetworkCreations.TryGetValue((scope, configuration.Name), out var pending))
            {
                if (pending.Signature != signature) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                shared.Operations.Add(request.RequestId, pending);
                return await ReviewContainerNetworkCreationAsync(pending, token).ConfigureAwait(false);
            }
            if (shared.NetworkDeletions.Any(pair => pair.Key.Scope == scope && pair.Value.Targets.Any(target => target.Id == pair.Key.Id && target.Name == configuration.Name)))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            IReadOnlyList<ContainerNetworkDefinition> before;
            try
            {
                await PrepareNetworkManagementAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                // 先核对实际列表读取权限；创建权限由 NAS 裁决，不假定只有管理员可创建。
                before = await LoadContainerNetworkDefinitionsAsync(token).ConfigureAwait(false);
                if (before.Any(network => network.Summary.Name == configuration.Name))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, NetworkCreationError(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new ContainerNetworkCreateOperation(scope, signature, configuration, before.Select(network => network.Summary.Id).ToHashSet(StringComparer.Ordinal));
            shared.Operations.Add(request.RequestId, state); shared.NetworkCreations.Add((scope, configuration.Name), state);
            var parameters = new Dictionary<string, object>
            { ["name"] = configuration.Name, ["enable_ipv6"] = configuration.IsIpv6Enabled, ["disable_masquerade"] = configuration.DisableMasquerade };
            if (configuration.UsesManualIpv4)
            {
                parameters["subnet"] = configuration.Subnet; parameters["iprange"] = configuration.IpRange; parameters["gateway"] = configuration.Gateway;
            }
            if (configuration.IsIpv6Enabled)
            {
                parameters["ipv6_subnet"] = configuration.Ipv6Subnet; parameters["ipv6_iprange"] = configuration.Ipv6Range; parameters["ipv6_gateway"] = configuration.Ipv6Gateway;
            }
            try
            {
                var capability = _capabilities[InternalObservedNetworkApi] with { MinVersion = 1, MaxVersion = 1 };
                await SecurityCallAsync(capability, "create", parameters, token).ConfigureAwait(false);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { state.Rejection = NetworkCreationError(error); }
            catch (Exception) { /* 可能已创建，随后只能读取；不得重放。 */ }
            return await ReviewContainerNetworkCreationAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }
    public async Task<IReadOnlyList<ContainerNetworkCreationRecovery>> GetNetworkCreationRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile(); var shared = ServiceMutations;
        await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return Array.AsReadOnly(shared.NetworkCreations.Values.Where(state => state.Scope == ServiceScope()).Select(state => new ContainerNetworkCreationRecovery(state.Configuration.Name)).ToArray()); }
        finally { shared.Gate.Release(); }
    }
    public async Task<MutationResult?> ReviewNetworkCreationAsync(string name, CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile();
        if (new ContainerNetworkCreation(name).ValidationIssue != ContainerNetworkValidationIssue.None) return ServicePreflightFailure("createContainerNetwork", MutationErrorCategory.Validation);
        var shared = ServiceMutations;
        try { if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return ServicePreflightFailure("createContainerNetwork", MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult("createContainerNetwork"); }
        try { return shared.NetworkCreations.TryGetValue((ServiceScope(), name), out var state) ? await ReviewContainerNetworkCreationAsync(state, cancellationToken).ConfigureAwait(false) : null; }
        finally { shared.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewContainerNetworkCreationAsync(ContainerNetworkCreateOperation state, CancellationToken token)
    {
        MutationResult Finish(MutationResult result) { state.Final = result; ServiceMutations.NetworkCreations.Remove((state.Scope, state.Configuration.Name)); return result; }
        if (state.Rejection is { } rejection)
            return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                "createContainerNetwork", true, true, new(0, 1, 0), rejection));
        var category = MutationErrorCategory.Unknown; var optionsUnknown = false;
        if (!token.IsCancellationRequested)
        try
        {
            var networks = await LoadContainerNetworkDefinitionsAsync(token).ConfigureAwait(false);
            var matches = networks.Where(item => item.Summary.Name == state.Configuration.Name).ToArray();
            if (matches.Length == 1 && !state.PreviousIds.Contains(matches[0].Summary.Id) && CreatedNetworkMatches(state.Configuration, matches[0]))
            {
                // 当前记录没有可依赖的 IPv6 地址及 IP 伪装回读字段，不把高级选项假装核对成功。
                optionsUnknown = state.Configuration.IsIpv6Enabled || state.Configuration.DisableMasquerade;
                if (!optionsUnknown) return Finish(new(1, MutationResultStatus.ConfirmedSuccess, "createContainerNetwork", true, false, new(1, 0, 0), diagnosticTag: "container.network.created"));
            }
        }
        catch (DsmException error) { category = NetworkCreationError(error); }
        catch (Exception) { category = MutationErrorCategory.Network; }
        return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
            "createContainerNetwork", true, true, new(0, 0, 1), category,
            diagnosticTag: optionsUnknown ? "container.network.created-options-unverified" : "container.network.create.unverified");
    }
    private async Task<IReadOnlyList<ContainerNetworkDefinition>> LoadContainerNetworkDefinitionsAsync(CancellationToken token)
    {
        EnsureContainerManagerProfile();
        if (!HasInternalObservedContainerVersion(InternalObservedNetworkApi)) throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        var data = await CallInternalObservedContainerAsync(InternalObservedNetworkApi, "list", null, token).ConfigureAwait(false);
        if (data["network"] is not null && data["networks"] is not null && !JsonNode.DeepEquals(data["network"], data["networks"])) throw InvalidContainerManagerResponse();
        var rows = RequiredContainerObjectArray(data, ["network", "networks"]);
        var summaries = ParseContainerResources(data, ContainerResourceKind.Network, ["network", "networks"], ["id", "network_id", "Id"], ["name", "Name"]);
        if (ContainerPageNumber(data, "total") is int total && total != rows.Count) throw InvalidContainerManagerResponse();
        var result = new List<ContainerNetworkDefinition>();
        for (var index = 0; index < rows.Count; index++)
        {
            var row = rows[index]; var summary = summaries[index];
            if (NativeNetworkString(row, "id", "network_id", "Id") != summary.Id || NativeNetworkString(row, "name", "Name") != summary.Name) throw InvalidContainerManagerResponse();
            result.Add(new(summary, row));
        }
        return result.AsReadOnly();
    }
    private static bool CreatedNetworkMatches(ContainerNetworkCreation desired, ContainerNetworkDefinition actual)
    {
        var details = actual.Summary.Network;
        if (details?.Driver != "bridge" || details.IsIpv6Enabled != desired.IsIpv6Enabled) return false;
        if (!desired.UsesManualIpv4) return true;
        var range = NativeNetworkString(actual.Raw, "iprange");
        return details.Subnet is not null && ContainerNetworkCreation.EquivalentIpv4Cidr(desired.Subnet, details.Subnet) &&
            details.Gateway == desired.Gateway && range is not null &&
            (desired.IpRange.Length == 0 ? range.Length == 0 : ContainerNetworkCreation.EquivalentIpv4Cidr(desired.IpRange, range));
    }
    private static string? NativeNetworkString(JsonObject row, params string[] keys)
    {
        string? result = null;
        foreach (var key in keys)
        {
            if (row[key] is null) continue;
            if (row[key] is not JsonValue value || !value.TryGetValue<string>(out var text) || text.Any(char.IsControl) || result is not null && result != text) return null;
            result = text;
        }
        return result;
    }
    private static MutationErrorCategory NetworkCreationError(DsmException error) => error.AuthenticationFailure ? MutationErrorCategory.Authentication :
        error.Code == 105 ? MutationErrorCategory.Permission : error.Code is 102 or 103 or 104 ? MutationErrorCategory.Unsupported :
        error.Code is null ? MutationErrorCategory.Unknown : MutationErrorCategory.Server;
    private sealed record ContainerNetworkDefinition(ContainerResourceSummary Summary, JsonObject Raw);
    private sealed class ContainerNetworkCreateOperation(string scope, string signature, ContainerNetworkCreation configuration, HashSet<string> previousIds)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.ContainerNetworks)
    {
        public ContainerNetworkCreation Configuration { get; } = configuration;
        public HashSet<string> PreviousIds { get; } = previousIds;
        public MutationErrorCategory? Rejection { get; set; }
    }
}
