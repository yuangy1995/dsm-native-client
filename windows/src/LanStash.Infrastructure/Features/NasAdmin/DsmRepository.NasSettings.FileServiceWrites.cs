using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> SaveFileServiceSettingsAsync(NasServiceSettingsSaveRequest<NasFileServiceSettings> request,
        CancellationToken cancellationToken = default) => NasSettingsWriteAvailability.CanSaveFileService
            ? ExecuteFileServiceSettingsWriteAsync(request, cancellationToken)
            : Task.FromResult(UnsupportedResult("saveFileService"));

    internal async Task<MutationResult> ExecuteFileServiceSettingsWriteAsync(
        NasServiceSettingsSaveRequest<NasFileServiceSettings> request, CancellationToken token = default)
    {
        const string operation = "saveFileService";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || request.Desired is null ||
            request.ProfileId != _profile.Id || _profile.Id != _session.ProfileId ||
            request.RequestId == Guid.Empty || !request.RiskConfirmed || string.IsNullOrWhiteSpace(_session.Sid) ||
            !NasFileServiceSettingsRules.IsValidChange(request.Baseline, request.Desired))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);

        var steps = new List<FileServiceWriteStep>();
        foreach (var group in FileServiceReadGroups)
        {
            var known = group.Fields.Where(item => request.Desired.AvailableFields.HasFlag(item.Field)).ToArray();
            if (!known.Any(item => !Equals(NasFileServiceSettingsRules.Value(request.Baseline, item.Field),
                    NasFileServiceSettingsRules.Value(request.Desired, item.Field)))) continue;
            var capability = FileServiceCapability(group);
            if (capability is null) return UnsupportedResult(operation);
            steps.Add(new(capability, known));
        }
        if (steps.Count == 0) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var scope = ServiceScope();
        var signature = ServiceHash(JsonSerializer.Serialize(new { kind = NasServiceSettingsKind.FileServices, request.Baseline, request.Desired }));
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
            if (shared.Pending.ContainsKey((scope, NasServiceSettingsKind.FileServices)))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                var current = await LoadFileServiceSettingsAsync(token).ConfigureAwait(false);
                if (current.FailedFields != NasFileServiceFields.None)
                    return ServicePreflightFailure(operation, MutationErrorCategory.Server, true);
                if (current.AvailableFields != request.Baseline.AvailableFields ||
                    Enum.GetValues<NasFileServiceFields>().Any(item => current.AvailableFields.HasFlag(item) &&
                        !Equals(NasFileServiceSettingsRules.Value(current, item), NasFileServiceSettingsRules.Value(request.Baseline, item))))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }

            var state = new NasFileServiceOperation(scope, signature, request.Desired, steps);
            shared.Operations.Add(request.RequestId, state);
            shared.Pending.Add((scope, NasServiceSettingsKind.FileServices), state);
            foreach (var step in steps)
            {
                if (token.IsCancellationRequested) break;
                var parameters = step.Fields.ToDictionary(item => item.Key,
                    item => JsonSerializer.Serialize(NasFileServiceSettingsRules.Value(state.Desired, item.Field)), StringComparer.Ordinal);
                step.Submitted = true;
                try
                {
                    await _api.CallAsync(_profile, _session, step.Capability, "set", parameters, token).ConfigureAwait(false);
                }
                catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
                {
                    step.Rejection = ServiceErrorCategory(error);
                    break;
                }
                catch (Exception) { break; } // 当前请求未知，停止后续组，不自动重放。
            }
            if (!steps.Any(step => step.Submitted))
            {
                shared.Operations.Remove(request.RequestId);
                shared.Pending.Remove((scope, NasServiceSettingsKind.FileServices));
                return CancelledBeforeSubmissionResult(operation);
            }
            return await ReviewFileServiceOperationAsync(state, token).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewFileServiceOperationAsync(NasFileServiceOperation state, CancellationToken token)
    {
        const string operation = "saveFileService";
        var submitted = state.Steps.Count(step => step.Submitted);
        NasFileServiceSettings current;
        try
        {
            token.ThrowIfCancellationRequested();
            // 提交开始后即使中途停止，也整体重新读取所有可用组；不得仅检查最后一个请求。
            current = await LoadFileServiceSettingsAsync(token).ConfigureAwait(false);
        }
        catch (Exception)
        {
            return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission :
                MutationResultStatus.SubmittedButUnverified, operation, true, true,
                new(0, state.Steps.Count - submitted, submitted), MutationErrorCategory.Network);
        }
        var succeeded = 0; var failed = 0; var unknown = 0;
        MutationErrorCategory? rejection = null;
        foreach (var step in state.Steps)
        {
            if (!step.Submitted) { failed++; continue; }
            if (step.Rejection is { } category) { rejection = category; failed++; continue; }
            if (step.Fields.Any(item => !current.AvailableFields.HasFlag(item.Field) ||
                current.FailedFields.HasFlag(item.Field))) { unknown++; continue; }
            if (step.Fields.All(item => Equals(NasFileServiceSettingsRules.Value(current, item.Field),
                    NasFileServiceSettingsRules.Value(state.Desired, item.Field)))) succeeded++;
            else failed++;
        }
        var result = new MutationResult(1,
            succeeded == state.Steps.Count ? MutationResultStatus.ConfirmedSuccess :
            succeeded > 0 ? MutationResultStatus.PartialSuccess :
            unknown > 0 ? MutationResultStatus.SubmittedButUnverified :
            rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
            operation, true, unknown > 0 || failed > 0 && state.Steps.Any(step => step.Submitted && step.Rejection is null),
            new(succeeded, failed, unknown),
            rejection ?? (succeeded == state.Steps.Count ? null : MutationErrorCategory.Server));
        if (unknown == 0)
        {
            state.Final = result;
            ServiceMutations.Pending.Remove((state.Scope, state.Kind));
        }
        return result;
    }

    private ApiCapability? FileServiceCapability(FileServiceReadGroup group)
    {
        if (!_capabilities.TryGetValue(group.Api, out var capability) || capability.Name != group.Api ||
            capability.MinVersion < 1 || capability.MinVersion > group.MaximumVersion ||
            capability.MaxVersion < group.MinimumVersion || capability.MaxVersion < capability.MinVersion ||
            !NasServiceFormatAndPathSupported(capability)) return null;
        var version = Math.Min(group.MaximumVersion, capability.MaxVersion);
        return capability with { Path = "entry.cgi", MinVersion = version, MaxVersion = version };
    }

    private sealed class FileServiceWriteStep(ApiCapability capability, FileServiceReadField[] fields)
    {
        public ApiCapability Capability { get; } = capability;
        public FileServiceReadField[] Fields { get; } = fields;
        public bool Submitted { get; set; }
        public MutationErrorCategory? Rejection { get; set; }
    }
    private sealed class NasFileServiceOperation(string scope, string signature, NasFileServiceSettings desired,
        List<FileServiceWriteStep> steps) : NasSettingsOperation(scope, signature, NasServiceSettingsKind.FileServices)
    {
        public NasFileServiceSettings Desired { get; } = desired;
        public List<FileServiceWriteStep> Steps { get; } = steps;
    }
}
