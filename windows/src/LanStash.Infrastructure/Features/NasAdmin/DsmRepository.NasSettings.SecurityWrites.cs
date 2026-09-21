using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> SaveSecuritySettingsAsync(NasServiceSettingsSaveRequest<NasSecuritySettings> request,
        CancellationToken cancellationToken = default) => NasSettingsWriteAvailability.CanSaveSecurity
            ? ExecuteSecuritySettingsWriteAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("saveSecurity"));

    internal async Task<MutationResult> ExecuteSecuritySettingsWriteAsync(NasServiceSettingsSaveRequest<NasSecuritySettings> request,
        CancellationToken token = default)
    {
        const string operation = "saveSecurity";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || request.Desired is null || !request.RiskConfirmed ||
            request.ProfileId != _profile.Id || _profile.Id != _session.ProfileId || request.RequestId == Guid.Empty ||
            string.IsNullOrWhiteSpace(_session.Sid) || !NasSecuritySettingsRules.IsValidChange(request.Baseline, request.Desired))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var baseline = request.Baseline with { DosProtection = Array.AsReadOnly(request.Baseline.DosProtection.ToArray()) };
        var desired = request.Desired with { DosProtection = Array.AsReadOnly(request.Desired.DosProtection.ToArray()) };
        var steps = new List<SecurityWriteStep>();
        foreach (var section in new[] { NasSecuritySections.AutoBlock, NasSecuritySections.Dos, NasSecuritySections.PortScan, NasSecuritySections.Firewall })
        {
            if (!desired.AvailableSections.HasFlag(section) || SecuritySignature(baseline, section) == SecuritySignature(desired, section)) continue;
            var name = section switch
            {
                NasSecuritySections.AutoBlock => "SYNO.Core.Security.AutoBlock",
                NasSecuritySections.Dos => "SYNO.Core.Security.DoS",
                NasSecuritySections.PortScan => "SYNO.Core.Security.Firewall.Conf",
                _ => desired.FirewallEnabled == true ? "SYNO.Core.Security.Firewall.Profile.Apply" : "SYNO.Core.Security.Firewall",
            };
            var capability = SecurityCapability(name, section == NasSecuritySections.Dos ? 2 : 1);
            if (capability is null) return UnsupportedResult(operation);
            if (section == NasSecuritySections.Dos && SecurityCapability("SYNO.Core.Network.Ethernet", 2) is null ||
                section == NasSecuritySections.Firewall && SecurityCapability("SYNO.Core.Security.Firewall", 1) is null)
                return UnsupportedResult(operation);
            steps.Add(new(section, capability));
        }
        if (steps.Count == 0) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var signature = ServiceHash(JsonSerializer.Serialize(new
        {
            kind = NasServiceSettingsKind.Security,
            before = SecurityAllSignature(baseline), after = SecurityAllSignature(desired),
        }));
        var shared = ServiceMutations; var scope = ServiceScope();
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
            if (shared.Pending.ContainsKey((scope, NasServiceSettingsKind.Security)))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            NasSecuritySettings current;
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                current = await LoadSecuritySettingsAsync(token).ConfigureAwait(false);
                if (current.FailedSections != NasSecuritySections.None || current.AvailableSections != baseline.AvailableSections ||
                    SecurityAllSignature(current) != SecurityAllSignature(baseline))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                if (steps.Any(step => step.Section == NasSecuritySections.Firewall) && desired.FirewallEnabled == true &&
                    string.IsNullOrWhiteSpace(current.FirewallProfileName)) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }
            var state = new NasSecurityOperation(scope, signature, desired, current.FirewallProfileName, steps);
            shared.Operations.Add(request.RequestId, state); shared.Pending.Add((scope, state.Kind), state);
            foreach (var step in steps)
            {
                if (token.IsCancellationRequested) break;
                step.Submitted = true;
                try
                {
                    if (step.Section == NasSecuritySections.Firewall && desired.FirewallEnabled == true)
                    {
                        var started = await SecurityCallAsync(step.Capability, "start",
                            new() { ["name"] = state.Profile!, ["profile_applying"] = false }, token).ConfigureAwait(false);
                        step.TaskId = started.String("task_id");
                        if (string.IsNullOrWhiteSpace(step.TaskId)) break;
                        for (var attempt = 0; attempt < 30 && !step.TaskFinished; attempt++)
                        {
                            if (attempt > 0) await Task.Delay(TimeSpan.FromSeconds(1), token).ConfigureAwait(false);
                            await PollFirewallTaskAsync(step, token).ConfigureAwait(false);
                        }
                        if (!step.TaskFinished || !step.TaskSucceeded || !step.CleanupSucceeded) break;
                    }
                    else await SecurityCallAsync(step.Capability, "set", SecurityParameters(desired, step.Section), token).ConfigureAwait(false);
                }
                catch (DsmException error) when (step.TaskId is null && DsmApiClient.IsExplicitApiRejection(error))
                { step.Rejection = ServiceErrorCategory(error); break; }
                catch (Exception) { break; }
            }
            if (!steps.Any(step => step.Submitted))
            {
                shared.Pending.Remove((scope, state.Kind)); shared.Operations.Remove(request.RequestId);
                return CancelledBeforeSubmissionResult(operation);
            }
            return await ReviewSecurityOperationAsync(state, token, pollTask: false).ConfigureAwait(false);
        }
        finally { shared.Gate.Release(); }
    }

    private async Task PollFirewallTaskAsync(SecurityWriteStep step, CancellationToken token)
    {
        if (step.TaskId is null || step.TaskFinished) return;
        var status = await SecurityCallAsync(step.Capability, "status", new() { ["task_id"] = step.TaskId }, token).ConfigureAwait(false);
        if (status.Bool("success") is not bool success) return;
        step.TaskFinished = true; step.TaskSucceeded = success;
        // 只有已确认完成的任务才清理；未知/超时任务不盲目 stop。
        try
        {
            await SecurityCallAsync(step.Capability, "stop", new(), token).ConfigureAwait(false);
            step.CleanupSucceeded = true;
        }
        catch (Exception) { } // 清理响应丢失也不重发，保留未确认状态。
    }

    private async Task<MutationResult> ReviewSecurityOperationAsync(NasSecurityOperation state, CancellationToken token, bool pollTask = true)
    {
        const string operation = "saveSecurity";
        foreach (var step in state.Steps.Where(step => pollTask && step.TaskId is not null && !step.TaskFinished))
        {
            if (token.IsCancellationRequested) break;
            try { await PollFirewallTaskAsync(step, token).ConfigureAwait(false); }
            catch (Exception) { }
        }
        NasSecuritySettings current;
        var submitted = state.Steps.Count(step => step.Submitted);
        try { current = await LoadSecuritySettingsAsync(token).ConfigureAwait(false); }
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
            if (step.Rejection is { } category) { failed++; rejection = category; continue; }
            if (step.Section == NasSecuritySections.Firewall && state.Desired.FirewallEnabled == true)
            {
                if (!step.TaskFinished || !step.CleanupSucceeded) { unknown++; continue; }
                if (!step.TaskSucceeded) { failed++; continue; }
            }
            if (!current.AvailableSections.HasFlag(step.Section) || current.FailedSections.HasFlag(step.Section)) { unknown++; continue; }
            // 关闭没有提交配置档名称，不能要求 NAS 在关闭后继续回传旧配置档。
            var matches = step.Section == NasSecuritySections.Firewall && state.Desired.FirewallEnabled == false
                ? current.FirewallEnabled == false
                : SecuritySignature(current, step.Section) == SecuritySignature(state.Desired, step.Section);
            if (matches) succeeded++;
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

    private ApiCapability? SecurityCapability(string name, int version) =>
        _capabilities.TryGetValue(name, out var value) && value.Name == name && value.MinVersion >= 1 && value.MinVersion <= version &&
        value.MaxVersion >= version && NasServiceFormatAndPathSupported(value)
            ? value with { Path = "entry.cgi", MinVersion = version, MaxVersion = version } : null;
    private Task<System.Text.Json.Nodes.JsonObject> SecurityCallAsync(ApiCapability capability, string method,
        Dictionary<string, object> parameters, CancellationToken token)
    {
        var json = capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase);
        return _api.CallAsync(_profile, _session, capability, method, parameters.ToDictionary(pair => pair.Key,
            pair => pair.Value is string text && !json ? text : JsonSerializer.Serialize(pair.Value)), token);
    }
    private static Dictionary<string, object> SecurityParameters(NasSecuritySettings value, NasSecuritySections section) => section switch
    {
        NasSecuritySections.AutoBlock => new() { ["enable"] = value.AutoBlockEnabled!.Value, ["attempts"] = value.AutoBlockFailedAttempts!.Value,
            ["within_mins"] = value.AutoBlockWithinMinutes!.Value, ["expire_day"] = value.AutoBlockExpiryDays!.Value },
        NasSecuritySections.Dos => new() { ["configs"] = value.DosProtection.Select(item => new { adapter = item.Id, dos_protect_enable = item.Enabled }).ToArray() },
        NasSecuritySections.PortScan => new() { ["enable_port_check"] = value.PortScanEnabled!.Value },
        _ => new() { ["set_type"] = "disable" },
    };
    private static string SecuritySignature(NasSecuritySettings value, NasSecuritySections section) => section switch
    {
        NasSecuritySections.AutoBlock => JsonSerializer.Serialize(new { value.AutoBlockEnabled, value.AutoBlockFailedAttempts, value.AutoBlockWithinMinutes, value.AutoBlockExpiryDays }),
        NasSecuritySections.Dos => JsonSerializer.Serialize(value.DosProtection.OrderBy(item => item.Id, StringComparer.Ordinal).Select(item => new { item.Id, item.Enabled })),
        NasSecuritySections.PortScan => JsonSerializer.Serialize(value.PortScanEnabled),
        _ => JsonSerializer.Serialize(new { value.FirewallEnabled, value.FirewallProfileName }),
    };
    private static string SecurityAllSignature(NasSecuritySettings value) => JsonSerializer.Serialize(new[]
    {
        SecuritySignature(value, NasSecuritySections.AutoBlock), SecuritySignature(value, NasSecuritySections.Dos),
        SecuritySignature(value, NasSecuritySections.PortScan), SecuritySignature(value, NasSecuritySections.Firewall),
    });
    private sealed class SecurityWriteStep(NasSecuritySections section, ApiCapability capability)
    {
        public NasSecuritySections Section { get; } = section;
        public ApiCapability Capability { get; } = capability;
        public bool Submitted { get; set; }
        public MutationErrorCategory? Rejection { get; set; }
        public string? TaskId { get; set; }
        public bool TaskFinished { get; set; }
        public bool TaskSucceeded { get; set; }
        public bool CleanupSucceeded { get; set; }
    }
    private sealed class NasSecurityOperation(string scope, string signature, NasSecuritySettings desired,
        string? profile, List<SecurityWriteStep> steps) : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Security)
    {
        public NasSecuritySettings Desired { get; } = desired;
        public string? Profile { get; } = profile;
        public List<SecurityWriteStep> Steps { get; } = steps;
    }
}
