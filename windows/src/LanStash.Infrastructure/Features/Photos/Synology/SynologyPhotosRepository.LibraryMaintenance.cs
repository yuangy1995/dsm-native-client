using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoMaintenanceRecord(SynologyPhotoMaintenanceChange Change, SynologyPhotoWriteStatus? Receipt = null, SynologyPhotoLibraryMaintenance? Result = null);
    private sealed record PhotoCodecRecord(SynologyPhotoCodecResponse Response, SynologyPhotoWriteStatus? GenerationReceipt = null,
        SynologyPhotoWriteStatus? PromptReceipt = null, bool PromptClosed = false);
    public async Task<SynologyPhotoLibraryMaintenance> LibraryMaintenanceAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        RequireAccess(space); var generation = Volatile.Read(ref _accessGeneration);
        var identity = await CallAsync("UserInfo", 1, "me", cancellationToken: cancellationToken).ConfigureAwait(false);
        var userId = Positive(identity, "id");
        if (!Boolean(identity, "enabled") || userId != _currentUserId || space == SynologyPhotoSpace.Shared && KnownPreference(identity, "is_admin") != true)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var user = await CallAsync("Setting.User", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        if (space == SynologyPhotoSpace.Personal)
        { if (!Boolean(user, "enable_home_service")) throw new SynologyPhotoException(SynologyPhotoFailure.Permission); }
        else
        {
            var team = await CallAsync("Setting.TeamSpace", 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
            if (!Boolean(team, "enabled") || Text(user, "team_space_permission") is not ("entry" or "management"))
                throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        }
        var counts = await CallAsync("Index", 1, "get", cancellationToken: cancellationToken, space: space).ConfigureAwait(false);
        var basic = Number(counts, "basic"); var thumbnail = Number(counts, "thumbnail");
        if (basic < 0 || thumbnail < 0) throw Invalid(); RequireGeneration(generation, cancellationToken);
        return new(ProfileId, userId, space, basic, thumbnail, OptionalObject(user, "ame_status") is { } ame && KnownPreference(ame, "has_h264") == true);
    }
    private async Task<SynologyPhotoCodecPrompt> ReadCodecPromptAsync(CancellationToken token)
    {
        RequireAccess(); var generation = Volatile.Read(ref _accessGeneration);
        var identity = await CallAsync("UserInfo", 1, "me", cancellationToken: token).ConfigureAwait(false);
        var userId = Positive(identity, "id");
        if (!Boolean(identity, "enabled") || userId != _currentUserId || KnownPreference(identity, "is_admin") is not { } admin)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var user = await CallAsync("Setting.User", 1, "get", cancellationToken: token).ConfigureAwait(false);
        var prompts = List(await CallAsync("Setting.Wizard", 1, "get", cancellationToken: token).ConfigureAwait(false), "prompt");
        var values = prompts.Select(value => (Name: Text(value, "name"), Show: Boolean(value, "show"))).Where(value => value.Name == "new_codec_installed").ToArray();
        if (values.Length > 1) throw Invalid(); RequireGeneration(generation, token);
        return new(ProfileId, userId, admin, values.SingleOrDefault().Show, Boolean(user, "enable_home_service"));
    }
    public async Task<SynologyPhotoCodecPrompt> CodecPromptAsync(CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration);
        await LoadChangesAsync().ConfigureAwait(false); var current = await ReadCodecPromptAsync(cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken);
        var owner = UploadOwner();
        // 已关闭提示的事实单独保留，允许将来出现的新提示；旧的已接收生成不因重启丢失。
        if (!current.ShouldShow)
        {
            foreach (var task in _changes.Settings.Values.Where(task => task.Record.Owner == owner && !ActiveSettings(task.Record) &&
                task.Record.Codec is { GenerationReceipt: SynologyPhotoWriteStatus.Accepted, PromptClosed: false }))
            {
                if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) continue;
                try { RequireGeneration(generation, cancellationToken); CheckSettingsOwner(task.Record); await SaveSettingsAsync(task, task.Record with { Codec = task.Record.Codec! with { PromptClosed = true } }).ConfigureAwait(false); }
                finally { task.Gate.Release(); }
            }
        }
        RequireGeneration(generation, cancellationToken);
        return current with { GenerationAlreadySubmitted = current.ShouldShow && _changes.Settings.Values.Any(task => task.Record.Owner == owner &&
            task.Record.Codec is { GenerationReceipt: SynologyPhotoWriteStatus.Accepted, PromptClosed: false }) };
    }
    public Task<SynologyPhotoSettingsChange> MaintainLibraryAsync(Guid operationId, SynologyPhotoLibraryMaintenance original,
        SynologyPhotoMaintenanceAction action, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (!confirmed) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null, Maintenance: new(new(original, action))), cancellationToken);
    }
    public Task<SynologyPhotoSettingsChange> RespondToCodecPromptAsync(Guid operationId, SynologyPhotoCodecPrompt original,
        bool generate, bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (generate && !confirmed) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null, Codec: new(new(original, generate))), cancellationToken);
    }
    private static void ValidateMaintenanceRecord(PhotoSettingsRecord record)
    {
        static bool Bad(SynologyPhotoWriteStatus? value) => value is { } status && !Enum.IsDefined(status);
        if (record.Maintenance is { } maintenance)
        {
            var change = maintenance.Change; var original = change?.Original;
            if (original is null || original.ProfileId != record.ProfileId || !original.CanStart(change!.Action) || Bad(maintenance.Receipt) ||
                record.Submitted != (maintenance.Receipt is not null) || record.CompletedSteps is < 0 or > 1) throw Invalid();
            if (maintenance.Result is { } current && (current.ProfileId != original.ProfileId || current.UserId != original.UserId || current.Space != original.Space || current.IndexingCount < 0 || current.PreviewCount < 0)) throw Invalid();
            if (record.State == SynologyPhotoChangeState.Completed && (maintenance.Receipt != SynologyPhotoWriteStatus.Accepted || maintenance.Result?.PendingCount(change!.Action) != 0 || record.CompletedSteps != 1)) throw Invalid();
        }
        if (record.Codec is { } codec)
        {
            var response = codec.Response; var original = response?.Original;
            if (original is null || original.ProfileId != record.ProfileId || original.UserId <= 0 || !original.ShouldShow || response!.Generate && !original.CanGenerate ||
                Bad(codec.GenerationReceipt) || Bad(codec.PromptReceipt) || !response.Generate && codec.GenerationReceipt is not null ||
                response.Generate && codec.PromptReceipt is not null && codec.GenerationReceipt != SynologyPhotoWriteStatus.Accepted ||
                record.Submitted != (codec.GenerationReceipt is not null || codec.PromptReceipt is not null) ||
                record.CompletedSteps < 0 || record.CompletedSteps > (response.Generate ? 2 : 1) ||
                record.CompletedSteps > 0 && response.Generate && codec.GenerationReceipt != SynologyPhotoWriteStatus.Accepted ||
                record.State == SynologyPhotoChangeState.Completed && (!codec.PromptClosed || codec.PromptReceipt is null || codec.PromptReceipt == SynologyPhotoWriteStatus.Rejected || record.CompletedSteps != (response.Generate ? 2 : 1))) throw Invalid();
        }
    }
    private async Task ValidateMaintenanceAsync(PhotoSettingsRecord record, CancellationToken token)
    {
        if (record.Maintenance is { Change: var change })
        {
            if (change.Original.UserId != _currentUserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
            if (change.Original.Space == SynologyPhotoSpace.Shared && MembersBusy()) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            var current = await LibraryMaintenanceAsync(change.Original.Space, token).ConfigureAwait(false);
            if (!current.CanStart(change.Action)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            _ = Capability("Index", 1, change.Original.Space);
        }
        if (record.Codec is { Response: var response })
        {
            var current = await CodecPromptAsync(token).ConfigureAwait(false);
            if (current != response.Original || response.Generate && !current.CanGenerate) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            _ = Capability("Setting.Wizard", 1, null); if (response.Generate) _ = Capability("Index", 1, null);
        }
    }
}
