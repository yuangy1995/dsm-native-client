using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static readonly ConditionalWeakTable<IDsmApiClient, DownloadSettingsApiState> DownloadSettingsStates = new();
    private int DownloadSettingsInfoVersion => HasPublicDownloadVersion(PublicDownloadInfoApi, 2) ? 2 : 1;

    public Task<DownloadSettingsSnapshot> LoadSettingsAsync(CancellationToken cancellationToken = default) =>
        ReadDownloadSettingsSnapshotAsync(cancellationToken, requireCompleteBasic: true);

    private bool HasDownloadSettingsCapability(string api, int version)
    {
        if (!HasPublicDownloadVersion(api, version) || !_capabilities.TryGetValue(api, out var capability) || capability.Name != api ||
            !(capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) || capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase))) return false;
        var path = capability.Path;
        var expected = api == PublicDownloadInfoApi ? "DownloadStation/info.cgi" : "DownloadStation/schedule.cgi";
        return path == expected || path == "/webapi/" + expected || path is "entry.cgi" or "/webapi/entry.cgi" or "webapi/entry.cgi";
    }

    private async Task<DownloadSettingsSnapshot> ReadDownloadSettingsSnapshotAsync(CancellationToken token, bool requireCompleteBasic)
    {
        EnsureReadablePublicDownloadStationContract();
        var basic = await ReadDownloadBasicSettingsAsync(token, requireCompleteBasic).ConfigureAwait(false);
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
        return new(_profile.Id, basic, DownloadSettingsInfoVersion == 2, scheduleStatus);
    }

    private async Task<DownloadStationSettingsSummary> ReadDownloadBasicSettingsAsync(CancellationToken token, bool requireComplete = true)
    {
        var version = DownloadSettingsInfoVersion;
        if (!HasDownloadSettingsCapability(PublicDownloadInfoApi, version)) throw MissingPublicDownloadStationContract();
        var config = await CallPublicDownloadAsync(PublicDownloadInfoApi, "getconfig", null, token, version).ConfigureAwait(false);
        var value = new DownloadStationSettingsSummary(version == 2 ? OptionalStableDownloadText(config, "default_destination") : null,
            OptionalDownloadBool(config, "emule_enabled"), OptionalDownloadBool(config, "unzip_service_enabled"),
            OptionalNonNegativeInt(config, "bt_max_download"), OptionalNonNegativeInt(config, "bt_max_upload"),
            OptionalNonNegativeInt(config, "http_max_download"), OptionalNonNegativeInt(config, "ftp_max_download"),
            OptionalNonNegativeInt(config, "nzb_max_download"), OptionalNonNegativeInt(config, "emule_max_download"),
            OptionalNonNegativeInt(config, "emule_max_upload"), null, null);
        if (requireComplete && !ValidDownloadBasicSettings(value, version == 2)) throw InvalidDownloadStationResponse();
        return value;
    }

    private async Task<(bool Enabled, bool EmuleEnabled)> ReadDownloadScheduleAsync(CancellationToken token)
    {
        if (!HasDownloadSettingsCapability(PublicDownloadScheduleApi, 1)) throw MissingPublicDownloadStationContract();
        var schedule = await CallPublicDownloadAsync(PublicDownloadScheduleApi, "getconfig", null, token).ConfigureAwait(false);
        return (OptionalDownloadBool(schedule, "enabled") ?? throw InvalidDownloadStationResponse(),
            OptionalDownloadBool(schedule, "emule_enabled") ?? throw InvalidDownloadStationResponse());
    }

    private static DownloadStationSettingsSummary BasicSettings(DownloadStationSettingsSummary value) =>
        value with { IsScheduleEnabled = null, IsEmuleScheduleEnabled = null };
    private static bool ScheduleSettingsMatch(DownloadStationSettingsSummary first, DownloadStationSettingsSummary second) =>
        first.IsScheduleEnabled == second.IsScheduleEnabled && first.IsEmuleScheduleEnabled == second.IsEmuleScheduleEnabled;

    private static bool ValidDownloadBasicSettings(DownloadStationSettingsSummary value, bool destinationSupported)
    {
        int?[] limits = [value.BtDownloadLimitKb, value.BtUploadLimitKb, value.HttpDownloadLimitKb, value.FtpDownloadLimitKb,
            value.NzbDownloadLimitKb, value.EmuleDownloadLimitKb, value.EmuleUploadLimitKb];
        return value.IsEmuleEnabled is not null && value.IsAutoExtractEnabled is not null && limits.All(limit => limit is >= 0 and <= 1_000_000) &&
            value.HttpDownloadLimitKb == value.FtpDownloadLimitKb && (destinationSupported ? ValidDownloadSettingsDestination(value.DefaultDestination) : value.DefaultDestination is null);
    }
    private static bool ValidDownloadSettingsDestination(string? path) => !string.IsNullOrWhiteSpace(path) &&
        !path.Any(char.IsControl) && !path.Contains('\\') && path == path.Trim().Trim('/') && path.Split('/').All(part => part.Length > 0 && part is not "." and not ".." && !part.Equals("#recycle", StringComparison.OrdinalIgnoreCase));

    public async Task<DownloadSettingsSaveOutcome> SaveSettingsAsync(DownloadSettingsSaveRequest request, CancellationToken cancellationToken = default)
    {
        var desired = request.Desired;
        if (request.ProfileId != _profile.Id || request.Expected.ProfileId != _profile.Id || _session.ProfileId != _profile.Id ||
            string.IsNullOrWhiteSpace(_session.Sid) || request.ClientRequestId == Guid.Empty ||
            !ValidDownloadBasicSettings(desired, request.Expected.CanEditDestination) ||
            !ValidDownloadBasicSettings(request.Expected.Value, request.Expected.CanEditDestination) ||
            (request.Expected.ScheduleStatus == DownloadStationSectionStatus.Available
                ? desired.IsScheduleEnabled is null || desired.IsEmuleScheduleEnabled is null
                : !ScheduleSettingsMatch(request.Expected.Value, desired)))
            return SettingsFailure(MutationErrorCategory.Validation);
        var context = DownloadCreateDigest(_profile.Username, _profile.Host, _profile.Port?.ToString(CultureInfo.InvariantCulture) ?? "");
        var signature = DownloadCreateDigest(JsonSerializer.Serialize(new { request.ProfileId, Context = context, request.Expected, desired }));
        var owner = (_profile.Id, context);
        var state = DownloadSettingsStates.GetValue(_api, _ => new());
        try { await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false); }
        catch (OperationCanceledException) { return SettingsCancelled(); }
        try
        {
            var first = !state.Requests.TryGetValue(request.ClientRequestId, out var operation);
            if (!first && operation!.Signature != signature) return SettingsFailure(MutationErrorCategory.Conflict);
            if (first && state.Pending.TryGetValue(owner, out var pending))
            {
                if (pending.Signature != signature) return SettingsFailure(MutationErrorCategory.Conflict);
                operation = pending; first = false; state.Requests[request.ClientRequestId] = operation;
            }
            if (operation?.Terminal is { } terminal) return terminal;
            if (first)
            {
                DownloadSettingsSnapshot current;
                try { current = await LoadSettingsAsync(cancellationToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { return SettingsCancelled(); }
                catch (Exception error) { return SettingsFailure(SettingsError(error)); }
                var basicChanged = BasicSettings(request.Expected.Value) != BasicSettings(desired);
                var scheduleChanged = !ScheduleSettingsMatch(request.Expected.Value, desired);
                if (!basicChanged && !scheduleChanged) return SettingsFailure(MutationErrorCategory.Conflict);
                if (current.CanEditDestination != request.Expected.CanEditDestination ||
                    (basicChanged && BasicSettings(current.Value) != BasicSettings(request.Expected.Value)) ||
                    (scheduleChanged && (current.ScheduleStatus != DownloadStationSectionStatus.Available || !ScheduleSettingsMatch(current.Value, request.Expected.Value))))
                    return SettingsFailure(MutationErrorCategory.Conflict);
                operation = new(signature, desired, request.Expected,
                    basicChanged ? DownloadSettingsComponentState.NotStarted : DownloadSettingsComponentState.Unchanged,
                    scheduleChanged ? DownloadSettingsComponentState.NotStarted : DownloadSettingsComponentState.Unchanged);
                state.Requests[request.ClientRequestId] = operation; state.Pending[owner] = operation;
            }
            var op = operation!;
            // 已开始的组件只回读；新写只在首次确认或明确继续时执行。
            await ReviewSettingsComponentsAsync(op, cancellationToken).ConfigureAwait(false);
            if ((first || request.ContinueRemaining) && op.Basic != DownloadSettingsComponentState.Unknown && op.Schedule != DownloadSettingsComponentState.Unknown)
            {
                if (op.Basic == DownloadSettingsComponentState.NotStarted)
                    await SubmitSettingsComponentAsync(op, basic: true, cancellationToken).ConfigureAwait(false);
                if (op.Basic is DownloadSettingsComponentState.Confirmed or DownloadSettingsComponentState.Unchanged && op.Schedule == DownloadSettingsComponentState.NotStarted)
                    await SubmitSettingsComponentAsync(op, basic: false, cancellationToken).ConfigureAwait(false);
            }
            var outcome = SettingsOutcome(op);
            if (!outcome.RequiresReview && !outcome.CanContinue) { op.Terminal = outcome; state.Pending.Remove(owner); }
            return outcome;
        }
        finally { state.Gate.Release(); }
    }

    private async Task SubmitSettingsComponentAsync(DownloadSettingsOperation op, bool basic, CancellationToken token)
    {
        try
        {
            if (basic)
            {
                if (op.Expected.CanEditDestination && op.Desired.DefaultDestination != op.Expected.Value.DefaultDestination)
                    await RequireDownloadSettingsFolderAsync(op.Desired.DefaultDestination!, token).ConfigureAwait(false);
                var current = await ReadDownloadBasicSettingsAsync(token).ConfigureAwait(false);
                if (BasicSettings(current) != BasicSettings(op.Expected.Value)) throw new DownloadSettingsConflictException();
            }
            else
            {
                var current = await ReadDownloadScheduleAsync(token).ConfigureAwait(false);
                if (current.Enabled != op.Expected.Value.IsScheduleEnabled || current.EmuleEnabled != op.Expected.Value.IsEmuleScheduleEnabled) throw new DownloadSettingsConflictException();
            }
            token.ThrowIfCancellationRequested();
        }
        catch (Exception error) { op.Cancelled |= error is OperationCanceledException; op.Error = SettingsError(error); SetComponent(op, basic, DownloadSettingsComponentState.Rejected); return; }

        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var desired = op.Desired;
        static string Flag(bool? value) => value == true ? "true" : "false";
        static string Limit(int? value) => value!.Value.ToString(CultureInfo.InvariantCulture);
        if (basic)
        {
            values["emule_enabled"] = Flag(desired.IsEmuleEnabled); values["unzip_service_enabled"] = Flag(desired.IsAutoExtractEnabled);
            values["bt_max_download"] = Limit(desired.BtDownloadLimitKb); values["bt_max_upload"] = Limit(desired.BtUploadLimitKb);
            values["http_max_download"] = Limit(desired.HttpDownloadLimitKb); values["ftp_max_download"] = Limit(desired.HttpDownloadLimitKb);
            values["nzb_max_download"] = Limit(desired.NzbDownloadLimitKb); values["emule_max_download"] = Limit(desired.EmuleDownloadLimitKb); values["emule_max_upload"] = Limit(desired.EmuleUploadLimitKb);
            if (op.Expected.CanEditDestination)
                values["default_destination"] = _capabilities[PublicDownloadInfoApi].RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)
                    ? JsonSerializer.Serialize(desired.DefaultDestination) : desired.DefaultDestination!;
        }
        else { values["enabled"] = Flag(desired.IsScheduleEnabled); values["emule_enabled"] = Flag(desired.IsEmuleScheduleEnabled); }
        op.Submitted = true; SetComponent(op, basic, DownloadSettingsComponentState.Unknown);
        try
        {
            await CallPublicDownloadAsync(basic ? PublicDownloadInfoApi : PublicDownloadScheduleApi,
                basic ? "setserverconfig" : "setconfig", values, token, basic ? DownloadSettingsInfoVersion : 1).ConfigureAwait(false);
        }
        catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
        { op.Error = SettingsError(error); SetComponent(op, basic, DownloadSettingsComponentState.Rejected); return; }
        catch (OperationCanceledException) { op.Cancelled = true; return; }
        catch { return; }
        await ReviewSettingsComponentsAsync(op, token).ConfigureAwait(false);
    }

    private async Task RequireDownloadSettingsFolderAsync(string destination, CancellationToken token)
    {
        if (!Supports("SYNO.FileStation.List")) throw new DownloadSettingsPermissionException();
        var target = "/" + destination;
        var split = target.LastIndexOf('/');
        var parent = split == 0 ? "" : target[..split];
        var offset = 0;
        while (offset < 5000)
        {
            var page = await ListFilesAsync(parent, offset, 200, new FileListOptions(TypeFilter: FileListTypeFilter.Folders), token).ConfigureAwait(false);
            if (page.Offset != offset || page.Total < offset + page.Items.Count || page.Items.Count > 200) throw InvalidDownloadStationResponse();
            var folder = page.Items.SingleOrDefault(item => item.Path == target);
            if (folder is not null)
            {
                if (!folder.IsDirectory || !folder.CanWrite) throw new DownloadSettingsPermissionException();
                return;
            }
            if (page.Items.Count == 0 || offset + page.Items.Count >= page.Total) break;
            offset = checked(offset + page.Items.Count);
        }
        throw new DownloadSettingsPermissionException();
    }

    private async Task ReviewSettingsComponentsAsync(DownloadSettingsOperation op, CancellationToken token)
    {
        if (op.Basic == DownloadSettingsComponentState.Unknown)
        {
            try { if (BasicSettings(await ReadDownloadBasicSettingsAsync(token).ConfigureAwait(false)) == BasicSettings(op.Desired)) op.Basic = DownloadSettingsComponentState.Confirmed; }
            catch { /* 未知写结果只保留核对状态。 */ }
        }
        if (op.Schedule == DownloadSettingsComponentState.Unknown)
        {
            try { var value = await ReadDownloadScheduleAsync(token).ConfigureAwait(false); if (value.Enabled == op.Desired.IsScheduleEnabled && value.EmuleEnabled == op.Desired.IsEmuleScheduleEnabled) op.Schedule = DownloadSettingsComponentState.Confirmed; }
            catch { /* 计划回读独立失败不能覆盖基础设置已确认的结果。 */ }
        }
    }

    private static void SetComponent(DownloadSettingsOperation op, bool basic, DownloadSettingsComponentState value)
    { if (basic) op.Basic = value; else op.Schedule = value; }
    private static MutationErrorCategory SettingsError(Exception error) => error switch
    { DownloadSettingsConflictException => MutationErrorCategory.Conflict, DownloadSettingsPermissionException => MutationErrorCategory.Permission, DsmException { AuthenticationFailure: true } => MutationErrorCategory.Authentication,
        DsmException { Code: 105 } => MutationErrorCategory.Permission, _ => MutationErrorCategory.Network };
    private static DownloadSettingsSaveOutcome SettingsFailure(MutationErrorCategory error) => new(new(1, MutationResultStatus.ConfirmedFailure, "downloadSettings", false, false,
        new(0, 1, 0), error), null, DownloadSettingsComponentState.Rejected, DownloadSettingsComponentState.Unchanged);
    private static DownloadSettingsSaveOutcome SettingsCancelled() => new(new(1, MutationResultStatus.CancelledBeforeSubmission, "downloadSettings", false, false,
        new(0, 0, 0)), null, DownloadSettingsComponentState.Rejected, DownloadSettingsComponentState.Unchanged);
    private static DownloadSettingsSaveOutcome SettingsOutcome(DownloadSettingsOperation op)
    {
        if (op.Cancelled && !op.Submitted) return SettingsCancelled();
        var components = new[] { op.Basic, op.Schedule };
        var succeeded = components.Count(value => value == DownloadSettingsComponentState.Confirmed);
        var unknown = components.Count(value => value == DownloadSettingsComponentState.Unknown);
        var failed = components.Count(value => value is DownloadSettingsComponentState.Rejected or DownloadSettingsComponentState.NotStarted);
        var status = unknown > 0 ? op.Cancelled ? MutationResultStatus.CancellationRequestedAfterSubmission : MutationResultStatus.SubmittedButUnverified : failed > 0
            ? succeeded > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.ConfirmedFailure : MutationResultStatus.ConfirmedSuccess;
        return new(new(1, status, "downloadSettings", op.Submitted, unknown > 0, new(succeeded, failed, unknown), op.Error),
            status == MutationResultStatus.ConfirmedSuccess ? op.Expected with { Value = op.Desired } : null, op.Basic, op.Schedule);
    }
    private sealed class DownloadSettingsConflictException : Exception;
    private sealed class DownloadSettingsPermissionException : Exception;
    private sealed class DownloadSettingsApiState
    {
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public Dictionary<Guid, DownloadSettingsOperation> Requests { get; } = [];
        public Dictionary<(Guid, string), DownloadSettingsOperation> Pending { get; } = [];
    }
    private sealed class DownloadSettingsOperation(string signature, DownloadStationSettingsSummary desired, DownloadSettingsSnapshot expected,
        DownloadSettingsComponentState basic, DownloadSettingsComponentState schedule)
    {
        public string Signature { get; } = signature;
        public DownloadStationSettingsSummary Desired { get; } = desired;
        public DownloadSettingsSnapshot Expected { get; } = expected;
        public DownloadSettingsComponentState Basic { get; set; } = basic;
        public DownloadSettingsComponentState Schedule { get; set; } = schedule;
        public bool Submitted { get; set; }
        public bool Cancelled { get; set; }
        public MutationErrorCategory? Error { get; set; }
        public DownloadSettingsSaveOutcome? Terminal { get; set; }
    }
}
