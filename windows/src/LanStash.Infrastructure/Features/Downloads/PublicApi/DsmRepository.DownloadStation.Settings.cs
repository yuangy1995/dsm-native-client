using System.Globalization;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private int DownloadSettingsInfoVersion => HasPublicDownloadVersion(PublicDownloadInfoApi, 2) ? 2 : 1;
    public Task<DownloadSettingsSnapshot> LoadSettingsAsync(CancellationToken cancellationToken = default) => ReadDownloadSettingsSnapshotAsync(cancellationToken);
    private bool HasDownloadSettingsCapability(string api, int version)
    {
        if (!HasPublicDownloadVersion(api, version) || !_capabilities.TryGetValue(api, out var capability) || capability.Name != api ||
            !(capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) || capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase))) return false;
        var expected = api == PublicDownloadInfoApi ? "DownloadStation/info.cgi" : "DownloadStation/schedule.cgi";
        return capability.Path == expected || capability.Path == "/webapi/" + expected || capability.Path is "entry.cgi" or "/webapi/entry.cgi" or "webapi/entry.cgi";
    }
    private async Task<bool?> ReadDownloadManagerAsync(CancellationToken token)
    {
        var data = await CallPublicDownloadAsync(PublicDownloadInfoApi, "getinfo", null, token, DownloadSettingsInfoVersion).ConfigureAwait(false);
        return OptionalDownloadBool(data, "is_manager");
    }
    private async Task<DownloadSettingsSnapshot> ReadDownloadSettingsSnapshotAsync(CancellationToken token)
    {
        EnsureReadablePublicDownloadStationContract();
        var basic = await ReadDownloadBasicSettingsAsync(token).ConfigureAwait(false);
        bool? manager = null;
        try { manager = await ReadDownloadManagerAsync(token).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw; }
        catch { /* 无法确认管理权限时仍可显示已读设置。 */ }
        var scheduleStatus = DownloadStationSectionStatus.Unavailable;
        if (HasDownloadSettingsCapability(PublicDownloadScheduleApi, 1))
        {
            try
            {
                var schedule = await ReadDownloadScheduleAsync(token).ConfigureAwait(false);
                basic = basic with { IsScheduleEnabled = schedule.Enabled, IsEmuleScheduleEnabled = schedule.EmuleEnabled };
                scheduleStatus = DownloadStationSectionStatus.Available;
            }
            catch (OperationCanceledException) { throw; }
            catch { scheduleStatus = DownloadStationSectionStatus.Failed; }
        }
        return new(ProfileId, basic, DownloadSettingsInfoVersion == 2 && basic.DefaultDestination is not null, scheduleStatus) { IsManager = manager };
    }
    private async Task<DownloadStationSettingsSummary> ReadDownloadBasicSettingsAsync(CancellationToken token)
    {
        if (!HasDownloadSettingsCapability(PublicDownloadInfoApi, DownloadSettingsInfoVersion)) throw MissingPublicDownloadStationContract();
        var config = await CallPublicDownloadAsync(PublicDownloadInfoApi, "getconfig", null, token, DownloadSettingsInfoVersion).ConfigureAwait(false);
        // 目录保持原值；缺失字段不补零、false 或空路径。
        var destination = DownloadSettingsInfoVersion == 2 && config["default_destination"] is System.Text.Json.Nodes.JsonValue value && value.TryGetValue<string>(out var path) ? path : null;
        return new(destination, OptionalDownloadBool(config, "emule_enabled"), OptionalDownloadBool(config, "unzip_service_enabled"),
            OptionalNonNegativeInt(config, "bt_max_download"), OptionalNonNegativeInt(config, "bt_max_upload"),
            OptionalNonNegativeInt(config, "http_max_download"), OptionalNonNegativeInt(config, "ftp_max_download"),
            OptionalNonNegativeInt(config, "nzb_max_download"), OptionalNonNegativeInt(config, "emule_max_download"),
            OptionalNonNegativeInt(config, "emule_max_upload"), null, null);
    }
    private async Task<(bool? Enabled, bool? EmuleEnabled)> ReadDownloadScheduleAsync(CancellationToken token)
    {
        if (!HasDownloadSettingsCapability(PublicDownloadScheduleApi, 1)) throw MissingPublicDownloadStationContract();
        var data = await CallPublicDownloadAsync(PublicDownloadScheduleApi, "getconfig", null, token).ConfigureAwait(false);
        return (OptionalDownloadBool(data, "enabled"), OptionalDownloadBool(data, "emule_enabled"));
    }
    private static bool ValidDownloadSettingsDestination(string? path) => !string.IsNullOrEmpty(path) && !path.Any(char.IsControl) &&
        !path.Contains('\\') && !path.StartsWith('/') && path.Split('/').All(part => part.Length > 0 && part is not "." and not ".." && !part.Equals("#recycle", StringComparison.OrdinalIgnoreCase));
    private static Dictionary<string, string> DownloadSettingsValues(DownloadStationSettingsSummary value, bool basic)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        void Flag(string key, bool? flag) { if (flag is not null) result[key] = flag == true ? "true" : "false"; }
        void Limit(string key, int? limit) { if (limit is not null) result[key] = limit.Value.ToString(CultureInfo.InvariantCulture); }
        if (basic)
        {
            if (value.DefaultDestination is not null) result["default_destination"] = value.DefaultDestination;
            Flag("emule_enabled", value.IsEmuleEnabled); Flag("unzip_service_enabled", value.IsAutoExtractEnabled);
            Limit("bt_max_download", value.BtDownloadLimitKb); Limit("bt_max_upload", value.BtUploadLimitKb);
            Limit("http_max_download", value.HttpDownloadLimitKb); Limit("ftp_max_download", value.FtpDownloadLimitKb);
            Limit("nzb_max_download", value.NzbDownloadLimitKb); Limit("emule_max_download", value.EmuleDownloadLimitKb); Limit("emule_max_upload", value.EmuleUploadLimitKb);
        }
        else { Flag("enabled", value.IsScheduleEnabled); Flag("emule_enabled", value.IsEmuleScheduleEnabled); }
        return result;
    }
    private static DownloadStep? DownloadSettingsDelta(DownloadSettingsSnapshot expected, DownloadStationSettingsSummary desired, bool basic)
    {
        var before = DownloadSettingsValues(expected.Value, basic); var after = DownloadSettingsValues(desired, basic);
        var changed = before.Keys.Union(after.Keys).Where(key => before.GetValueOrDefault(key) != after.GetValueOrDefault(key)).ToArray();
        if (changed.Length == 0) return null;
        if (expected.IsManager != true || changed.Any(key => !before.ContainsKey(key) || !after.ContainsKey(key)) ||
            !basic && expected.ScheduleStatus != DownloadStationSectionStatus.Available ||
            changed.Contains("default_destination") && !expected.CanEditDestination) throw new ArgumentException("download.settings.unavailable-field");
        if (basic && (changed.Contains("http_max_download") || changed.Contains("ftp_max_download")))
        {
            if (!before.ContainsKey("http_max_download") || !before.ContainsKey("ftp_max_download") || before["http_max_download"] != before["ftp_max_download"] ||
                after.GetValueOrDefault("http_max_download") != after.GetValueOrDefault("ftp_max_download")) throw new ArgumentException("download.settings.web-ftp");
            changed = changed.Union(["http_max_download", "ftp_max_download"]).ToArray();
        }
        var step = new DownloadStep { Target = basic ? "basic" : "schedule", Before = changed.ToDictionary(key => key, key => before[key]), Desired = changed.ToDictionary(key => key, key => after[key]) };
        step.Identity = DownloadSettingsIdentity(step);
        if (!ValidDownloadSettingsStep(step)) throw new ArgumentException("download.settings.invalid-delta");
        return step;
    }
    private static string DownloadSettingsIdentity(DownloadStep step) => DownloadCreateDigest("settings", step.Target,
        JsonSerializer.Serialize(step.Before!.OrderBy(pair => pair.Key, StringComparer.Ordinal)), JsonSerializer.Serialize(step.Desired!.OrderBy(pair => pair.Key, StringComparer.Ordinal)));
    private static bool ValidDownloadSettingsStep(DownloadStep step)
    {
        if (step.Target is not ("basic" or "schedule") || step.Before is not { Count: > 0 } || step.Desired is null ||
            !step.Before.Keys.Order(StringComparer.Ordinal).SequenceEqual(step.Desired.Keys.Order(StringComparer.Ordinal)) || step.Identity != DownloadSettingsIdentity(step)) return false;
        var flags = step.Target == "basic" ? new[] { "emule_enabled", "unzip_service_enabled" } : ["enabled", "emule_enabled"];
        var limits = new[] { "bt_max_download", "bt_max_upload", "http_max_download", "ftp_max_download", "nzb_max_download", "emule_max_download", "emule_max_upload" };
        foreach (var values in new[] { step.Before, step.Desired })
            foreach (var pair in values)
                if (flags.Contains(pair.Key) ? pair.Value is not ("true" or "false") : step.Target != "basic" ||
                    (pair.Key == "default_destination" ? !ValidDownloadSettingsDestination(pair.Value) : !limits.Contains(pair.Key) ||
                    !int.TryParse(pair.Value, NumberStyles.None, CultureInfo.InvariantCulture, out var limit) || limit is < 0 or > 1_000_000)) return false;
        if (step.Target == "basic" && (step.Before.ContainsKey("http_max_download") || step.Before.ContainsKey("ftp_max_download")))
            return step.Before.GetValueOrDefault("http_max_download") == step.Before.GetValueOrDefault("ftp_max_download") && step.Desired.GetValueOrDefault("http_max_download") == step.Desired.GetValueOrDefault("ftp_max_download");
        return true;
    }
    public async Task<DownloadSettingsSaveOutcome> SaveSettingsAsync(DownloadSettingsSaveRequest request, CancellationToken cancellationToken = default)
    {
        var entered = false;
        try
        {
            if (request.ProfileId != ProfileId || request.Expected.ProfileId != ProfileId || request.ClientRequestId == Guid.Empty) throw new ArgumentException();
            var steps = new[] { DownloadSettingsDelta(request.Expected, request.Desired, true), DownloadSettingsDelta(request.Expected, request.Desired, false) }.OfType<DownloadStep>().ToArray();
            if (steps.Length == 0) throw new DownloadActionConflictException();
            await EnterDownloadsAsync(cancellationToken).ConfigureAwait(false); entered = true;
            var first = !DownloadRecords.Entries.ContainsKey(request.ClientRequestId);
            DownloadRecord entry;
            if (!first)
            {
                entry = DownloadEntry(request.ClientRequestId);
                if (entry.Kind != DownloadActionKind.Settings || !entry.Steps.Select(step => step.Identity).SequenceEqual(steps.Select(step => step.Identity))) throw new DownloadActionConflictException();
            }
            else
            {
                if (PendingDownload(DownloadActionKind.Settings, ["basic", "schedule"]) is not null) throw new DownloadActionConflictException();
                entry = NewDownload(DownloadActionKind.Settings, steps, request.ClientRequestId); await SaveDownloadAsync(entry).ConfigureAwait(false);
            }
            entry.CancelledAfterSubmission = false;
            await ReviewDownloadAsync(entry, cancellationToken).ConfigureAwait(false);
            if ((first || request.ContinueRemaining) && !entry.Steps.Any(step => step.Stage == DownloadActionStage.Unknown)) await ExecuteDownloadSettingsAsync(entry, cancellationToken).ConfigureAwait(false);
            var info = DownloadInfo(entry); var result = DownloadActionResult(info);
            DownloadSettingsComponentState Component(string target) => entry.Steps.SingleOrDefault(step => step.Target == target)?.Stage switch
            { null => DownloadSettingsComponentState.Unchanged, DownloadActionStage.NotStarted => DownloadSettingsComponentState.NotStarted,
                DownloadActionStage.Unknown => DownloadSettingsComponentState.Unknown, DownloadActionStage.Confirmed => DownloadSettingsComponentState.Confirmed, _ => DownloadSettingsComponentState.Rejected };
            return new(result, result.Status == MutationResultStatus.ConfirmedSuccess ? request.Expected with { Value = request.Desired } : null, Component("basic"), Component("schedule")) { ActionId = entry.Id };
        }
        catch (Exception error) { return new(DownloadActionFailure(error, "downloadSettings"), null,
            error is DownloadActionPersistenceException { Submitted: true } ? DownloadSettingsComponentState.Unknown : DownloadSettingsComponentState.Rejected, DownloadSettingsComponentState.Unchanged); }
        finally { if (entered) DownloadRecords.Gate.Release(); }
    }
    private async Task<bool> DownloadSettingsStepMatchesAsync(DownloadStep step, bool desired, CancellationToken token)
    {
        Dictionary<string, string> current;
        if (step.Target == "basic") current = DownloadSettingsValues(await ReadDownloadBasicSettingsAsync(token).ConfigureAwait(false), true);
        else
        {
            var schedule = await ReadDownloadScheduleAsync(token).ConfigureAwait(false); current = [];
            if (schedule.Enabled is { } enabled) current["enabled"] = enabled ? "true" : "false";
            if (schedule.EmuleEnabled is { } emule) current["emule_enabled"] = emule ? "true" : "false";
        }
        return (desired ? step.Desired! : step.Before!).All(pair => current.TryGetValue(pair.Key, out var value) && value == pair.Value);
    }
    private async Task ExecuteDownloadSettingsAsync(DownloadRecord entry, CancellationToken token)
    {
        foreach (var step in entry.Steps.Where(step => step.Stage == DownloadActionStage.NotStarted))
        {
            if (token.IsCancellationRequested || entry.Steps.Any(item => item.Stage == DownloadActionStage.Unknown)) break;
            try
            {
                if (await ReadDownloadManagerAsync(token).ConfigureAwait(false) != true) throw new DownloadTaskActionRejectedException(105);
                if (step.Desired!.ContainsKey("default_destination") && DownloadSettingsInfoVersion != 2) throw new NotSupportedException();
                if (!await DownloadSettingsStepMatchesAsync(step, false, token).ConfigureAwait(false)) throw new DownloadActionConflictException();
                token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { break; }
            catch (Exception error) { step.Stage = DownloadActionStage.Rejected; step.Error = DownloadActionError(error); await SaveDownloadAsync(entry).ConfigureAwait(false); continue; }
            step.Stage = DownloadActionStage.Unknown; await SaveDownloadAsync(entry).ConfigureAwait(false);
            if (token.IsCancellationRequested) { step.Stage = DownloadActionStage.NotStarted; await SaveDownloadAsync(entry).ConfigureAwait(false); break; }
            var basic = step.Target == "basic"; var api = basic ? PublicDownloadInfoApi : PublicDownloadScheduleApi;
            var parameters = new Dictionary<string, string>(step.Desired!, StringComparer.Ordinal);
            if (parameters.TryGetValue("default_destination", out var destination) && _capabilities[api].RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)) parameters["default_destination"] = JsonSerializer.Serialize(destination);
            step.Submitted = true;
            try { await CallPublicDownloadAsync(api, basic ? "setserverconfig" : "setconfig", parameters, token, basic ? DownloadSettingsInfoVersion : 1).ConfigureAwait(false); step.Accepted = true; }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error) && DownloadStationErrors.IsKnownRejection(error.Code)) { step.Stage = DownloadActionStage.Rejected; step.Error = DownloadActionError(error); }
            catch (OperationCanceledException) { entry.CancelledAfterSubmission = true; }
            catch { }
            await SaveDownloadAsync(entry).ConfigureAwait(false);
            if (step.Stage == DownloadActionStage.Unknown && !step.Accepted) break;
            await ReviewDownloadAsync(entry, token).ConfigureAwait(false);
        }
    }
}
