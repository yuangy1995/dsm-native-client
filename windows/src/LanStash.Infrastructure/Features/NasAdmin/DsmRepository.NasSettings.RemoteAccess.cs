using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static readonly NasRemoteAccessParts[] RemoteAccessParts = [NasRemoteAccessParts.Relay, NasRemoteAccessParts.Router];
    private ApiCapability? RemoteAccessCapability(NasRemoteAccessParts part) =>
        SecurityCapability(part == NasRemoteAccessParts.Relay ? "SYNO.Core.QuickConnect" : "SYNO.Core.QuickConnect.Upnp", part == NasRemoteAccessParts.Relay ? 3 : 1);
    private bool CanDisableCurrentRelay => !DsmQuickConnectResolver.IsTrustedRelayHost(_api.GetBaseUri(_profile).Host);

    public async Task<NasRemoteAccessSettings> LoadRemoteAccessSettingsAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var result = new NasRemoteAccessSettings(null, null, CanDisableCurrentRelay); var discovered = false;
        foreach (var part in RemoteAccessParts)
        {
            var api = part == NasRemoteAccessParts.Relay ? "SYNO.Core.QuickConnect" : "SYNO.Core.QuickConnect.Upnp";
            if (!_capabilities.ContainsKey(api)) continue;
            discovered = true;
            try
            {
                var capability = RemoteAccessCapability(part) ?? throw InvalidNasServiceSettings();
                var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, part == NasRemoteAccessParts.Relay ? 3 : 1,
                    part == NasRemoteAccessParts.Relay ? "get_misc_config" : "get", cancellationToken: cancellationToken).ConfigureAwait(false);
                var enabled = DirectoryBoolean(data[part == NasRemoteAccessParts.Relay ? "relay_enabled" : "enabled"]) ?? throw InvalidNasServiceSettings();
                result = part == NasRemoteAccessParts.Relay ? result with { RelayEnabled = enabled } : result with { RouterConfigurationEnabled = enabled };
                result = result with { AvailableParts = result.AvailableParts | part };
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (DsmException error) when (error.AuthenticationFailure) { throw; }
            catch (Exception) { result = result with { FailedParts = result.FailedParts | part }; }
        }
        if (!discovered) throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        return result;
    }
    public Task<MutationResult> SaveRemoteAccessSettingsAsync(NasServiceSettingsSaveRequest<NasRemoteAccessSettings> request,
        CancellationToken cancellationToken = default) => NasSettingsWriteAvailability.CanSaveRemoteAccess ?
        ExecuteRemoteAccessWriteAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("saveRemoteAccess"));

    internal async Task<MutationResult> ExecuteRemoteAccessWriteAsync(NasServiceSettingsSaveRequest<NasRemoteAccessSettings> request, CancellationToken token = default)
    {
        const string operation = "saveRemoteAccess";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || request.Desired is null || !request.RiskConfirmed || request.RequestId == Guid.Empty ||
            request.ProfileId != _profile.Id || _profile.Id != _session.ProfileId || string.IsNullOrWhiteSpace(_session.Sid) ||
            !NasRemoteAccessRules.IsValidChange(request.Baseline, request.Desired))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var baseline = request.Baseline; var desired = request.Desired;
        if (!CanDisableCurrentRelay && desired.RelayEnabled == false && baseline.RelayEnabled != false)
            return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
        var steps = new List<RemoteAccessWriteStep>();
        foreach (var part in RemoteAccessParts)
        {
            if (NasRemoteAccessRules.Value(baseline, part) == NasRemoteAccessRules.Value(desired, part)) continue;
            var capability = RemoteAccessCapability(part); if (capability is null) return UnsupportedResult(operation);
            steps.Add(new(part, capability, NasRemoteAccessRules.Value(desired, part)!.Value));
        }
        var shared = ServiceMutations; var scope = ServiceScope();
        var signature = ServiceHash(JsonSerializer.Serialize(new { Kind = NasServiceSettingsKind.RemoteAccess, baseline, desired }));
        try { if (!await shared.Gate.WaitAsync(0, token).ConfigureAwait(false)) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true); }
        catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
        try
        {
            if (shared.Operations.TryGetValue(request.RequestId, out var previous))
                return previous.Scope == scope && previous.Signature == signature ? previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false) :
                    ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            if (shared.Pending.ContainsKey((scope, NasServiceSettingsKind.RemoteAccess))) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var current = await LoadRemoteAccessSettingsAsync(token).ConfigureAwait(false);
                if (steps.Any(step => !current.AvailableParts.HasFlag(step.Part) || current.FailedParts.HasFlag(step.Part) ||
                    NasRemoteAccessRules.Value(current, step.Part) != NasRemoteAccessRules.Value(baseline, step.Part)))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new NasRemoteAccessOperation(scope, signature, steps);
            shared.Operations.Add(request.RequestId, state); shared.Pending.Add((scope, state.Kind), state);
            foreach (var step in steps)
            {
                if (token.IsCancellationRequested) break;
                step.Submitted = true;
                try
                {
                    await SecurityCallAsync(step.Capability, step.Part == NasRemoteAccessParts.Relay ? "set_misc_config" : "set",
                        new Dictionary<string, object> { [step.Part == NasRemoteAccessParts.Relay ? "relay_enabled" : "enabled"] = step.Desired }, token).ConfigureAwait(false);
                }
                catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && error.Code is (102 or 103 or 104 or 105 or 106 or 107 or 119 or 404 or 408 or 900))
                { step.Rejection = ServiceErrorCategory(error); break; }
                catch (Exception) { break; }
            }
            return await ReviewRemoteAccessOperationAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }
    private async Task<MutationResult> ReviewRemoteAccessOperationAsync(NasRemoteAccessOperation state, CancellationToken token)
    {
        MutationResult Finish(MutationResult result) { state.Final = result; ServiceMutations.Pending.Remove((state.Scope, state.Kind)); return result; }
        if (state.Steps.All(step => !step.Submitted)) return Finish(CancelledBeforeSubmissionResult("saveRemoteAccess"));
        NasRemoteAccessSettings? current = null; MutationErrorCategory? errorCategory = null;
        try { current = await LoadRemoteAccessSettingsAsync(token).ConfigureAwait(false); }
        catch (DsmException error) { errorCategory = ServiceErrorCategory(error); }
        catch (Exception) { errorCategory = MutationErrorCategory.Network; }
        int succeeded = 0, failed = 0, unknown = 0;
        foreach (var step in state.Steps)
        {
            if (!step.Submitted) { failed++; continue; }
            if (step.Rejection is { } rejection) { failed++; errorCategory = rejection; continue; }
            if (current is not null && current.AvailableParts.HasFlag(step.Part) && !current.FailedParts.HasFlag(step.Part) &&
                NasRemoteAccessRules.Value(current, step.Part) == step.Desired) succeeded++;
            else unknown++;
        }
        var status = succeeded == state.Steps.Count ? MutationResultStatus.ConfirmedSuccess :
            token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission :
            succeeded > 0 ? MutationResultStatus.PartialSuccess : unknown > 0 ? MutationResultStatus.SubmittedButUnverified :
            errorCategory == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure;
        var result = new MutationResult(1, status, "saveRemoteAccess", true, status != MutationResultStatus.ConfirmedSuccess,
            new(succeeded, failed, unknown), errorCategory ?? (unknown > 0 ? MutationErrorCategory.Unknown : null));
        return unknown == 0 ? Finish(result) : result;
    }
    private sealed class RemoteAccessWriteStep(NasRemoteAccessParts part, ApiCapability capability, bool desired)
    {
        public NasRemoteAccessParts Part { get; } = part; public ApiCapability Capability { get; } = capability;
        public bool Desired { get; } = desired; public bool Submitted { get; set; } public MutationErrorCategory? Rejection { get; set; }
    }
    private sealed class NasRemoteAccessOperation(string scope, string signature, List<RemoteAccessWriteStep> steps)
        : NasSettingsOperation(scope, signature, NasServiceSettingsKind.RemoteAccess)
    { public List<RemoteAccessWriteStep> Steps { get; } = steps; }
}
