using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 无确认上下文的旧调用不允许产生电源副作用。
    public Task<MutationResult> ExecutePowerActionAsync(NasPowerAction action, CancellationToken cancellationToken = default) =>
        Task.FromResult(Enum.IsDefined(action) ? UnsupportedResult(PowerOperationName(action)) : ServicePreflightFailure("powerAction", MutationErrorCategory.Validation));

    public Task<MutationResult> ExecutePowerActionAsync(NasPowerRequest request, CancellationToken cancellationToken = default) =>
        NasSettingsWriteAvailability.CanPowerAction ? ExecutePowerRequestAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("powerAction"));

    internal async Task<MutationResult> ExecutePowerRequestAsync(NasPowerRequest request, CancellationToken token = default)
    {
        var operation = request is null ? "powerAction" : PowerOperationName(request.Action);
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || !Enum.IsDefined(request.Action) || request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id ||
            request.RequestId == Guid.Empty || !request.RiskConfirmed || string.IsNullOrWhiteSpace(_session.Sid))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var capability = PowerCapability();
        if (capability is null) return UnsupportedResult(operation);
        var shared = ServiceMutations; var scope = ServiceScope(); var signature = ServiceHash("power:" + request.Action);
        try
        {
            if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
        }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
                return previous.Scope == scope && previous.Signature == signature ? previous.Final! : ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (shared.Pending.ContainsKey((scope, NasServiceSettingsKind.Power))) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                await _api.CallReadJsonObjectAsync(_profile, _session, capability, 3, "info", cancellationToken: token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }

            // 只存高熵会话标识的不可逆摘要，用于阻止同一会话直接解除待核对状态。
            var state = new NasPowerOperation(scope, signature, request.Action, ServiceHash(_session.Sid));
            shared.Operations.Add(request.RequestId, state); shared.Pending.Add((scope, state.Kind), state);
            try
            {
                await _api.CallAsync(_profile, _session, capability, operation, cancellationToken: token).ConfigureAwait(false);
                state.Final = new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(1, 0, 0),
                    diagnosticTag: "power." + operation + ".accepted");
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && error.Code is (102 or 103 or 104 or 105 or 106 or 107 or 119 or 404 or 408 or 900))
            {
                var category = ServiceErrorCategory(error);
                state.Final = new(1, category == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                    operation, true, false, new(0, 1, 0), category);
                shared.Pending.Remove((scope, state.Kind));
            }
            catch (Exception)
            {
                state.Final = new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified,
                    operation, true, true, new(0, 0, 1), MutationErrorCategory.Network, diagnosticTag: "power.result-unverified");
            }
            // 不回读、不轮询在线状态，不把连接中断当成关机/重启完成。
            return state.Final;
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<NasPowerRecoveryInfo?> GetPowerRecoveryAsync(CancellationToken cancellationToken = default)
    {
        if (_profile.Id != _session.ProfileId) throw InvalidNasServiceSettings();
        var shared = ServiceMutations; await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return shared.Pending.TryGetValue((ServiceScope(), NasServiceSettingsKind.Power), out var value) && value is NasPowerOperation state
                ? new(state.Action, state.Final!, !string.IsNullOrWhiteSpace(_session.Sid) && ServiceHash(_session.Sid) != state.SessionHash) : null;
        }
        finally { shared.Gate.Release(); }
    }

    public async Task<bool> AcknowledgePowerRecoveryAsync(bool deviceChecked, CancellationToken cancellationToken = default)
    {
        if (!deviceChecked || _profile.Id != _session.ProfileId || string.IsNullOrWhiteSpace(_session.Sid)) return false;
        var shared = ServiceMutations;
        if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return false;
        try
        {
            var key = (ServiceScope(), NasServiceSettingsKind.Power);
            if (!shared.Pending.TryGetValue(key, out var value) || value is not NasPowerOperation state || ServiceHash(_session.Sid) == state.SessionHash) return false;
            var capability = PowerCapability(); if (capability is null) return false;
            await PrepareServiceSettingsAsync(cancellationToken).ConfigureAwait(false);
            if (!_nasServiceAdministrator) return false;
            await _api.CallReadJsonObjectAsync(_profile, _session, capability, 3, "info", cancellationToken: cancellationToken).ConfigureAwait(false);
            // 这是用户检查设备之后的本地确认，不是从 info 证明最终电源状态。
            shared.Pending.Remove(key); return true;
        }
        finally { shared.Gate.Release(); }
    }
    private ApiCapability? PowerCapability() => SecurityCapability("SYNO.Core.System", 3);
    private static string PowerOperationName(NasPowerAction action) => action switch { NasPowerAction.Shutdown => "shutdown", NasPowerAction.Reboot => "reboot", _ => "powerAction" };
    private sealed class NasPowerOperation(string scope, string signature, NasPowerAction action, string sessionHash)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Power)
    {
        public NasPowerAction Action { get; } = action;
        public string SessionHash { get; } = sessionHash;
    }
}
