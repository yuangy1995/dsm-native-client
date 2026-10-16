using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record PhotoBackgroundFact(long Id, SynologyPhotoWriteStatus Status);
    private sealed record PhotoBackgroundRecord(SynologyPhotoBackgroundCommand Command, PhotoBackgroundFact[] Facts, long[] Completed);
    private static bool SameBackgroundCommand(PhotoBackgroundRecord? left, PhotoBackgroundRecord? right) =>
        left is null ? right is null : right is not null && left.Command.Action == right.Command.Action &&
            left.Command.Targets.Count == right.Command.Targets.Count && left.Command.Targets.Zip(right.Command.Targets).All(pair => pair.First.SameIdentity(pair.Second));
    private bool BackgroundBusy(PhotoSettingsRecord record) => record.Background is { } background && _changes.Settings.Values.Any(task =>
        task.Record.Id != record.Id && task.Record.Owner == record.Owner && ActiveSettings(task.Record) && task.Record.Background is { } other &&
        other.Command.Targets.Any(target => background.Command.Targets.Any(value => value.Id == target.Id)));
    private static void ValidateBackgroundRecord(PhotoSettingsRecord record)
    {
        if (record.Background is not { } background) return;
        var command = background.Command;
        if (command is null || !Enum.IsDefined(command.Action) || command.Targets is not { Count: > 0 } ||
            command.Action == SynologyPhotoBackgroundAction.Stop && command.Targets.Count != 1 || background.Facts is null || background.Completed is null) throw Invalid();
        foreach (var target in command.Targets)
        {
            ValidateBackgroundTask(target);
            if (target.ProfileId != record.ProfileId || target.UserId != command.Targets[0].UserId ||
                !(command.Action == SynologyPhotoBackgroundAction.Stop ? target.CanStop : target.CanClear)) throw Invalid();
        }
        var ids = command.Targets.Select(target => target.Id).ToArray();
        if (ids.Distinct().Count() != ids.Length || background.Facts.Length > ids.Length ||
            background.Facts.Where((fact, index) => fact.Id != ids[index] || !Enum.IsDefined(fact.Status) || index < background.Facts.Length - 1 && fact.Status != SynologyPhotoWriteStatus.Accepted).Any() ||
            background.Completed.Distinct().Count() != background.Completed.Length ||
            background.Completed.Any(id => !background.Facts.Any(fact => fact.Id == id && fact.Status != SynologyPhotoWriteStatus.Rejected)) ||
            record.Submitted != (background.Facts.Length > 0) || record.CompletedSteps != background.Completed.Length ||
            record.State == SynologyPhotoChangeState.Completed && background.Completed.Length != ids.Length) throw Invalid();
    }
    public Task<SynologyPhotoSettingsChange> ControlBackgroundTasksAsync(Guid operationId, SynologyPhotoBackgroundCommand command,
        bool confirmed = false, CancellationToken cancellationToken = default)
    {
        if (!confirmed) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        if (command?.Targets is null) throw Invalid();
        return SetPreferenceAsync(new(operationId, ProfileId, UploadOwner(), null,
            Background: new(command with { Targets = command.Targets.OrderBy(target => target.Id).ToArray() }, [], [])), cancellationToken);
    }
    public async Task<IReadOnlyList<SynologyPhotoSettingsChange>> BackgroundChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Settings.Values.Where(task => task.Record.Owner == owner && task.Record.Background is not null).Select(SettingsSnapshot).ToArray();
    }
    private async Task PreserveOriginalFileResultAsync(SynologyPhotoBackgroundTask original, CancellationToken token)
    {
        foreach (var task in _changes.Files.Values.Where(task => task.Record.Owner == UploadOwner() && task.Record.TaskId == original.Id &&
            task.Record.State is SynologyPhotoFileState.Submitting or SynologyPhotoFileState.PendingReview))
        {
            // 只读保存原复制/移动结果；停止控制不接管原任务，清理不能先删除其唯一终态依据。
            await ReviewFileChangeAsync(task.Record.Id, token).ConfigureAwait(false);
            if (task.Record.State is SynologyPhotoFileState.Submitting or SynologyPhotoFileState.PendingReview)
                throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        }
    }
    private async Task ValidateBackgroundTargetAsync(PhotoSettingsRecord record, SynologyPhotoBackgroundTask original, CancellationToken token)
    {
        CheckSettingsOwner(record);
        if (BackgroundBusy(record)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (record.Background!.Command.Action == SynologyPhotoBackgroundAction.Clear) await PreserveOriginalFileResultAsync(original, token).ConfigureAwait(false);
        var current = await CurrentBackgroundTaskAsync(original, token).ConfigureAwait(false);
        if (!(record.Background.Command.Action == SynologyPhotoBackgroundAction.Stop ? current.CanStop : current.CanClear))
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        CheckSettingsOwner(record);
    }
    private async Task ValidateBackgroundAsync(PhotoSettingsRecord record, CancellationToken token)
    {
        foreach (var target in record.Background!.Command.Targets) await ValidateBackgroundTargetAsync(record, target, token).ConfigureAwait(false);
    }
    private async Task<SynologyPhotoSettingsChange> ExecuteBackgroundAsync(PhotoSettingsTask task, CancellationToken token)
    {
        await task.Gate.WaitAsync(CancellationToken.None).ConfigureAwait(false); task.Running = true;
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var owns = false; long? checkpoint = null; var sent = false;
        try
        {
            await owner.WaitAsync(token).ConfigureAwait(false); owns = true; var generation = Volatile.Read(ref _accessGeneration);
            var command = task.Record.Background!.Command;
            foreach (var target in command.Targets)
            {
                checkpoint = null; sent = false;
                await ValidateBackgroundTargetAsync(task.Record, target, token).ConfigureAwait(false);
                var background = task.Record.Background!;
                await SaveSettingsAsync(task, task.Record with { State = SynologyPhotoChangeState.Submitting, Submitted = true,
                    Background = background with { Facts = [.. background.Facts, new(target.Id, SynologyPhotoWriteStatus.Unknown)] } }).ConfigureAwait(false);
                checkpoint = target.Id;
                await ValidateBackgroundTargetAsync(task.Record, target, token).ConfigureAwait(false);
                RequireGeneration(generation, token); CheckSettingsOwner(task.Record); sent = true;
                var receipt = await _api.WritePhotoAsync(_profile, _session, Capability("BackgroundTask.Info", 1, null), 1,
                    command.Action == SynologyPhotoBackgroundAction.Stop ? "abort_task" : "clear_completed_task",
                    command.Action == SynologyPhotoBackgroundAction.Stop ? Parameters(("id", new[] { target.Id })) : Parameters(("id", target.Id)), token).ConfigureAwait(false);
                background = task.Record.Background!;
                await SaveSettingsAsync(task, task.Record with { State = SynologyPhotoChangeState.PendingReview, Failure = receipt.Failure,
                    Background = background with { Facts = background.Facts.Select(fact => fact.Id == target.Id ? fact with { Status = receipt.Status } : fact).ToArray() } }).ConfigureAwait(false);
                RequireGeneration(generation, token); CheckSettingsOwner(task.Record);
                if (receipt.Status != SynologyPhotoWriteStatus.Accepted) break;
            }
            await ReviewBackgroundAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (PreviewError(error))
        {
            RequireManagementStore(); var background = task.Record.Background!;
            if (checkpoint is { } id && !sent) background = background with { Facts = background.Facts.Where(fact => fact.Id != id).ToArray() };
            await SaveSettingsAsync(task, task.Record with { Background = background, Submitted = background.Facts.Length > 0,
                State = background.Facts.Length > 0 ? SynologyPhotoChangeState.PendingReview : token.IsCancellationRequested ? SynologyPhotoChangeState.Cancelled : SynologyPhotoChangeState.Failed,
                Failure = PreviewFailure(error) }).ConfigureAwait(false);
            if (!token.IsCancellationRequested) await ReviewBackgroundAsync(task, token).ConfigureAwait(false);
        }
        finally { task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return SettingsSnapshot(task);
    }
    private async Task ReviewBackgroundAsync(PhotoSettingsTask task, CancellationToken token)
    {
        if (task.Record.State is not (SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview)) return;
        try
        {
            CheckSettingsOwner(task.Record); var generation = Volatile.Read(ref _accessGeneration);
            if (task.Record.Background is { Facts: var facts, Completed: var known } && facts.All(fact => fact.Status == SynologyPhotoWriteStatus.Rejected || known.Contains(fact.Id)))
            {
                await SaveSettingsAsync(task, task.Record with { State = known.Length == task.Record.Background.Command.Targets.Count ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Failed }).ConfigureAwait(false);
                return;
            }
            var current = await BackgroundTasksAsync(token).ConfigureAwait(false); var background = task.Record.Background!;
            var completed = background.Completed.ToHashSet();
            foreach (var fact in background.Facts.Where(fact => fact.Status != SynologyPhotoWriteStatus.Rejected && !completed.Contains(fact.Id)))
            {
                var original = background.Command.Targets.Single(value => value.Id == fact.Id); var target = current.SingleOrDefault(value => value.Id == fact.Id);
                if (target is null || background.Command.Action == SynologyPhotoBackgroundAction.Stop && target.SameIdentity(original) && target.Status == SynologyPhotoBackgroundStatus.Done)
                    completed.Add(fact.Id);
            }
            RequireGeneration(generation, token); CheckSettingsOwner(task.Record);
            var pending = background.Facts.Any(fact => fact.Status != SynologyPhotoWriteStatus.Rejected && !completed.Contains(fact.Id));
            await SaveSettingsAsync(task, task.Record with { Background = background with { Completed = completed.Order().ToArray() }, CompletedSteps = completed.Count,
                State = pending ? SynologyPhotoChangeState.PendingReview : completed.Count == background.Command.Targets.Count ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Failed,
                Failure = pending || completed.Count != background.Command.Targets.Count ? task.Record.Failure : null }).ConfigureAwait(false);
        }
        catch (Exception error) when (PreviewError(error)) { RequireManagementStore(); }
    }
}
