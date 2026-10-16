using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record SimilarStep(Guid OperationId, SynologyPhotoSimilarGroup Group, long[] Selected,
        SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready, bool Accepted = false, SynologyPhotoSimilarGroup? Result = null);
    private static bool SimilarKind(SynologyPhotoRecognitionKind kind) => kind is SynologyPhotoRecognitionKind.SimilarTopPick or
        SynologyPhotoRecognitionKind.SimilarRemove or SynologyPhotoRecognitionKind.SimilarUngroup or SynologyPhotoRecognitionKind.SimilarUndo;
    private static bool ValidSimilarGroup(SynologyPhotoSimilarGroup group, SynologyPhotoSpace space) => group.Id > 0 && group.Space == space &&
        group.PhotoIds is { Count: >= 2 } && group.PhotoIds.All(id => id > 0) && group.PhotoIds.Distinct().Count() == group.Count && group.PhotoIds.Contains(group.TopPickId);
    private static string SimilarFingerprint(SynologyPhotoRecognitionKind kind, SynologyPhotoSpace space, SimilarStep[] steps, RecognitionPhoto[] photos, Guid? undo) =>
        PhotoTextHash(JsonSerializer.Serialize(new { Kind = kind, Space = space, Steps = steps.Select(step => new { step.Group, step.Selected }), Photos = photos, Undo = undo }));
    private PhotoRecognitionRecord SimilarRecognitionRecord(Guid id, SynologyPhotoRecognitionEdit edit)
    {
        if (id == Guid.Empty || !Enum.IsDefined(edit.Space) || edit.People.Count != 0 || edit.Name is not null || edit.Visible || edit.Faces.Count != 0 || edit.CoverPhoto is not null ||
            edit.ManualPhoto is not null || edit.OriginalRegions.Count != 0 || edit.FaceChanges.Count != 0 || edit.Concepts.Count != 0 || edit.ConceptPhotos.Count != 0 ||
            edit.SimilarGroups is not { Count: > 0 and <= 100 } || edit.SimilarGroups.Any(detail => !ValidSimilarGroup(detail.Group, edit.Space)) ||
            edit.SimilarGroups.DistinctBy(detail => detail.Group.Id).Count() != edit.SimilarGroups.Count ||
            edit.Kind is SynologyPhotoRecognitionKind.SimilarTopPick or SynologyPhotoRecognitionKind.SimilarRemove && edit.SimilarGroups.Count != 1 ||
            (edit.Kind == SynologyPhotoRecognitionKind.SimilarUndo) != (edit.UndoOperationId is not null) || edit.UndoOperationId == Guid.Empty) throw Invalid();
        var photos = new List<RecognitionPhoto>(); var steps = new List<SimilarStep>();
        foreach (var detail in edit.SimilarGroups)
        {
            if (detail.Photos.Count != detail.Group.Count || !detail.Photos.Select(photo => photo.Id.ItemId).ToHashSet().SetEquals(detail.Group.PhotoIds)) throw Invalid();
            foreach (var photo in detail.Photos)
            {
                RequirePhoto(photo);
                if (photo.Id.Space != edit.Space || photo.AlbumContext is not null) throw Invalid();
                photos.Add(new(photo.Id.ItemId, photo.FolderId, RecognitionPhotoHash(photo)));
            }
            steps.Add(new(Guid.NewGuid(), detail.Group with { PhotoIds = detail.Group.PhotoIds.ToArray() }, edit.SimilarSelection.ToArray()));
        }
        if (photos.DistinctBy(photo => photo.Id).Count() != photos.Count) throw Invalid();
        var originals = photos.OrderBy(photo => photo.Id).ToArray(); var values = steps.ToArray();
        var record = new PhotoRecognitionRecord(id, ProfileId, UploadOwner(), SimilarFingerprint(edit.Kind, edit.Space, values, originals, edit.UndoOperationId),
            edit.Kind, edit.Space, [], null, false, originals, Similar: values, UndoOperationId: edit.UndoOperationId);
        return RestoreSimilarRecognition(id, record);
    }
    private static PhotoRecognitionRecord RestoreSimilarRecognition(Guid id, PhotoRecognitionRecord record)
    {
        if (id == Guid.Empty || id != record.Id || record.ProfileId == Guid.Empty || !UploadHash(record.Owner) || !UploadHash(record.Fingerprint) ||
            !Enum.IsDefined(record.Space) || !Enum.IsDefined(record.State) || record.Failure is { } failure && !Enum.IsDefined(failure) ||
            record.People is not { Length: 0 } || record.NameHash is not null || record.Visible || record.Manual is not null || record.Concepts is not null ||
            (record.Faces ?? []).Length != 0 || record.PersonReceipt is not null || record.CoverReceipt is not null || (record.RemovedIds ?? []).Length != 0 || (record.RemovedPhotoIds ?? []).Length != 0 ||
            record.Similar is not { Length: > 0 and <= 100 } || record.Similar.Any(step => step.OperationId == Guid.Empty || !ValidSimilarGroup(step.Group, record.Space) || !Enum.IsDefined(step.State)) ||
            record.Similar.DistinctBy(step => step.OperationId).Count() != record.Similar.Length || record.Similar.DistinctBy(step => step.Group.Id).Count() != record.Similar.Length ||
            (record.Kind == SynologyPhotoRecognitionKind.SimilarUndo) != (record.UndoOperationId is not null) || record.UndoOperationId == Guid.Empty || record.UndoOperationId == id ||
            record.Kind is SynologyPhotoRecognitionKind.SimilarTopPick or SynologyPhotoRecognitionKind.SimilarRemove && record.Similar.Length != 1 ||
            record.Photos is null || record.Photos.Any(photo => photo.Id <= 0 || photo.FolderId <= 0 || !UploadHash(photo.IdentityHash) || photo.Album is not null) ||
            record.Photos.DistinctBy(photo => photo.Id).Count() != record.Photos.Length) throw Invalid();
        var ids = record.Similar.SelectMany(step => step.Group.PhotoIds).ToArray();
        if (ids.Distinct().Count() != ids.Length || !record.Photos.Select(photo => photo.Id).ToHashSet().SetEquals(ids)) throw Invalid();
        foreach (var step in record.Similar)
        {
            if (step.Selected is null || step.Selected.Distinct().Count() != step.Selected.Length || step.Selected.Any(value => !step.Group.PhotoIds.Contains(value)) ||
                record.Kind == SynologyPhotoRecognitionKind.SimilarTopPick && (step.Selected.Length != 1 || step.Selected[0] == step.Group.TopPickId) ||
                record.Kind == SynologyPhotoRecognitionKind.SimilarRemove && step.Selected.Length == 0 ||
                record.Kind is SynologyPhotoRecognitionKind.SimilarUngroup or SynologyPhotoRecognitionKind.SimilarUndo && step.Selected.Length != 0 ||
                step.Accepted && step.State is not (SynologyPhotoChangeState.PendingReview or SynologyPhotoChangeState.Completed) ||
                step.State == SynologyPhotoChangeState.Completed && !step.Accepted ||
                step.Result is not null && (step.State != SynologyPhotoChangeState.Completed || !ValidSimilarGroup(step.Result, record.Space) || step.Result.Id != step.Group.Id) ||
                step.State == SynologyPhotoChangeState.Completed && !SimilarResultMatches(record.Kind, step, step.Result)) throw Invalid();
        }
        if (record.Fingerprint != SimilarFingerprint(record.Kind, record.Space, record.Similar, record.Photos, record.UndoOperationId) ||
            !(record.CompletedIds ?? []).ToHashSet().SetEquals(record.Similar.Where(step => step.State == SynologyPhotoChangeState.Completed).Select(step => step.Group.Id)) ||
            (record.CompletedIds ?? []).Distinct().Count() != (record.CompletedIds ?? []).Length || record.Accepted != record.Similar.Any(step => step.Accepted)) throw Invalid();
        var restored = record with { Similar = record.Similar.Select(step => step.State == SynologyPhotoChangeState.Submitting ? step with { State = SynologyPhotoChangeState.PendingReview } : step).ToArray() };
        var result = SimilarAggregate(restored);
        if ((record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview : record.State) != result.State) throw Invalid();
        return result;
    }
    private static bool SimilarPending(PhotoRecognitionRecord record) => record.Similar!.Any(step => step.State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview);
    private static bool SimilarCanContinue(PhotoRecognitionRecord record) => !SimilarPending(record) && record.Similar!.Any(step => step.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed);
    private bool SimilarCanUndo(PhotoRecognitionRecord record) => record.Similar is not null && record.Kind is SynologyPhotoRecognitionKind.SimilarRemove or SynologyPhotoRecognitionKind.SimilarUngroup &&
        record.State is SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled && record.Similar.Any(step => step.State == SynologyPhotoChangeState.Completed) &&
        !_changes.Recognition.Values.Any(task => task.Record.Owner == record.Owner && task.Record.UndoOperationId == record.Id);
    private static PhotoRecognitionRecord SimilarAggregate(PhotoRecognitionRecord record)
    {
        var steps = record.Similar!; var completed = steps.Where(step => step.State == SynologyPhotoChangeState.Completed).Select(step => step.Group.Id).ToArray();
        var state = SimilarPending(record) ? SynologyPhotoChangeState.PendingReview : steps.Any(step => step.State == SynologyPhotoChangeState.Failed) ? SynologyPhotoChangeState.Failed :
            steps.Any(step => step.State == SynologyPhotoChangeState.Ready) ? SynologyPhotoChangeState.Ready : steps.All(step => step.State == SynologyPhotoChangeState.Completed) ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Cancelled;
        return record with { State = state, CompletedIds = completed, Accepted = steps.Any(step => step.Accepted), Failure = state == SynologyPhotoChangeState.Completed ? null : record.Failure };
    }
    private static PhotoRecognitionRecord WithSimilarStep(PhotoRecognitionRecord record, int index, SimilarStep step)
    { var steps = record.Similar!.ToArray(); steps[index] = step; return SimilarAggregate(record with { Similar = steps }); }
    private async Task CancelSimilarAsync(PhotoRecognitionTask task)
    {
        task.Record = SimilarAggregate(task.Record with { Similar = task.Record.Similar!.Select(step => step.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed
            ? step with { State = SynologyPhotoChangeState.Cancelled } : step).ToArray() });
        await SaveRecognitionAsync(task).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoRecognitionEdit> SimilarUndoAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var original = OwnedRecognition(operationId).Record;
        if (!SimilarCanUndo(original)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var generation = Volatile.Read(ref _accessGeneration); var details = new List<SynologyPhotoSimilarDetail>();
        await FreshSimilarAccessAsync(original.Space, cancellationToken).ConfigureAwait(false);
        foreach (var step in original.Similar!.Reverse().Where(step => step.State == SynologyPhotoChangeState.Completed))
        {
            var current = await InspectSimilarAsync(original, step, cancellationToken).ConfigureAwait(false);
            if (!current.Matches || !SameSimilarGroup(step.Result, current.Group) || current.Photos.Any(photo => photo.SimilarGroup is { } group && group.Id != step.Group.Id))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            details.Add(new(step.Group, current.Photos));
        }
        RequireGeneration(generation, cancellationToken); CheckRecognitionOwner(original);
        return new(SynologyPhotoRecognitionKind.SimilarUndo, []) { Space = original.Space, SimilarGroups = details, UndoOperationId = original.Id };
    }
    private static bool SameSimilarGroup(SynologyPhotoSimilarGroup? first, SynologyPhotoSimilarGroup? second) => first is null ? second is null : first.Matches(second);
}
