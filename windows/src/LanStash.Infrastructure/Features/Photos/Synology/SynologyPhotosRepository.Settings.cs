using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoSettingsRecord(Guid Id, Guid ProfileId, string Owner, SynologyPhotoAutomaticSetting? Automatic,
        SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready, bool Submitted = false, SynologyPhotoFailure? Failure = null,
        SynologyPhotoDisplaySettingChange? Display = null, SynologyPhotoDuplicateSettingChange? Duplicates = null, SynologyPhotoRecognitionSettingChange? Recognition = null,
        SynologyPhotoSharedSettingChange? Shared = null, SynologyPhotoSharedSettings? SharedResult = null,
        SynologyPhotoGlobalSettingChange? Global = null, SynologyPhotoConversionCache? Cache = null,
        PhotoSettingStepFact[]? Steps = null, int CompletedSteps = 0, SynologyPhotoGlobalSettings? GlobalResult = null, SynologyPhotoConversionCache? CacheResult = null,
        PhotoMembersRecord? Members = null, PhotoMaintenanceRecord? Maintenance = null, PhotoCodecRecord? Codec = null, PhotoBackgroundRecord? Background = null);
    private sealed record PhotoSettingStepFact(SynologyPhotoSettingStep Kind, SynologyPhotoWriteStatus Status);
    private sealed class PhotoSettingsTask(PhotoSettingsRecord record)
    {
        internal volatile PhotoSettingsRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal volatile bool Running;
    }
    private static PhotoSettingsRecord RestoreSettings(Guid id, PhotoSettingsRecord record)
    {
        ValidateSettingPayload(record);
        if (id == Guid.Empty || record.Id != id || record.ProfileId == Guid.Empty || !UploadHash(record.Owner) ||
            !Enum.IsDefined(record.State) || record.Failure is { } failure && !Enum.IsDefined(failure) ||
            record.State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview && !record.Submitted ||
            record.State == SynologyPhotoChangeState.Ready && record.Submitted ||
            record.State == SynologyPhotoChangeState.Completed && !record.Submitted && SettingParameters(record).Count != 0) throw Invalid();
        return record with { State = record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview :
            record.State == SynologyPhotoChangeState.Ready ? SynologyPhotoChangeState.Failed : record.State };
    }
    private void CheckSettingsOwner(PhotoSettingsRecord record)
    {
        RequireManagementStore(); RequireAccess();
        if (record.ProfileId != ProfileId || record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private static bool ActiveSettings(PhotoSettingsRecord record) => record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview;
    private bool SettingsBusy() => _changes.Settings.Values.Any(task => task.Record.Owner == UploadOwner() && task.Record.Background is null && ActiveSettings(task.Record));
    private PhotoSettingsTask OwnedSettings(Guid id)
    {
        if (!_changes.Settings.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckSettingsOwner(task.Record); return task;
    }
    private async Task SaveSettingsAsync(PhotoSettingsTask task, PhotoSettingsRecord record)
    { task.Record = record; await SaveManagementRecordAsync(record.Id, new(1, Settings: record)).ConfigureAwait(false); }
    private static SynologyPhotoSettingsChange SettingsSnapshot(PhotoSettingsTask task) => new(task.Record.Id, task.Record.Automatic, task.Record.State, task.Running, task.Record.Failure)
    { Display = task.Record.Display, Duplicates = task.Record.Duplicates, Recognition = task.Record.Recognition, Shared = task.Record.Shared, SharedResult = task.Record.SharedResult,
      Global = task.Record.Global, Cache = task.Record.Cache, GlobalResult = task.Record.GlobalResult, CacheResult = task.Record.CacheResult,
      Maintenance = task.Record.Maintenance?.Change, MaintenanceResult = task.Record.Maintenance?.Result,
      MaintenanceAccepted = task.Record.Maintenance?.Receipt == SynologyPhotoWriteStatus.Accepted, Codec = task.Record.Codec?.Response,
      CodecGenerationAccepted = task.Record.Codec?.GenerationReceipt == SynologyPhotoWriteStatus.Accepted,
      Background = task.Record.Background is { } background ? background.Command with { Targets = background.Command.Targets.ToArray() } : null,
      CompletedSteps = task.Record.CompletedSteps, TotalSteps = task.Record.Background?.Command.Targets.Count ?? (task.Record.Maintenance is not null ? 1 : task.Record.Codec is { } codec ? codec.Response.Generate ? 2 : 1 : task.Record.Members is { } members ? MemberSteps(members.Plan).Count : GlobalSteps(task.Record).Count),
      HasMemberChanges = task.Record.Members is not null, MemberChangesObserved = task.Record.Members?.Changed == true };
    public async Task<IReadOnlyList<SynologyPhotoSettingsChange>> SettingsChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Settings.Values.Where(task => task.Record.Owner == owner && task.Record.Background is null).Select(SettingsSnapshot).ToArray();
    }
    private async Task ValidateSettingsAsync(PhotoSettingsRecord record, CancellationToken token)
    {
        CheckSettingsOwner(record); var generation = Volatile.Read(ref _accessGeneration);
        if (record.Background is not null)
        { await ValidateBackgroundAsync(record, token).ConfigureAwait(false); RequireGeneration(generation, token); CheckSettingsOwner(record); return; }
        await FreshManagementAccessAsync([], token).ConfigureAwait(false);
        if (record.Maintenance is not null || record.Codec is not null)
        { await ValidateMaintenanceAsync(record, token).ConfigureAwait(false); RequireGeneration(generation, token); CheckSettingsOwner(record); return; }
        if (record.Members is not null)
        { await ValidateMembersAsync(record, false, token).ConfigureAwait(false); RequireGeneration(generation, token); CheckSettingsOwner(record); return; }
        if (record.Global is not null || record.Cache is not null)
        { await ValidateGlobalSettingsAsync(record, token).ConfigureAwait(false); RequireGeneration(generation, token); CheckSettingsOwner(record); return; }
        if (!await SettingMatchesAsync(record, false, token).ConfigureAwait(false))
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        CheckSharedSettingSafety(record);
        _ = Capability(SettingEndpoint(record), 1, null); RequireGeneration(generation, token); CheckSettingsOwner(record);
    }
    public Task<SynologyPhotoSettingsChange> SetAutomaticPreviewAsync(Guid operationId, bool original, bool enabled, CancellationToken cancellationToken = default) =>
        SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), new(original, enabled)), cancellationToken);
    private async Task<SynologyPhotoSettingsChange> SetPreferenceAsync(PhotoSettingsRecord record, CancellationToken cancellationToken)
    {
        var operationId = record.Id;
        if (operationId == Guid.Empty) throw Invalid();
        ValidateSettingPayload(record); var parameters = SettingParameters(record);
        await LoadChangesAsync().ConfigureAwait(false); PhotoSettingsTask task; var existing = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(operationId) || _changes.Folders.ContainsKey(operationId) || _changes.Files.ContainsKey(operationId) ||
                _changes.Albums.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) ||
                _changes.Requests.ContainsKey(operationId) || _changes.FolderSharing.ContainsKey(operationId) || _changes.Recognition.ContainsKey(operationId) ||
                _changes.Previews.ContainsKey(operationId) || _changes.Automatic.ContainsKey(operationId)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Settings.TryGetValue(operationId, out task!))
            {
                CheckSettingsOwner(task.Record);
                if (task.Record.Automatic != record.Automatic || task.Record.Display != record.Display || task.Record.Duplicates != record.Duplicates || task.Record.Recognition != record.Recognition || task.Record.Shared != record.Shared ||
                    task.Record.Cache != record.Cache || !SameGlobalChange(task.Record.Global, record.Global) || !SameMembersPlan(task.Record.Members, record.Members) ||
                    task.Record.Maintenance?.Change != record.Maintenance?.Change || task.Record.Codec?.Response != record.Codec?.Response || !SameBackgroundCommand(task.Record.Background, record.Background))
                    throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                existing = true;
            }
            else
            {
                if (record.Background is null ? SettingsBusy() : BackgroundBusy(record)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
                await ValidateSettingsAsync(record, cancellationToken).ConfigureAwait(false);
                task = new(record); await SaveSettingsAsync(task, record).ConfigureAwait(false); _changes.Settings.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        if (existing) return await ReviewSettingsChangeAsync(operationId, cancellationToken).ConfigureAwait(false);
        if (record.Background is not null) return await ExecuteBackgroundAsync(task, cancellationToken).ConfigureAwait(false);
        if (record.Maintenance is not null || record.Codec is not null) return await ExecuteMaintenanceAsync(task, cancellationToken).ConfigureAwait(false);
        if (record.Members is not null) return await ExecuteMembersAsync(task, cancellationToken).ConfigureAwait(false);
        if (record.Global is not null || record.Cache is not null) return await ExecuteGlobalSettingsAsync(task, cancellationToken).ConfigureAwait(false);
        await task.Gate.WaitAsync(CancellationToken.None).ConfigureAwait(false); task.Running = true;
        var owner = _changes.Owners.GetOrAdd(record.Owner, _ => new(1, 1)); var owns = false; var sent = false;
        try
        {
            await owner.WaitAsync(cancellationToken).ConfigureAwait(false); owns = true;
            var generation = Volatile.Read(ref _accessGeneration);
            await ValidateSettingsAsync(record, cancellationToken).ConfigureAwait(false); RequireGeneration(generation, cancellationToken);
            if (parameters.Count == 0)
                await SaveSettingsAsync(task, record with { State = SynologyPhotoChangeState.Completed, SharedResult = record.Shared?.Original }).ConfigureAwait(false);
            else
            {
                await SaveSettingsAsync(task, record with { State = SynologyPhotoChangeState.Submitting, Submitted = true }).ConfigureAwait(false);
                await ValidateSettingsAsync(record, cancellationToken).ConfigureAwait(false); RequireGeneration(generation, cancellationToken);
                sent = true;
                var receipt = await _api.WritePhotoAsync(_profile, _session, Capability(SettingEndpoint(record), 1, null), 1, record.Shared?.ChangesEnabled == true ? "set_enable" : "set",
                    parameters, cancellationToken).ConfigureAwait(false);
                await SaveSettingsAsync(task, task.Record with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                    Failure = receipt.Failure }).ConfigureAwait(false);
                RequireGeneration(generation, cancellationToken); CheckSettingsOwner(task.Record);
                await ReviewSettingsCoreAsync(task, cancellationToken).ConfigureAwait(false);
            }
        }
        catch (Exception error) when (PreviewError(error))
        {
            RequireManagementStore();
            if (task.Record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Failed))
                await SaveSettingsAsync(task, task.Record with { State = sent ? SynologyPhotoChangeState.PendingReview : cancellationToken.IsCancellationRequested ? SynologyPhotoChangeState.Cancelled : SynologyPhotoChangeState.Failed,
                    Submitted = sent, Failure = PreviewFailure(error) }).ConfigureAwait(false);
        }
        finally { task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return SettingsSnapshot(task);
    }
    public async Task<SynologyPhotoSettingsChange> ReviewSettingsChangeAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedSettings(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return SettingsSnapshot(task);
        try { await ReviewSettingsCoreAsync(task, cancellationToken).ConfigureAwait(false); return SettingsSnapshot(task); }
        finally { task.Gate.Release(); }
    }
    private async Task ReviewSettingsCoreAsync(PhotoSettingsTask task, CancellationToken token)
    {
        if (task.Record.State is not (SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview)) return;
        if (task.Record.Background is not null) { await ReviewBackgroundAsync(task, token).ConfigureAwait(false); return; }
        if (task.Record.Maintenance is not null || task.Record.Codec is not null) { await ReviewMaintenanceAsync(task, token).ConfigureAwait(false); return; }
        if (task.Record.Members is not null) { await ReviewMembersAsync(task, token).ConfigureAwait(false); return; }
        if (task.Record.Global is not null || task.Record.Cache is not null) { await ReviewGlobalSettingsAsync(task, token).ConfigureAwait(false); return; }
        try
        {
            CheckSettingsOwner(task.Record); var generation = Volatile.Read(ref _accessGeneration);
            await FreshManagementAccessAsync([], token).ConfigureAwait(false);
            var shared = task.Record.Shared is null ? null : await SharedSettingsAsync(token).ConfigureAwait(false);
            var matches = shared is not null ? SharedSettingMatches(task.Record.Shared!, shared, true) : await SettingMatchesAsync(task.Record, true, token).ConfigureAwait(false);
            RequireGeneration(generation, token); CheckSettingsOwner(task.Record);
            if (matches)
                await SaveSettingsAsync(task, task.Record with { State = SynologyPhotoChangeState.Completed, Failure = null, SharedResult = shared }).ConfigureAwait(false);
        }
        catch (Exception error) when (PreviewError(error)) { RequireManagementStore(); }
    }
}
