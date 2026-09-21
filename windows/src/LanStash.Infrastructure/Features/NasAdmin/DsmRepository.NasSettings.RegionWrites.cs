using System.Globalization;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public Task<MutationResult> SaveRegionSettingsAsync(NasRegionSettingsSaveRequest request,
        CancellationToken cancellationToken = default) => NasSettingsWriteAvailability.CanSaveRegion
            ? ExecuteRegionSettingsWriteAsync(request, cancellationToken) : Task.FromResult(UnsupportedResult("saveRegion"));

    internal async Task<MutationResult> ExecuteRegionSettingsWriteAsync(NasRegionSettingsSaveRequest request,
        CancellationToken token = default)
    {
        const string operation = "saveRegion";
        if (token.IsCancellationRequested) return CancelledBeforeSubmissionResult(operation);
        if (request is null || request.Baseline is null || request.Desired is null || !request.RiskConfirmed ||
            request.ProfileId != _profile.Id || _profile.Id != _session.ProfileId || request.RequestId == Guid.Empty ||
            string.IsNullOrWhiteSpace(_session.Sid)) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var baseline = NasRegionSettingsRules.Normalize(request.Baseline);
        var desired = NasRegionSettingsRules.Normalize(request.Desired);
        if (baseline.Mode is not (NasRegionTimeMode.Network or NasRegionTimeMode.Manual) ||
            !NasRegionSettingsRules.IsValid(desired, request.EditedNasTime))
            return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var capability = RegionCapability();
        if (capability is null) return UnsupportedResult(operation);
        var original = RegionFields(baseline); var target = RegionFields(desired);
        var changed = target.Keys.Where(key => target[key] != original[key]).ToList();
        if (request.EditedNasTime is not null) changed.Add("clock");
        if (changed.Count == 0) return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
        var sync = desired.Mode == NasRegionTimeMode.Network &&
            (baseline.Mode != NasRegionTimeMode.Network || !baseline.NtpServers.SequenceEqual(desired.NtpServers));
        var signature = ServiceHash(JsonSerializer.Serialize(new { kind = NasServiceSettingsKind.Region, original, target, request.EditedNasTime }));
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
                if (previous.Scope != scope || previous.Signature != signature)
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                return previous.Final ?? await ReviewNasSettingsOperationAsync(previous, token).ConfigureAwait(false);
            }
            if (shared.Pending.ContainsKey((scope, NasServiceSettingsKind.Region)))
                return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
            NasRegionSettings current;
            try
            {
                await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
                if (!_nasServiceSessionVerified) return UnsupportedResult(operation);
                if (!_nasServiceAdministrator) return ServicePreflightFailure(operation, MutationErrorCategory.Permission);
                current = NasRegionSettingsRules.Normalize(await LoadRegionSettingsAsync(token).ConfigureAwait(false));
                if (!current.TimeZones.Any(zone => zone.Id == desired.Timezone))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
                if (RegionFields(current).Any(pair => original[pair.Key] != pair.Value))
                    return ServicePreflightFailure(operation, MutationErrorCategory.Conflict, true);
                // 未编辑时间时只使用刚从 NAS 读取的时间，不使用请求中的旧 clock。
                if (desired.Mode == NasRegionTimeMode.Manual && request.EditedNasTime is null && current.NasLocalTime is null)
                    return ServicePreflightFailure(operation, MutationErrorCategory.Validation);
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return CancelledBeforeSubmissionResult(operation); }
            catch (DsmException error) { return ServicePreflightFailure(operation, ServiceErrorCategory(error)); }
            catch (Exception) { return ServicePreflightFailure(operation, MutationErrorCategory.Network); }

            var state = new NasRegionOperation(scope, signature, capability, desired, changed.ToArray(), sync, request.EditedNasTime);
            shared.Operations.Add(request.RequestId, state);
            shared.Pending.Add((scope, NasServiceSettingsKind.Region), state);
            var parameters = RegionParameters(desired, request.EditedNasTime ?? current.NasLocalTime, capability);
            try
            {
                await _api.CallAsync(_profile, _session, capability with { MinVersion = 3, MaxVersion = 3 },
                    "set", parameters, token).ConfigureAwait(false);
                state.SetAccepted = true;
            }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error)) { state.Rejection = ServiceErrorCategory(error); }
            catch (Exception) { }
            var result = await ReviewRegionOperationAsync(state, token, allowSync: state.SetAccepted).ConfigureAwait(false);
            return result;
        }
        finally { shared.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewRegionOperationAsync(NasRegionOperation state, CancellationToken token, bool allowSync = false)
    {
        const string operation = "saveRegion";
        NasRegionSettings current;
        try { current = NasRegionSettingsRules.Normalize(await LoadRegionSettingsAsync(token).ConfigureAwait(false)); }
        catch (Exception)
        {
            return new(1, token.IsCancellationRequested ? MutationResultStatus.CancellationRequestedAfterSubmission :
                MutationResultStatus.SubmittedButUnverified, operation, true, true,
                new(0, 0, state.Changed.Length + (state.NeedsSync ? 1 : 0)), MutationErrorCategory.Network);
        }
        var actual = RegionFields(current); var expected = RegionFields(state.Desired);
        var matched = state.Changed.Count(key => key == "clock"
            ? current.NasLocalTime is { } clock && state.EditedTime is { } target && Math.Abs((clock - target).TotalSeconds) <= 120
            : actual[key] == expected[key]);
        var configurationMatches = expected.All(pair => actual[pair.Key] == pair.Value) &&
            (!state.Changed.Contains("clock") || matched == state.Changed.Length);
        if (state.Rejection is { } rejection)
            return CompleteRegion(state, new(1, rejection == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied :
                MutationResultStatus.ConfirmedFailure, operation, true, false, new(0, state.Changed.Length + (state.NeedsSync ? 1 : 0), 0), rejection));
        if (state.EditedTime is not null && current.NasLocalTime is null)
            return new(1, matched > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified,
                operation, true, true, new(matched, state.Changed.Length - matched - 1, 1), MutationErrorCategory.Server);
        if (!configurationMatches)
            return CompleteRegion(state, new(1, matched > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.ConfirmedFailure,
                operation, true, true, new(matched, Math.Max(1, expected.Count(pair => actual[pair.Key] != pair.Value) +
                    (state.EditedTime is not null && matched != state.Changed.Length ? 1 : 0)) + (state.NeedsSync ? 1 : 0), 0), MutationErrorCategory.Server));
        if (!state.NeedsSync)
            return CompleteRegion(state, new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false, new(state.Changed.Length, 0, 0)));
        // 恢复入口从不发送 sync；配置匹配不能证明旧校时请求是否被接受，更不能证明时钟精度。
        if (!allowSync || state.SyncSubmitted || token.IsCancellationRequested)
            return CompleteRegion(state, new(1, MutationResultStatus.PartialSuccess, operation, true, true,
                new(state.Changed.Length, state.SyncSubmitted ? 0 : 1, state.SyncSubmitted ? 1 : 0),
                MutationErrorCategory.Network, diagnosticTag: "region.sync.unverified"));
        state.SyncSubmitted = true;
        try
        {
            var capability = state.Capability;
            await _api.CallAsync(_profile, _session, capability with { MinVersion = 2, MaxVersion = 2 }, "sync",
                new Dictionary<string, string> { ["servers"] = JsonSerializer.Serialize(state.Desired.NtpServers) }, token).ConfigureAwait(false);
        }
        catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
        {
            return CompleteRegion(state, new(1, MutationResultStatus.PartialSuccess, operation, true, true,
                new(state.Changed.Length, 1, 0), ServiceErrorCategory(error), diagnosticTag: "region.sync.failed"));
        }
        catch (Exception)
        {
            return CompleteRegion(state, new(1, MutationResultStatus.PartialSuccess, operation, true, true,
                new(state.Changed.Length, 0, 1), MutationErrorCategory.Network, diagnosticTag: "region.sync.unverified"));
        }
        try
        {
            var verified = RegionFields(NasRegionSettingsRules.Normalize(await LoadRegionSettingsAsync(token).ConfigureAwait(false)));
            if (expected.All(pair => verified[pair.Key] == pair.Value))
                return CompleteRegion(state, new(1, MutationResultStatus.ConfirmedSuccess, operation, true, false,
                    new(state.Changed.Length + 1, 0, 0), diagnosticTag: "region.sync.accepted"));
        }
        catch (Exception) { }
        return CompleteRegion(state, new(1, MutationResultStatus.PartialSuccess, operation, true, true,
            new(state.Changed.Length, 0, 1), MutationErrorCategory.Network, diagnosticTag: "region.sync.unverified"));
    }

    private MutationResult CompleteRegion(NasRegionOperation state, MutationResult result)
    {
        // sync 无独立查询句柄，部分结果必须保留且不重放，但不能永久锁住后续独立配置更改。
        state.Final = result;
        ServiceMutations.Pending.Remove((state.Scope, state.Kind));
        return result;
    }
    private ApiCapability? RegionCapability()
    {
        const string name = "SYNO.Core.Region.NTP";
        return _capabilities.TryGetValue(name, out var value) && value.Name == name && value.MinVersion == 1 &&
            value.MaxVersion >= 3 && NasServiceFormatAndPathSupported(value) ? value with { Path = "entry.cgi" } : null;
    }
    private static Dictionary<string, string> RegionFields(NasRegionSettings value) => new()
    {
        ["date_format"] = value.DateFormat ?? "", ["time_format"] = value.TimeFormat ?? "", ["timezone"] = value.Timezone ?? "",
        ["enable_ntp"] = value.Mode == NasRegionTimeMode.Network ? "ntp" : "manual", ["server"] = string.Join(",", value.NtpServers),
    };
    private static Dictionary<string, string> RegionParameters(NasRegionSettings value, DateTime? clock, ApiCapability capability)
    {
        var json = capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase);
        var parameters = RegionFields(value).ToDictionary(pair => pair.Key, pair => json ? JsonSerializer.Serialize(pair.Value) : pair.Value);
        if (value.Mode == NasRegionTimeMode.Manual && clock is { } time)
        {
            var date = time.ToString("yyyy/M/d", CultureInfo.InvariantCulture);
            parameters["date"] = json ? JsonSerializer.Serialize(date) : date;
            parameters["hour"] = time.Hour.ToString(CultureInfo.InvariantCulture);
            parameters["minute"] = time.Minute.ToString(CultureInfo.InvariantCulture);
            parameters["second"] = time.Second.ToString(CultureInfo.InvariantCulture);
        }
        return parameters;
    }
    private sealed class NasRegionOperation(string scope, string signature, ApiCapability capability, NasRegionSettings desired,
        string[] changed, bool sync, DateTime? editedTime) : NasSettingsOperation(scope, signature, NasServiceSettingsKind.Region)
    {
        public NasRegionSettings Desired { get; } = desired;
        public ApiCapability Capability { get; } = capability;
        public string[] Changed { get; } = changed;
        public bool NeedsSync { get; } = sync;
        public DateTime? EditedTime { get; } = editedTime;
        public bool SetAccepted { get; set; }
        public bool SyncSubmitted { get; set; }
        public MutationErrorCategory? Rejection { get; set; }
    }
}
