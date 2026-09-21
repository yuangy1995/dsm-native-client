using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> SaveHardwareSettingsAsync(NasServiceSettingsSaveRequest<NasHardwareSettings> request,
        CancellationToken cancellationToken = default) => NasSettingsWriteAvailability.CanSaveHardware
            ? ExecuteHardwareSettingsWriteAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("saveHardware"));

    internal async Task<MutationResult> ExecuteHardwareSettingsWriteAsync(NasServiceSettingsSaveRequest<NasHardwareSettings> request,
        CancellationToken token = default)
    {
        const string operation = "saveHardware";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || request.Desired is null || !request.RiskConfirmed ||
            request.ProfileId != _profile.Id || _profile.Id != _session.ProfileId || request.RequestId == Guid.Empty ||
            string.IsNullOrWhiteSpace(_session.Sid) || !NasHardwareSettingsRules.IsValidChange(request.Baseline, request.Desired))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var baseline = request.Baseline; var desired = request.Desired;
        var steps = new List<HardwareWriteStep>();
        foreach (var (name, section) in HardwareReadGroups)
        {
            var before = NasHardwareSettingsRules.Fields(baseline, section); var after = NasHardwareSettingsRules.Fields(desired, section);
            var changes = after.Where(pair => !Equals(before.GetValueOrDefault(pair.Key), pair.Value)).ToDictionary(pair => pair.Key, pair => pair.Value);
            if (changes.Count == 0) continue;
            var capability = SecurityCapability(name, 1);
            if (capability is null) return UnsupportedResult(operation);
            if (section == NasHardwareSections.Ups)
            {
                changes["enable"] = desired.Ups!.Enabled; changes["mode"] = desired.Ups.Mode;
                if (desired.Ups.DelaySeconds is int delay) changes["delay_time"] = delay;
            }
            steps.Add(new(section, capability, changes));
        }
        if (steps.Count == 0) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var signature = ServiceHash(JsonSerializer.Serialize(new { kind = NasServiceSettingsKind.Hardware, baseline, desired }));
        var scope = ServiceScope(); var shared = ServiceMutations;
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
                if (previous.Scope != scope || previous.Signature != signature) return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                return previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false);
            }
            if (shared.Pending.ContainsKey((scope, NasServiceSettingsKind.Hardware)))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var current = await LoadHardwareSettingsAsync(token).ConfigureAwait(false);
                if (current.FailedSections != NasHardwareSections.None || current.AvailableSections != baseline.AvailableSections ||
                    current.LedMinimum != baseline.LedMinimum || current.LedMaximum != baseline.LedMaximum ||
                    current.Beep?.VolumeFieldName != baseline.Beep?.VolumeFieldName ||
                    HardwareReadGroups.Any(group => !HardwareFieldsMatch(current, baseline, group.Section)))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new NasHardwareOperation(scope, signature, desired, steps);
            shared.Operations.Add(request.RequestId, state); shared.Pending.Add((scope, state.Kind), state);
            foreach (var step in steps)
            {
                if (token.IsCancellationRequested) break;
                step.Submitted = true;
                try
                {
                    await SecurityCallAsync(step.Capability, step.Section == NasHardwareSections.Led ? "set_current_brightness" : "set", step.Parameters, token).ConfigureAwait(false);
                    if (step.Section == NasHardwareSections.Led)
                    {
                        token.ThrowIfCancellationRequested();
                        step.UpdateSubmitted = true;
                        await SecurityCallAsync(step.Capability, "update", new(), token).ConfigureAwait(false);
                        step.UpdateAccepted = true;
                    }
                }
                catch (DsmException error) when (!step.UpdateSubmitted && DsmApiClient.IsExplicitApiRejection(error))
                { step.Rejection = ServiceErrorCategory(error); break; }
                catch (Exception) { break; }
            }
            if (!steps.Any(step => step.Submitted))
            {
                shared.Operations.Remove(request.RequestId); shared.Pending.Remove((scope, state.Kind));
                return CancelledBeforeSubmissionResult(operation);
            }
            return await ReviewHardwareOperationAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewHardwareOperationAsync(NasHardwareOperation state, CancellationToken token)
    {
        const string operation = "saveHardware";
        var submitted = state.Steps.Count(step => step.Submitted);
        NasHardwareSettings current;
        try { current = await LoadHardwareSettingsAsync(token).ConfigureAwait(false); }
        catch (Exception)
        {
            return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission :
                MutationResultStatus.SubmittedButUnverified, operation, true, true,
                new(0, state.Steps.Count - submitted, submitted), MutationErrorCategory.Network);
        }
        var succeeded = 0; var failed = 0; var unknown = 0; MutationErrorCategory? rejection = null;
        foreach (var step in state.Steps)
        {
            if (!step.Submitted) { failed++; continue; }
            if (step.Rejection is { } category) { failed++; rejection = category; continue; }
            if (!current.AvailableSections.HasFlag(step.Section) || current.FailedSections.HasFlag(step.Section) ||
                step.Section == NasHardwareSections.Led && !step.UpdateAccepted) { unknown++; continue; }
            var actual = NasHardwareSettingsRules.Fields(current, step.Section);
            if (step.Parameters.Keys.Any(key => !actual.ContainsKey(key))) { unknown++; continue; }
            if (step.Parameters.All(pair => Equals(actual[pair.Key], pair.Value))) succeeded++;
            else failed++;
        }
        var result = new MutationResult(1, succeeded == state.Steps.Count ? MutationResultStatus.ConfirmedSuccess :
            succeeded > 0 ? MutationResultStatus.PartialSuccess : unknown > 0 ? MutationResultStatus.SubmittedButUnverified :
            rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
            operation, true, unknown > 0 || failed > 0 && state.Steps.Any(step => step.Submitted && step.Rejection is null),
            new(succeeded, failed, unknown), rejection ?? (succeeded == state.Steps.Count ? null : MutationErrorCategory.Server));
        if (unknown == 0) { state.Final = result; ServiceMutations.Pending.Remove((state.Scope, state.Kind)); }
        return result;
    }
    private static bool HardwareFieldsMatch(NasHardwareSettings left, NasHardwareSettings right, NasHardwareSections section)
    {
        var a = NasHardwareSettingsRules.Fields(left, section); var b = NasHardwareSettingsRules.Fields(right, section);
        return a.Count == b.Count && a.All(pair => b.TryGetValue(pair.Key, out var value) && Equals(pair.Value, value));
    }
    private sealed class HardwareWriteStep(NasHardwareSections section, ApiCapability capability, Dictionary<string, object> parameters)
    {
        public NasHardwareSections Section { get; } = section;
        public ApiCapability Capability { get; } = capability;
        public Dictionary<string, object> Parameters { get; } = parameters;
        public bool Submitted { get; set; }
        public bool UpdateSubmitted { get; set; }
        public bool UpdateAccepted { get; set; }
        public MutationErrorCategory? Rejection { get; set; }
    }
    private sealed class NasHardwareOperation(string scope, string signature, NasHardwareSettings desired,
        List<HardwareWriteStep> steps) : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Hardware)
    {
        public NasHardwareSettings Desired { get; } = desired;
        public List<HardwareWriteStep> Steps { get; } = steps;
    }
}
