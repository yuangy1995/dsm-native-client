using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> MutateDdnsAsync(NasDdnsMutationRequest request, string? password = null,
        CancellationToken cancellationToken = default) => NasSettingsWriteAvailability.CanSaveDDNS
        ? ExecuteDdnsMutationAsync(request, password, cancellationToken) : Task.FromResult(UnsupportedResult("ddnsMutation"));

    internal async Task<MutationResult> ExecuteDdnsMutationAsync(NasDdnsMutationRequest request, string? password = null,
        CancellationToken token = default)
    {
        const string operation = "ddnsMutation";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.ProfileId != _profile.Id || _profile.Id != _session.ProfileId ||
            request.RequestId == Guid.Empty || !request.RiskConfirmed || string.IsNullOrWhiteSpace(_session.Sid) ||
            !NasDdnsMutationRules.IsValid(request, password)) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        // 外部集合在首次 await 前复制；密码不保存在确认快照、共享协调器或哈希中。
        request = request with { ExpectedProviderIds = Array.AsReadOnly(request.ExpectedProviderIds.ToArray()) };
        var capability = DdnsWriteCapability();
        if (capability is null) return UnsupportedResult(operation);
        var scope = ServiceScope();
        var signature = ServiceHash(JsonSerializer.Serialize(request));
        var shared = ServiceMutations;
        try
        {
            if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
        }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
            {
                if (previous.Scope != scope || previous.Signature != signature)
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                return previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false);
            }
            if (shared.Pending.ContainsKey((scope, NasServiceSettingsKind.Ddns)))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var providers = await LoadDDNSProvidersAsync(token).ConfigureAwait(false);
                var records = await LoadDDNSRecordsAsync(token).ConfigureAwait(false);
                if (!DdnsPreflightMatches(request, providers, records))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }

            var state = new NasDdnsOperation(scope, signature, request)
            {
                // 仅换密码时，配置列表本来就相同；丢失确认不能靠原配置声称密码已保存。
                NeedsCredentialAcknowledgement = request.Action == NasDdnsAction.Save && !string.IsNullOrEmpty(password) &&
                    request.Desired!.ProviderId != "Synology" && request.Baseline is { } original &&
                    DdnsSavedFieldsMatch(original, request.Desired),
            };
            shared.Operations.Add(request.RequestId, state); shared.Pending.Add((scope, state.Kind), state);
            var parameters = DdnsWriteParameters(request, password);
            password = null;
            try
            {
                await SecurityCallAsync(capability, request.Action switch
                {
                    NasDdnsAction.Test => "test", NasDdnsAction.Delete => "delete",
                    NasDdnsAction.UpdateAddress => "update_ip_address", _ => request.Baseline is null ? "create" : "set",
                }, parameters, token).ConfigureAwait(false);
                state.Accepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { state.Rejection = ServiceErrorCategory(error); }
            catch (Exception) { /* 发送开始后的断线或取消不能证明未生效，不重放。 */ }
            finally { parameters.Clear(); }
            return await ReviewDdnsOperationAsync(state, token).ConfigureAwait(false);
        }
        finally { password = null; shared.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewDdnsOperationAsync(NasDdnsOperation state, CancellationToken token)
    {
        const string operation = "ddnsMutation";
        MutationResult Finish(MutationResult result)
        {
            state.Final = result; ServiceMutations.Pending.Remove((state.Scope, state.Kind)); return result;
        }
        MutationResult Unknown() => new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission :
            MutationResultStatus.SubmittedButUnverified, operation, true, true, new(0, 0, 1), MutationErrorCategory.Network,
            diagnosticTag: "ddns.result-unverified");
        MutationResult Success(string tag) => new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0), diagnosticTag: tag);
        if (state.Rejection is { } rejection)
            return Finish(new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied :
                MutationResultStatus.ConfirmedFailure, operation, true, false, new(0, 1, 0), rejection));
        // test 没有可回读结果，update 丢失确认也不能从列表推断 DNS 更新已被接受。
        // 缓存最终“未知”防同请求重发，但不把无法核对的瞬时操作永久挂起。
        if (state.Request.Action == NasDdnsAction.Test)
            return Finish(state.Accepted && !token.IsCancellationRequested ? Success("ddns.test.accepted") : Unknown());
        if (state.Request.Action == NasDdnsAction.UpdateAddress && !state.Accepted) return Finish(Unknown());
        if (token.IsCancellationRequested) return Unknown();
        IReadOnlyList<NasDDNSRecord> records;
        try { records = await LoadDDNSRecordsAsync(token).ConfigureAwait(false); }
        catch (Exception) { return Unknown(); }
        if (state.Request.Action == NasDdnsAction.UpdateAddress) return Finish(Success("ddns.update.accepted-not-dns-propagation"));
        var provider = state.Request.Baseline?.ProviderId ?? state.Request.Desired!.ProviderId;
        var record = records.FirstOrDefault(item => item.ProviderId == provider);
        var matches = state.Request.Action == NasDdnsAction.Delete ? record is null :
            record is not null && DdnsSavedFieldsMatch(record, state.Request.Desired!);
        if (matches && (!state.NeedsCredentialAcknowledgement || state.Accepted))
            return Finish(Success(state.Request.Action == NasDdnsAction.Delete ? "ddns.delete.verified" : "ddns.save.verified"));
        // 不匹配可能是延迟应用，不能把未知保存/删除解锁后再发一次。
        return Unknown();
    }

    private ApiCapability? DdnsWriteCapability() => SecurityCapability("SYNO.Core.DDNS.Provider", 1) is not null
        ? SecurityCapability("SYNO.Core.DDNS.Record", 1) : null;


    private static bool DdnsPreflightMatches(NasDdnsMutationRequest request, IReadOnlyList<NasDDNSProvider> providers,
        IReadOnlyList<NasDDNSRecord> records)
    {
        if (request.Action == NasDdnsAction.UpdateAddress)
            return records.Select(item => item.ProviderId).ToHashSet(StringComparer.Ordinal).SetEquals(request.ExpectedProviderIds);
        var id = request.Baseline?.ProviderId ?? request.Desired!.ProviderId;
        if (!providers.Any(item => item.Id == id)) return false;
        var current = records.FirstOrDefault(item => item.ProviderId == id);
        if (request.Baseline is null) return current is null;
        // 公网地址/上次更新时间会自行变化，不作为用户配置冲突；已知配置必须匹配。
        return current is not null && DdnsSavedFieldsMatch(current, request.Baseline) &&
            current.NetworkType == request.Baseline.NetworkType && current.InterfaceV4 == request.Baseline.InterfaceV4 &&
            current.InterfaceV6 == request.Baseline.InterfaceV6;
    }

    private static bool DdnsSavedFieldsMatch(NasDDNSRecord actual, NasDDNSRecord desired) =>
        actual.ProviderId == desired.ProviderId && string.Equals(actual.Hostname, desired.Hostname, StringComparison.OrdinalIgnoreCase) &&
        actual.Username == desired.Username && actual.IsEnabled == desired.IsEnabled && actual.Heartbeat == desired.Heartbeat;

    private static Dictionary<string, object> DdnsWriteParameters(NasDdnsMutationRequest request, string? password)
    {
        if (request.Action == NasDdnsAction.UpdateAddress) return [];
        if (request.Action == NasDdnsAction.Delete) return new() { ["id"] = new[] { request.Baseline!.ProviderId } };
        var value = request.Desired!;
        var result = new Dictionary<string, object>
        {
            ["provider"] = value.ProviderId, ["hostname"] = value.Hostname, ["username"] = value.Username,
            ["enable"] = value.IsEnabled, ["heartbeat"] = value.Heartbeat,
        };
        foreach (var (key, field) in new[] { ("net", value.NetworkType), ("ip", value.ExternalIp), ("ipv6", value.Ipv6),
            ("interface_v4", value.InterfaceV4), ("interface_v6", value.InterfaceV6) })
            if (field is not null) result[key] = field;
        if (request.Baseline is { } original) result["id"] = original.ProviderId;
        if (value.ProviderId == "Synology") result["passwd"] = "Synology";
        else if (!string.IsNullOrEmpty(password)) result["passwd"] = password;
        return result;
    }

    private sealed class NasDdnsOperation(string scope, string signature, NasDdnsMutationRequest request)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Ddns)
    {
        public NasDdnsMutationRequest Request { get; } = request;
        public bool Accepted { get; set; }
        public bool NeedsCredentialAcknowledgement { get; init; }
        public MutationErrorCategory? Rejection { get; set; }
    }
}
