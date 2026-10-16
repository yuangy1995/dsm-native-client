using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static bool SimilarResultMatches(SynologyPhotoRecognitionKind kind, SimilarStep step, SynologyPhotoSimilarGroup? current)
    {
        if (kind == SynologyPhotoRecognitionKind.SimilarUngroup) return current is null;
        if (kind == SynologyPhotoRecognitionKind.SimilarUndo) return step.Group.Matches(current);
        if (kind == SynologyPhotoRecognitionKind.SimilarTopPick)
            return current is not null && current.Id == step.Group.Id && current.TopPickId == step.Selected[0] && current.PhotoIds.ToHashSet().SetEquals(step.Group.PhotoIds);
        var remaining = step.Group.PhotoIds.Except(step.Selected).ToArray();
        return remaining.Length < 2 ? current is null : current is not null && current.Id == step.Group.Id && current.PhotoIds.ToHashSet().SetEquals(remaining);
    }
    private async Task<(bool Matches, SynologyPhotoSimilarGroup? Group, SynologyPhoto[] Photos)> InspectSimilarAsync(PhotoRecognitionRecord record, SimilarStep step, CancellationToken token)
    {
        var group = await CurrentSimilarAsync(step.Group.Id, record.Space, token).ConfigureAwait(false);
        var photos = await SimilarOriginalsAsync(step.Group, true, token).ConfigureAwait(false);
        if (photos.Any(photo => !record.Photos.Any(original => original.Id == photo.Id.ItemId && original.IdentityHash == RecognitionPhotoHash(photo))))
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var matches = SimilarResultMatches(record.Kind, step, group) && photos.All(photo =>
            group?.PhotoIds.Contains(photo.Id.ItemId) == true ? group.Matches(photo.SimilarGroup) : photo.SimilarGroup?.Id != step.Group.Id);
        return (matches, group, photos);
    }
    private async Task PrepareSimilarStepAsync(PhotoRecognitionRecord record, SimilarStep step, CancellationToken token, bool requireWriteSafety = true)
    {
        CheckRecognitionOwner(record); var generation = Volatile.Read(ref _accessGeneration);
        if (requireWriteSafety && !RecognitionSafety.SimilarGroups) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        await FreshSimilarAccessAsync(record.Space, token).ConfigureAwait(false);
        if (_changes.Recognition.Values.Any(task => task.Record.Id != record.Id && task.Record.Owner == record.Owner && task.Record.Space == record.Space &&
            ActiveRecognition(task.Record) && task.Record.Similar?.Any(other => other.Group.Id == step.Group.Id) == true)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        var photos = await SimilarOriginalsAsync(step.Group, false, token).ConfigureAwait(false);
        foreach (var photo in photos)
        {
            if (!record.Photos.Any(original => original.Id == photo.Id.ItemId && original.IdentityHash == RecognitionPhotoHash(photo))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            await CheckRecognitionPhotoLocksAsync(record, photo, token).ConfigureAwait(false);
        }
        if (record.Kind == SynologyPhotoRecognitionKind.SimilarUndo)
        {
            if (record.UndoOperationId is not { } undo || !_changes.Recognition.TryGetValue(undo, out var previous)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            CheckRecognitionOwner(previous.Record);
            if (previous.Record.Kind is not (SynologyPhotoRecognitionKind.SimilarRemove or SynologyPhotoRecognitionKind.SimilarUngroup) ||
                previous.Record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled) ||
                _changes.Recognition.Values.Any(task => task.Record.Id != record.Id && task.Record.Owner == record.Owner && task.Record.UndoOperationId == undo))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var completed = previous.Record.Similar!.Reverse().Where(value => value.State == SynologyPhotoChangeState.Completed).ToArray();
            if (!record.Similar!.Select(value => value.Group.Id).SequenceEqual(completed.Select(value => value.Group.Id)) ||
                !record.Photos.ToHashSet().SetEquals(previous.Record.Photos.Where(photo => completed.Any(value => value.Group.PhotoIds.Contains(photo.Id)))))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var original = completed.Single(value => value.Group.Id == step.Group.Id);
            if (!original.Group.Matches(step.Group)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var checkedResult = await InspectSimilarAsync(previous.Record, original, token).ConfigureAwait(false);
            if (!checkedResult.Matches || !SameSimilarGroup(original.Result, checkedResult.Group) || checkedResult.Photos.Any(photo => photo.SimilarGroup is { } group && group.Id != step.Group.Id))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        else
        {
            if (!step.Group.Matches(await CurrentSimilarAsync(step.Group.Id, record.Space, token).ConfigureAwait(false))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var memberships = await SimilarOriginalsAsync(step.Group, true, token).ConfigureAwait(false);
            if (memberships.Any(photo => !step.Group.Matches(photo.SimilarGroup) || !record.Photos.Any(original => original.Id == photo.Id.ItemId && original.IdentityHash == RecognitionPhotoHash(photo))))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        RequireGeneration(generation, token); CheckRecognitionOwner(record);
    }
    private async Task ReviewSimilarAsync(PhotoRecognitionTask task, CancellationToken token)
    {
        if (!SimilarPending(task.Record)) return;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); await FreshSimilarAccessAsync(task.Record.Space, token).ConfigureAwait(false);
            for (var index = 0; index < task.Record.Similar!.Length; index++)
            {
                var step = task.Record.Similar[index];
                if (step.State is not (SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview) || !step.Accepted) continue;
                var result = await InspectSimilarAsync(task.Record, step, token).ConfigureAwait(false);
                RequireGeneration(generation, token); CheckRecognitionOwner(task.Record);
                if (!result.Matches) continue;
                task.Record = WithSimilarStep(task.Record, index, step with { State = SynologyPhotoChangeState.Completed, Result = result.Group });
                await SaveRecognitionAsync(task).ConfigureAwait(false);
            }
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
    private async Task SendSimilarAsync(PhotoRecognitionTask task, CancellationToken token)
    {
        for (var index = 0; index < task.Record.Similar!.Length && !SimilarPending(task.Record); index++)
        {
            var step = task.Record.Similar[index]; if (step.State is not (SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)) continue;
            var sent = false; var original = task.Record; var generation = Volatile.Read(ref _accessGeneration);
            try
            {
                await PrepareSimilarStepAsync(original, step, token).ConfigureAwait(false);
                var fields = original.Kind switch
                {
                    SynologyPhotoRecognitionKind.SimilarTopPick => Parameters(("id", step.Group.Id), ("item_id", step.Selected[0])),
                    SynologyPhotoRecognitionKind.SimilarRemove => Parameters(("id", step.Group.Id), ("item_id", step.Selected)),
                    SynologyPhotoRecognitionKind.SimilarUngroup => Parameters(("id", new[] { step.Group.Id })),
                    SynologyPhotoRecognitionKind.SimilarUndo => Parameters(("id", step.Group.Id), ("item_id", step.Group.PhotoIds), ("top_pick", step.Group.TopPickId)),
                    _ => throw Invalid(),
                };
                var method = original.Kind switch { SynologyPhotoRecognitionKind.SimilarTopPick => "set_top_pick", SynologyPhotoRecognitionKind.SimilarRemove => "remove_item",
                    SynologyPhotoRecognitionKind.SimilarUngroup => "ungroup", SynologyPhotoRecognitionKind.SimilarUndo => "add_item", _ => throw Invalid() };
                task.Record = WithSimilarStep(original, index, step with { State = SynologyPhotoChangeState.Submitting });
                await SaveRecognitionAsync(task).ConfigureAwait(false);
                await PrepareSimilarStepAsync(original, step, token).ConfigureAwait(false); RequireGeneration(generation, token); CheckRecognitionOwner(original);
                sent = true;
                var receipt = await _api.WritePhotoAsync(_profile, _session, Capability("Browse.Similar", 1, original.Space), 1, method, fields, token).ConfigureAwait(false);
                task.Record = WithSimilarStep(task.Record, index, step with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                    Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted }) with { Failure = receipt.Failure };
                await SaveRecognitionAsync(task).ConfigureAwait(false); RequireGeneration(generation, token); CheckRecognitionOwner(original);
                if (receipt.Status != SynologyPhotoWriteStatus.Accepted) return;
                await ReviewSimilarAsync(task, token).ConfigureAwait(false);
            }
            catch (Exception error) when (ManagementError(error))
            {
                RequireManagementStore();
                if (!sent) task.Record = WithSimilarStep(original, index, step with { State = SynologyPhotoChangeState.Failed });
                task.Record = SimilarAggregate(task.Record) with { Failure = UploadFailure(error) }; await SaveRecognitionAsync(task).ConfigureAwait(false); return;
            }
        }
    }
}
