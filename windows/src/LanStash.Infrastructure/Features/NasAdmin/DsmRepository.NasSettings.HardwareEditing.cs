using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasHardwareEditRecovery> SaveZramAsync(NasZramSaveRequest request, CancellationToken cancellationToken = default)
    {
        if (request is null || request.ProfileId != ProfileId || request.RequestId == Guid.Empty || !request.RiskConfirmed ||
            request.Baseline?.IsEnabled is not { } baseline || request.Baseline.NeedsReboot is null || baseline == request.Enabled)
            throw NasEditError(MutationErrorCategory.Validation);
        var signature = ServiceHash(JsonSerializer.Serialize(new { baseline, request.Enabled }));
        await EnterNasManagementAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (FindExistingHardwareEdit(request.RequestId, NasHardwareEditKind.Zram, signature) is { } prior)
            { await ReviewHardwareEditCoreAsync(prior, cancellationToken).ConfigureAwait(false); return HardwareEditInfo(prior); }
            await RequireNasHardwarePermissionAsync(NasHardwareEditKind.Zram, cancellationToken).ConfigureAwait(false);
            var current = await LoadZramAsync(cancellationToken).ConfigureAwait(false);
            if (current.IsEnabled != baseline || current.NeedsReboot is null) throw NasEditError(MutationErrorCategory.Conflict);
            var entry = NewHardwareEdit(request.RequestId, NasHardwareEditKind.Zram, signature, ZramDigest(request.Enabled), ZramDigest(request.Enabled));
            await SubmitHardwareEditStepAsync(entry, 0, "SYNO.Core.Hardware.ZRAM", "set",
                new() { ["enable_zram"] = request.Enabled }, cancellationToken).ConfigureAwait(false);
            await ReviewHardwareEditCoreAsync(entry, cancellationToken).ConfigureAwait(false);
            if (entry.Steps[0].Stage == NasHardwareEditStage.Confirmed)
                await MarkZramRebootCoreAsync(entry, cancellationToken).ConfigureAwait(false);
            return HardwareEditInfo(entry);
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    public async Task<NasHardwareEditRecovery> SavePowerScheduleAsync(NasPowerScheduleSaveRequest request, CancellationToken cancellationToken = default)
    {
        if (request is null || request.ProfileId != ProfileId || request.RequestId == Guid.Empty || !request.RiskConfirmed ||
            request.Baseline?.CanEdit != true || !NasPowerScheduleRules.IsValid(request.Entries)) throw NasEditError(MutationErrorCategory.Validation);
        // 草稿在跨越任何 await 之前冻结；外部集合变更不能改变用户确认的写入内容。
        var entries = request.Entries.Select(entry => entry with { Weekdays = entry.Weekdays.ToArray() }).ToArray();
        var baselineDigest = PowerScheduleDigest(request.Baseline);
        var desired = new NasPowerScheduleSnapshot(entries, request.Baseline.TimeZoneIdentifier, entries.Length, false, 0) { SupportsEditing = true };
        var desiredDigest = PowerScheduleDigest(desired);
        if (desiredDigest == baselineDigest) throw NasEditError(MutationErrorCategory.Validation);
        var signature = ServiceHash(JsonSerializer.Serialize(new { baselineDigest, desiredDigest }));
        await EnterNasManagementAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (FindExistingHardwareEdit(request.RequestId, NasHardwareEditKind.PowerSchedule, signature) is { } prior)
            { await ReviewHardwareEditCoreAsync(prior, cancellationToken).ConfigureAwait(false); return HardwareEditInfo(prior); }
            await RequireNasHardwarePermissionAsync(NasHardwareEditKind.PowerSchedule, cancellationToken).ConfigureAwait(false);
            var current = await LoadPowerScheduleAsync(cancellationToken).ConfigureAwait(false);
            if (!current.CanEdit || PowerScheduleDigest(current) != baselineDigest) throw NasEditError(MutationErrorCategory.Conflict);
            var entry = NewHardwareEdit(request.RequestId, NasHardwareEditKind.PowerSchedule, signature, desiredDigest);
            object[] Rows(NasPowerScheduleAction action) => entries.Where(item => item.Action == action).Select(item => (object)new
            { enabled = item.IsEnabled!.Value, weekdays = string.Join(',', NasPowerScheduleRules.Days(item).Select(day => (int)day)), hour = item.Hour, min = item.Minute }).ToArray();
            await SubmitHardwareEditStepAsync(entry, 0, "SYNO.Core.Hardware.PowerSchedule", "save",
                new() { ["poweron_tasks"] = Rows(NasPowerScheduleAction.Startup), ["poweroff_tasks"] = Rows(NasPowerScheduleAction.Shutdown) }, cancellationToken).ConfigureAwait(false);
            await ReviewHardwareEditCoreAsync(entry, cancellationToken).ConfigureAwait(false);
            return HardwareEditInfo(entry);
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    public async Task<NasHardwareEditRecovery> MarkZramRebootAsync(Guid id, bool riskConfirmed, CancellationToken cancellationToken = default)
    {
        if (!riskConfirmed) throw NasEditError(MutationErrorCategory.Validation);
        await EnterNasManagementAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var entry = NasManagementEntry(id);
            if (entry.Package is not null) throw NasEditError(MutationErrorCategory.Validation);
            await ReviewHardwareEditCoreAsync(entry, cancellationToken).ConfigureAwait(false);
            if (!HardwareEditInfo(entry).CanMarkReboot) return HardwareEditInfo(entry);
            await MarkZramRebootCoreAsync(entry, cancellationToken).ConfigureAwait(false);
            return HardwareEditInfo(entry);
        }
        finally { NasManagementRecords.Gate.Release(); }
    }
    private async Task MarkZramRebootCoreAsync(NasManagementRecord entry, CancellationToken token)
    {
        try
        {
            await RequireNasHardwarePermissionAsync(NasHardwareEditKind.Zram, token).ConfigureAwait(false);
            var current = await LoadZramAsync(token).ConfigureAwait(false);
            if (current.IsEnabled is not { } enabled || current.NeedsReboot is null || ZramDigest(enabled) != entry.Steps[0].DesiredDigest)
                throw NasEditError(MutationErrorCategory.Conflict);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
        catch (Exception error)
        {
            entry.Steps[1].Error = error is NasHardwareEditException edit ? edit.Category :
                error is DsmException dsm ? ServiceErrorCategory(dsm) : MutationErrorCategory.Network;
            await SaveNasManagementAsync(entry).ConfigureAwait(false); return;
        }
        // 即使原来已有重启要求，也为本次压缩变更提交独立标记；从不触发电源操作。
        await SubmitHardwareEditStepAsync(entry, 1, "SYNO.Core.Hardware.NeedReboot", "set", new(), token).ConfigureAwait(false);
        await ReviewHardwareEditCoreAsync(entry, token).ConfigureAwait(false);
    }
    private NasManagementRecord? FindExistingHardwareEdit(Guid id, NasHardwareEditKind kind, string signature)
    {
        if (NasManagementRecords.Entries.TryGetValue(id, out var entry))
        {
            if (entry.Package is not null || entry.Owner != NasManagementOwner || entry.ProfileId != ProfileId || entry.Kind != kind || entry.Signature != signature)
                throw NasEditError(MutationErrorCategory.Conflict);
            return entry;
        }
        if (NasManagementRecords.Entries.Values.Any(item => item.Package is null && item.Owner == NasManagementOwner && item.ProfileId == ProfileId && item.Kind == kind &&
            (item.Steps.Any(step => step.Stage == NasHardwareEditStage.Unknown) ||
                kind == NasHardwareEditKind.Zram && item.Steps[0].Stage == NasHardwareEditStage.Confirmed && item.Steps[1].Stage != NasHardwareEditStage.Confirmed)))
            throw NasEditError(MutationErrorCategory.Conflict);
        return null;
    }
    private NasManagementRecord NewHardwareEdit(Guid id, NasHardwareEditKind kind, string signature, params string[] digests) => new()
    {
        Id = id, ProfileId = ProfileId, Owner = NasManagementOwner, Kind = kind, Signature = signature, CreatedAt = DateTimeOffset.UtcNow,
        Steps = digests.Select(digest => new NasManagementStep { DesiredDigest = digest }).ToArray(),
    };
    private async Task RequireNasHardwarePermissionAsync(NasHardwareEditKind kind, CancellationToken token)
    {
        await PrepareServiceSettingsAsync(token).ConfigureAwait(false);
        if (!_nasServiceSessionVerified) throw NasEditError(MutationErrorCategory.Unsupported);
        if (!_nasServiceAdministrator) throw NasEditError(MutationErrorCategory.Permission);
        if (kind == NasHardwareEditKind.Zram ? !NasSettingsWriteAvailability.CanSaveZram : !NasSettingsWriteAvailability.CanSavePowerSchedule)
            throw NasEditError(MutationErrorCategory.Unsupported);
    }
    private async Task SubmitHardwareEditStepAsync(NasManagementRecord entry, int index, string api, string method,
        Dictionary<string, object> parameters, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var capability = SecurityCapability(api, 1) ?? throw NasEditError(MutationErrorCategory.Unsupported);
        var step = entry.Steps[index]; step.Stage = NasHardwareEditStage.Unknown; step.Submitted = true; step.Accepted = false; step.Error = null;
        await SaveNasManagementAsync(entry).ConfigureAwait(false);
        try
        {
            await SecurityCallAsync(capability, method, parameters, token).ConfigureAwait(false);
            step.Accepted = true;
        }
        catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
        { step.Stage = NasHardwareEditStage.Rejected; step.Error = ServiceErrorCategory(error); }
        catch (Exception) { step.Error = MutationErrorCategory.Network; }
        await SaveNasManagementAsync(entry).ConfigureAwait(false);
    }
    private async Task ReviewHardwareEditCoreAsync(NasManagementRecord entry, CancellationToken token)
    {
        if (!entry.Steps.Any(step => step.Stage == NasHardwareEditStage.Unknown)) return;
        try
        {
            if (entry.Kind == NasHardwareEditKind.Zram)
            {
                var current = await LoadZramAsync(token).ConfigureAwait(false);
                if (current.IsEnabled is { } enabled)
                    for (var index = 0; index < entry.Steps.Length; index++)
                    {
                        var step = entry.Steps[index];
                        if (step.Stage == NasHardwareEditStage.Unknown && step.Accepted && ZramDigest(enabled) == step.DesiredDigest &&
                            (index == 0 || current.NeedsReboot == true && entry.Steps[0].Stage == NasHardwareEditStage.Confirmed))
                        { step.Stage = NasHardwareEditStage.Confirmed; step.Error = null; }
                    }
            }
            else
            {
                var current = await LoadPowerScheduleAsync(token).ConfigureAwait(false); var step = entry.Steps[0];
                if (current.CanEdit && step.Accepted && PowerScheduleDigest(current) == step.DesiredDigest)
                { step.Stage = NasHardwareEditStage.Confirmed; step.Error = null; }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { /* 失败读取不能释放未知操作；只保留原提交与接受事实。 */ }
        await SaveNasManagementAsync(entry).ConfigureAwait(false);
    }
    private static string ZramDigest(bool enabled) => ServiceHash(JsonSerializer.Serialize(new { enabled }));
    private static string PowerScheduleDigest(NasPowerScheduleSnapshot snapshot) => ServiceHash(JsonSerializer.Serialize(new
    {
        snapshot.TimeZoneIdentifier,
        rows = snapshot.Entries.Select(entry => JsonSerializer.Serialize(new
        {
            entry.Action, entry.IsEnabled, entry.Hour, entry.Minute,
            days = NasPowerScheduleRules.Days(entry).Select(day => (int)day).ToArray(),
        })).OrderBy(row => row, StringComparer.Ordinal).ToArray(),
    }));
    private static NasHardwareEditException NasEditError(MutationErrorCategory category) => new(category);
}
