using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task<SynologyPhotoSettingsChange> ExecuteMaintenanceAsync(PhotoSettingsTask task, CancellationToken token)
    {
        await task.Gate.WaitAsync(CancellationToken.None).ConfigureAwait(false); task.Running = true;
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var owns = false; var sent = false;
        PhotoSettingsRecord? beforeAttempt = null;
        try
        {
            await owner.WaitAsync(token).ConfigureAwait(false); owns = true; var generation = Volatile.Read(ref _accessGeneration);
            await ValidateSettingsAsync(task.Record, token).ConfigureAwait(false);
            if (task.Record.Maintenance is { } maintenance)
            {
                beforeAttempt = task.Record;
                await SaveSettingsAsync(task, task.Record with { Submitted = true, State = SynologyPhotoChangeState.Submitting,
                    Maintenance = maintenance with { Receipt = SynologyPhotoWriteStatus.Unknown } }).ConfigureAwait(false);
                await ValidateSettingsAsync(task.Record, token).ConfigureAwait(false); RequireGeneration(generation, token); sent = true;
                var receipt = await _api.WritePhotoAsync(_profile, _session, Capability("Index", 1, maintenance.Change.Original.Space), 1, "reindex",
                    Parameters(("type", maintenance.Change.Action == SynologyPhotoMaintenanceAction.Reindex ? "basic" : "thumbnail")), token).ConfigureAwait(false);
                await SaveSettingsAsync(task, task.Record with { Maintenance = maintenance with { Receipt = receipt.Status },
                    State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview, Failure = receipt.Failure }).ConfigureAwait(false);
            }
            else if (task.Record.Codec is { } codec)
            {
                if (codec.Response.Generate)
                {
                    beforeAttempt = task.Record;
                    await SaveSettingsAsync(task, task.Record with { Submitted = true, State = SynologyPhotoChangeState.Submitting,
                        Codec = codec with { GenerationReceipt = SynologyPhotoWriteStatus.Unknown } }).ConfigureAwait(false);
                    await ValidateSettingsAsync(task.Record, token).ConfigureAwait(false); RequireGeneration(generation, token); sent = true;
                    var receipt = await _api.WritePhotoAsync(_profile, _session, Capability("Index", 1, null), 1,
                        codec.Response.Original.IsAdministrator ? "reindex_all_user" : "reindex", Parameters(("type", "thumbnail")), token).ConfigureAwait(false);
                    codec = codec with { GenerationReceipt = receipt.Status };
                    await SaveSettingsAsync(task, task.Record with { Codec = codec, CompletedSteps = receipt.Status == SynologyPhotoWriteStatus.Accepted ? 1 : 0,
                        State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview, Failure = receipt.Failure }).ConfigureAwait(false);
                }
                if (!codec.Response.Generate || codec.GenerationReceipt == SynologyPhotoWriteStatus.Accepted)
                {
                    beforeAttempt = task.Record; sent = false;
                    await ValidateCodecPromptStepAsync(codec.Response.Original, token).ConfigureAwait(false); RequireGeneration(generation, token); CheckSettingsOwner(task.Record);
                    await SaveSettingsAsync(task, task.Record with { Submitted = true, State = SynologyPhotoChangeState.Submitting,
                        Codec = codec with { PromptReceipt = SynologyPhotoWriteStatus.Unknown } }).ConfigureAwait(false);
                    await ValidateCodecPromptStepAsync(codec.Response.Original, token).ConfigureAwait(false); RequireGeneration(generation, token); CheckSettingsOwner(task.Record); sent = true;
                    var promptReceipt = await _api.WritePhotoAsync(_profile, _session, Capability("Setting.Wizard", 1, null), 1, "set",
                        Parameters(("prompt", new[] { new { name = "new_codec_installed", show = false } })), token).ConfigureAwait(false);
                    await SaveSettingsAsync(task, task.Record with { Codec = codec with { PromptReceipt = promptReceipt.Status },
                        State = promptReceipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview, Failure = promptReceipt.Failure }).ConfigureAwait(false);
                }
            }
            RequireGeneration(generation, token); CheckSettingsOwner(task.Record); await ReviewMaintenanceAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (PreviewError(error))
        {
            RequireManagementStore();
            if (task.Record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Failed))
            {
                // 在网络调用之前取消或失去权限，撤回本步尝试；已接收的前一步仍保留。
                var basis = !sent && beforeAttempt is not null ? beforeAttempt : task.Record;
                await SaveSettingsAsync(task, basis with { State = sent ? SynologyPhotoChangeState.PendingReview :
                    basis.CompletedSteps > 0 || !token.IsCancellationRequested ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.Cancelled,
                    Failure = PreviewFailure(error) }).ConfigureAwait(false);
            }
        }
        finally { task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return SettingsSnapshot(task);
    }
    private async Task ValidateCodecPromptStepAsync(SynologyPhotoCodecPrompt original, CancellationToken token)
    {
        var current = await ReadCodecPromptAsync(token).ConfigureAwait(false);
        if (current != original with { GenerationAlreadySubmitted = false }) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
    }
    private async Task ReviewMaintenanceAsync(PhotoSettingsTask task, CancellationToken token)
    {
        if (!SettingsSnapshot(task).Pending) return;
        try
        {
            CheckSettingsOwner(task.Record); var generation = Volatile.Read(ref _accessGeneration);
            if (task.Record.Maintenance is { } maintenance)
            {
                var current = await LibraryMaintenanceAsync(maintenance.Change.Original.Space, token).ConfigureAwait(false);
                if (current.UserId != maintenance.Change.Original.UserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
                RequireGeneration(generation, token); CheckSettingsOwner(task.Record);
                // 没有任务编号；计数变化不能追认丢失的回执，也不代表所有识别阶段都已结束。
                var finished = maintenance.Receipt == SynologyPhotoWriteStatus.Accepted && current.PendingCount(maintenance.Change.Action) == 0;
                await SaveSettingsAsync(task, task.Record with { Maintenance = maintenance with { Result = current },
                    State = finished ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview,
                    CompletedSteps = finished ? 1 : 0, Failure = finished ? null : task.Record.Failure }).ConfigureAwait(false);
            }
            else if (task.Record.Codec is { } codec)
            {
                var current = await ReadCodecPromptAsync(token).ConfigureAwait(false);
                if (current.UserId != codec.Response.Original.UserId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
                RequireGeneration(generation, token); CheckSettingsOwner(task.Record);
                if (codec.GenerationReceipt == SynologyPhotoWriteStatus.Accepted && codec.PromptReceipt is null)
                {
                    await SaveSettingsAsync(task, task.Record with { Codec = codec with { PromptClosed = !current.ShouldShow },
                        State = SynologyPhotoChangeState.Failed, CompletedSteps = 1 }).ConfigureAwait(false);
                    return;
                }
                if (!current.ShouldShow && codec.PromptReceipt is SynologyPhotoWriteStatus.Accepted or SynologyPhotoWriteStatus.Unknown &&
                    (!codec.Response.Generate || codec.GenerationReceipt == SynologyPhotoWriteStatus.Accepted))
                    await SaveSettingsAsync(task, task.Record with { Codec = codec with { PromptClosed = true }, State = SynologyPhotoChangeState.Completed,
                        CompletedSteps = codec.Response.Generate ? 2 : 1, Failure = null }).ConfigureAwait(false);
            }
        }
        catch (Exception error) when (PreviewError(error)) { RequireManagementStore(); }
    }
}
