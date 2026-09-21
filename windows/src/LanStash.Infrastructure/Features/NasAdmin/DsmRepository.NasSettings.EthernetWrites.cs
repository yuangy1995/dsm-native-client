using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> SaveEthernetSettingsAsync(NasServiceSettingsSaveRequest<NasEthernetInterface> request,
        CancellationToken cancellationToken = default) => NasSettingsWriteAvailability.CanSaveNetwork
            ? ExecuteEthernetSettingsWriteAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("saveNetwork"));

    internal async Task<MutationResult> ExecuteEthernetSettingsWriteAsync(
        NasServiceSettingsSaveRequest<NasEthernetInterface> request, CancellationToken token = default)
    {
        const string operation = "saveNetwork";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || request.Desired is null || !request.RiskConfirmed ||
            request.RequestId == Guid.Empty || request.ProfileId != _profile.Id || _profile.Id != _session.ProfileId ||
            string.IsNullOrWhiteSpace(_session.Sid) || request.Baseline.Id != request.Desired.Id ||
            !NasEthernetSettingsRules.IsComplete(request.Baseline) || !NasEthernetSettingsRules.IsValid(request.Desired))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var baseline = request.Baseline with { DnsServers = Array.AsReadOnly(request.Baseline.DnsServers.ToArray()) };
        var desired = request.Desired with { DnsServers = Array.AsReadOnly(request.Desired.DnsServers.ToArray()) };
        var original = EthernetConfig(baseline); var target = EthernetConfig(desired);
        if (ConfigSignature(original) == ConfigSignature(target)) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var capability = EthernetCapability();
        if (capability is null) return UnsupportedResult(operation);
        var signature = ServiceHash(JsonSerializer.Serialize(new { kind = NasServiceSettingsKind.Ethernet, original, target }));
        var scope = ServiceScope(); var owner = EthernetOwner(); var shared = ServiceMutations;
        try
        {
            if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
        }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var existing))
            {
                if (existing is not NasEthernetOperation prior || prior.Owner != owner || prior.Signature != signature)
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                return prior.Final ?? await ReviewEthernetOperationAsync(prior, false, token).ConfigureAwait(false);
            }
            if (FindPendingEthernet() is not null) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var current = (await LoadEthernetSnapshotCoreAsync(token).ConfigureAwait(false)).Interfaces.SingleOrDefault(item => item.Id == baseline.Id);
                if (current is null || !NasEthernetSettingsRules.IsComplete(current) || ConfigSignature(EthernetConfig(current)) != ConfigSignature(original))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new NasEthernetOperation(scope, signature, owner, ServiceHash(_session.Sid), desired, capability);
            shared.Operations.Add(request.RequestId, state); shared.Pending.Add((scope, state.Kind), state);
            try
            {
                await _api.CallAsync(_profile, _session, capability with { MinVersion = 1, MaxVersion = 1 }, "set",
                    new Dictionary<string, string> { ["configs"] = JsonSerializer.Serialize(new[] { target }) }, token).ConfigureAwait(false);
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { state.Rejection = ServiceErrorCategory(error); }
            catch (Exception) { }
            return await ReviewEthernetOperationAsync(state, false, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<NasEthernetRecoveryInfo?> GetEthernetRecoveryAsync(CancellationToken cancellationToken = default)
    {
        await ServiceMutations.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = FindPendingEthernet();
            if (state is null) return null;
            var moved = state.Scope != ServiceScope();
            return new(state.Desired.Id, moved && state.SessionHash == ServiceHash(_session.Sid),
                moved && state.ApprovedRecovery != RecoverySignature());
        }
        finally { ServiceMutations.Gate.Release(); }
    }

    public async Task<MutationResult?> ReviewEthernetSettingsAsync(bool sameNasConfirmed = false, CancellationToken cancellationToken = default)
    {
        await ServiceMutations.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var state = FindPendingEthernet();
            return state is null ? null : await ReviewEthernetOperationAsync(state, sameNasConfirmed, cancellationToken).ConfigureAwait(false);
        }
        finally { ServiceMutations.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewEthernetOperationAsync(NasEthernetOperation state, bool sameNasConfirmed, CancellationToken token)
    {
        const string operation = "saveNetwork";
        if (state.Owner != EthernetOwner() || _profile.Id != _session.ProfileId || string.IsNullOrWhiteSpace(_session.Sid))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        if (state.Scope != ServiceScope())
        {
            // 新地址只能使用用户重新登录得到的新会话，绝不把旧 SID 自动转发过去。
            if (state.SessionHash == ServiceHash(_session.Sid))
                return ServicePreflightFailure(operation, MutationErrorCategory.Authentication, true);
            if (!sameNasConfirmed && state.ApprovedRecovery != RecoverySignature())
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            state.ApprovedRecovery = RecoverySignature();
        }
        if (token.IsCancellationRequested) return CancellationRequestedAfterSubmissionResult(operation);
        try
        {
            var json = state.Capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase);
            var detail = await _api.CallReadJsonObjectAsync(_profile, _session, state.Capability, 1, "get",
                new Dictionary<string, string> { ["ifname"] = json ? JsonSerializer.Serialize(state.Desired.Id) : state.Desired.Id }, token).ConfigureAwait(false);
            var current = ParseEthernetInterface(state.Desired.Id, detail, new());
            if (state.Rejection is { } rejection)
            {
                var denied = new MutationResult(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied :
                    MutationResultStatus.ConfirmedFailure, operation, true, false, new(0, 1, 0), rejection);
                state.Final = denied; ServiceMutations.Pending.Remove((state.Scope, state.Kind)); return denied;
            }
            if (NasEthernetSettingsRules.IsComplete(current) && ConfigSignature(EthernetConfig(current)) == ConfigSignature(EthernetConfig(state.Desired)))
            {
                var result = ConfirmedSuccessResult(operation);
                state.Final = result; ServiceMutations.Pending.Remove((state.Scope, state.Kind)); return result;
            }
        }
        catch (Exception) { }
        return token.IsCancellationRequested ? CancellationRequestedAfterSubmissionResult(operation) : SubmittedButUnverifiedResult(operation);
    }

    private NasEthernetOperation? FindPendingEthernet() => ServiceMutations.Pending.Values.OfType<NasEthernetOperation>()
        .FirstOrDefault(item => item.Owner == EthernetOwner() && item.Final is null);
    private string EthernetOwner() => ServiceHash(JsonSerializer.Serialize(new { _profile.Id, _profile.Username }));
    private string RecoverySignature() => ServiceHash(ServiceScope() + ServiceHash(_session.Sid));
    private ApiCapability? EthernetCapability() => _capabilities.TryGetValue("SYNO.Core.Network.Ethernet", out var value) &&
        value.Name == "SYNO.Core.Network.Ethernet" && value.MinVersion == 1 && value.MaxVersion >= 2 &&
        NasServiceFormatAndPathSupported(value) ? value with { Path = "entry.cgi" } : null;
    private static string ConfigSignature(SortedDictionary<string, object?> value) => JsonSerializer.Serialize(value);
    private static SortedDictionary<string, object?> EthernetConfig(NasEthernetInterface value)
    {
        var result = new SortedDictionary<string, object?>(StringComparer.Ordinal)
        {
            ["ifname"] = value.Id, ["use_dhcp"] = value.DhcpEnabled, ["is_default_gateway"] = value.IsDefaultGateway,
            ["mtu"] = value.Mtu, ["enable_vlan"] = value.VlanEnabled,
        };
        if (!value.DhcpEnabled)
        {
            result["ip"] = value.IpAddress; result["mask"] = value.SubnetMask;
            result["gateway"] = value.Gateway; result["dns"] = value.ReportedDns;
        }
        if (value.VlanEnabled == true) result["vlan_id"] = value.VlanId;
        return result;
    }
    private sealed class NasEthernetOperation(string scope, string signature, string owner, string sessionHash,
        NasEthernetInterface desired, ApiCapability capability) : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Ethernet)
    {
        public string Owner { get; } = owner;
        public string SessionHash { get; } = sessionHash;
        public NasEthernetInterface Desired { get; } = desired;
        public ApiCapability Capability { get; } = capability;
        public MutationErrorCategory? Rejection { get; set; }
        public string? ApprovedRecovery { get; set; }
    }
}
