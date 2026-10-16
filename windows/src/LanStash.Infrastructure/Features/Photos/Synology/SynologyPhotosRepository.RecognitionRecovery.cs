using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record RecognitionPerson(long Id, string NameHash, int? Count, bool? Visible);
    private sealed record RecognitionPhoto(long Id, long FolderId, string IdentityHash, SynologyPhotoAlbumContext? Album = null);
    private sealed record RecognitionFace(long Id, long PhotoId);
    private sealed record PhotoRecognitionRecord(Guid Id, Guid ProfileId, string Owner, string Fingerprint,
        SynologyPhotoRecognitionKind Kind, SynologyPhotoSpace Space, RecognitionPerson[] People, string? NameHash, bool Visible,
        RecognitionPhoto[] Photos, SynologyPhotoChangeState State = SynologyPhotoChangeState.Ready, bool Accepted = false,
        long[]? CompletedIds = null, long[]? RemovedIds = null, SynologyPhotoFailure? Failure = null,
        RecognitionFace[]? Faces = null, long? CoverReceipt = null, long? PersonReceipt = null, long[]? RemovedPhotoIds = null,
        ManualFaceRecord? Manual = null, RecognitionConcept[]? Concepts = null, SimilarStep[]? Similar = null, Guid? UndoOperationId = null);
    private sealed class PhotoRecognitionTask(PhotoRecognitionRecord record)
    {
        internal volatile PhotoRecognitionRecord Record = record;
        internal readonly SemaphoreSlim Gate = new(1, 1);
        internal string? Name;
        internal SynologyPhotoFaceChange[]? ManualInput;
        internal IReadOnlyList<SynologyPhotoPerson> People = [];
        internal IReadOnlyList<SynologyPhotoConcept> Concepts = [];
        internal volatile bool Running;
    }
    private PhotoRecognitionRecord RecognitionRecord(Guid id, SynologyPhotoRecognitionEdit edit)
    {
        if (SimilarKind(edit.Kind)) return SimilarRecognitionRecord(id, edit);
        if (edit.SimilarGroups.Count != 0 || edit.SimilarSelection.Count != 0 || edit.UndoOperationId is not null) throw Invalid();
        if (ConceptKind(edit.Kind)) return ConceptRecognitionRecord(id, edit);
        if (edit.Concepts.Count != 0 || edit.ConceptPhotos.Count != 0) throw Invalid();
        if (edit.Kind == SynologyPhotoRecognitionKind.ManualFaces) return ManualRecognitionRecord(id, edit);
        if (edit.ManualPhoto is not null || edit.FaceChanges.Count != 0 || edit.OriginalRegions.Count != 0) throw Invalid();
        if (id == Guid.Empty || !Enum.IsDefined(edit.Kind) || !Enum.IsDefined(edit.Space) || edit.People is not { Count: > 0 and <= 100 } ||
            edit.People.Any(person => person.Person.Id <= 0 || person.Person.Space != edit.Space || person.Person.Count < 0) ||
            edit.People.DistinctBy(person => person.Person.Id).Count() != edit.People.Count ||
            edit.Kind == SynologyPhotoRecognitionKind.RenamePerson && edit.People.Count != 1 ||
            edit.Kind == SynologyPhotoRecognitionKind.MergePeople && edit.People.Count < 2 ||
            RecognitionUsesName(edit.Kind) && edit.Name is null || !RecognitionUsesName(edit.Kind) && edit.Name is not null ||
            edit.Kind is SynologyPhotoRecognitionKind.RemovePersonFaces or SynologyPhotoRecognitionKind.SetPersonCover && edit.People.Count != 1 ||
            edit.Kind == SynologyPhotoRecognitionKind.ReassignPersonFaces && (edit.People.Count > 2 || edit.People.Count == 2 && edit.Name != edit.People[1].Person.Name) ||
            edit.Kind == SynologyPhotoRecognitionKind.ShowPeople && (edit.Name is not null || edit.People.Any(person => person.Visible is null || person.Visible == edit.Visible))) throw Invalid();
        if (RecognitionCorrectsFaces(edit.Kind) != (edit.Faces.Count > 0) || (edit.Kind == SynologyPhotoRecognitionKind.SetPersonCover) != (edit.CoverPhoto is not null) ||
            edit.Faces.Any(face => face.Id <= 0 || face.PersonId != edit.People[0].Person.Id) || edit.Faces.DistinctBy(face => face.Id).Count() != edit.Faces.Count) throw Invalid();
        var originals = edit.CoverPhoto is { } cover ? new[] { cover } : edit.Faces.Select(face => face.Photo).DistinctBy(photo => photo.Id).ToArray();
        if (originals.Length > 100 || edit.Faces.Any(face => !originals.Any(photo => photo.Id == face.Photo.Id && photo.IsSameDeletionTarget(face.Photo)))) throw Invalid();
        foreach (var photo in originals) { RequirePhoto(photo); if (photo.Id.Space != edit.Space || photo.AlbumContext is not null) throw Invalid(); }
        var photos = originals.Select(photo => new RecognitionPhoto(photo.Id.ItemId, photo.FolderId, RecognitionPhotoHash(photo))).OrderBy(photo => photo.Id).ToArray();
        var faces = edit.Faces.Select(face => new RecognitionFace(face.Id, face.Photo.Id.ItemId)).OrderBy(face => face.Id).ToArray();
        var people = edit.People.Select(person => new RecognitionPerson(person.Person.Id, PhotoTextHash(person.Person.Name), person.Person.Count, person.Visible)).ToArray();
        var name = edit.Name is null ? null : PhotoTextHash(edit.Name);
        var fingerprint = PhotoTextHash(JsonSerializer.Serialize(new { edit.Kind, edit.Space, People = people, Name = name, edit.Visible, Photos = photos, Faces = faces }));
        return new(id, ProfileId, UploadOwner(), fingerprint, edit.Kind, edit.Space, people, name, edit.Visible, photos, Faces: faces);
    }
    private static bool RecognitionCorrectsFaces(SynologyPhotoRecognitionKind kind) => kind is SynologyPhotoRecognitionKind.RemovePersonFaces or SynologyPhotoRecognitionKind.ReassignPersonFaces;
    private static bool RecognitionUsesPhotos(SynologyPhotoRecognitionKind kind) => RecognitionCorrectsFaces(kind) || kind is SynologyPhotoRecognitionKind.SetPersonCover or SynologyPhotoRecognitionKind.ManualFaces or SynologyPhotoRecognitionKind.SetConceptCover or SynologyPhotoRecognitionKind.RemoveConceptPhotos;
    private static bool RecognitionUsesName(SynologyPhotoRecognitionKind kind) => kind is SynologyPhotoRecognitionKind.RenamePerson or SynologyPhotoRecognitionKind.MergePeople or SynologyPhotoRecognitionKind.ReassignPersonFaces;
    private static long[] RecognitionCompletionIds(PhotoRecognitionRecord record) => SimilarKind(record.Kind) ? record.Similar!.Select(step => step.Group.Id).ToArray() : ConceptKind(record.Kind) ? record.Kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos
        ? record.Photos.Select(photo => photo.Id).ToArray() : (record.Concepts ?? []).Select(value => value.Id).ToArray() : RecognitionCorrectsFaces(record.Kind)
        ? (record.Faces ?? []).Select(face => face.Id).ToArray() : record.People.Select(person => person.Id).ToArray();
    private static IEnumerable<long> RecognitionPersonIds(PhotoRecognitionRecord record) => record.People.Select(person => person.Id).Concat(record.PersonReceipt is { } id ? [id] : [])
        .Concat(record.Manual?.Originals.Select(face => face.PersonId).Where(id => id > 0) ?? [])
        .Concat(record.Manual?.Changes.Select(change => change.PersonReceipt).OfType<long>() ?? []);
    private static PhotoRecognitionRecord RestoreRecognition(Guid id, PhotoRecognitionRecord record)
    {
        if (SimilarKind(record.Kind)) return RestoreSimilarRecognition(id, record);
        if (record.Similar is not null || record.UndoOperationId is not null) throw Invalid();
        if (ConceptKind(record.Kind)) return RestoreConceptRecognition(id, record);
        if (record.Concepts is not null) throw Invalid();
        if (record.Kind == SynologyPhotoRecognitionKind.ManualFaces) return RestoreManualRecognition(id, record);
        if (record.Manual is not null || record.Photos?.Any(photo => photo.Album is not null) == true) throw Invalid();
        if (id == Guid.Empty || id != record.Id || record.ProfileId == Guid.Empty || !UploadHash(record.Owner) || !UploadHash(record.Fingerprint) ||
            !Enum.IsDefined(record.Kind) || !Enum.IsDefined(record.Space) || !Enum.IsDefined(record.State) || record.Failure is { } failure && !Enum.IsDefined(failure) ||
            record.People is not { Length: > 0 and <= 100 } || record.People.Any(person => person.Id <= 0 || !UploadHash(person.NameHash) || person.Count < 0) ||
            record.People.DistinctBy(person => person.Id).Count() != record.People.Length ||
            record.Kind == SynologyPhotoRecognitionKind.RenamePerson && record.People.Length != 1 || record.Kind == SynologyPhotoRecognitionKind.MergePeople && record.People.Length < 2 ||
            RecognitionUsesName(record.Kind) && !UploadHash(record.NameHash) || !RecognitionUsesName(record.Kind) && record.NameHash is not null ||
            record.Kind is SynologyPhotoRecognitionKind.RemovePersonFaces or SynologyPhotoRecognitionKind.SetPersonCover && record.People.Length != 1 ||
            record.Kind == SynologyPhotoRecognitionKind.ReassignPersonFaces && (record.People.Length > 2 || record.People.Length == 2 && record.NameHash != record.People[1].NameHash) ||
            record.Kind == SynologyPhotoRecognitionKind.ShowPeople && (record.NameHash is not null || record.People.Any(person => person.Visible is null || person.Visible == record.Visible)) ||
            record.Photos is null || record.Photos.Any(photo => photo.Id <= 0 || photo.FolderId <= 0 || !UploadHash(photo.IdentityHash)) ||
            record.Photos.DistinctBy(photo => photo.Id).Count() != record.Photos.Length ||
            !RecognitionUsesPhotos(record.Kind) && record.Kind != SynologyPhotoRecognitionKind.MergePeople && record.Photos.Length != 0 ||
            RecognitionUsesPhotos(record.Kind) && record.Photos.Length is not (> 0 and <= 100) ||
            record.Kind == SynologyPhotoRecognitionKind.SetPersonCover && record.Photos.Length != 1 ||
            RecognitionCorrectsFaces(record.Kind) != ((record.Faces ?? []).Length > 0) ||
            (record.Faces ?? []).Any(face => face.Id <= 0 || !record.Photos.Any(photo => photo.Id == face.PhotoId)) ||
            (record.Faces ?? []).DistinctBy(face => face.Id).Count() != (record.Faces ?? []).Length ||
            RecognitionCorrectsFaces(record.Kind) && record.Photos.Any(photo => !(record.Faces ?? []).Any(face => face.PhotoId == photo.Id)) ||
            record.CoverReceipt is { } cover && (cover <= 0 || record.Kind != SynologyPhotoRecognitionKind.SetPersonCover || !record.Accepted) ||
            record.PersonReceipt is { } person && (person <= 0 || record.Kind != SynologyPhotoRecognitionKind.ReassignPersonFaces || person == record.People[0].Id || !record.Accepted || record.People.Length == 2 && person != record.People[1].Id) ||
            record.Accepted && record.Kind == SynologyPhotoRecognitionKind.SetPersonCover && record.CoverReceipt is null ||
            record.Accepted && record.Kind == SynologyPhotoRecognitionKind.ReassignPersonFaces && record.PersonReceipt is null ||
            (record.RemovedPhotoIds ?? []).Any(value => !record.Photos.Any(photo => photo.Id == value) || !RecognitionCorrectsFaces(record.Kind)) ||
            (record.CompletedIds ?? []).Any(value => !RecognitionCompletionIds(record).Contains(value)) ||
            (record.CompletedIds ?? []).Distinct().Count() != (record.CompletedIds ?? []).Length ||
            (record.CompletedIds ?? []).Length > 0 && !record.Accepted ||
            (record.RemovedIds ?? []).Any(value => !record.People.Any(person => person.Id == value)) ||
            record.State == SynologyPhotoChangeState.Completed && (!record.Accepted || (record.CompletedIds ?? []).Length != RecognitionCompletionIds(record).Length)) throw Invalid();
        return record with { State = record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview : record.State };
    }
    private void CheckRecognitionOwner(PhotoRecognitionRecord record)
    {
        RequireManagementStore(); RequireAccess(record.Space);
        if (record.ProfileId != ProfileId || record.Owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
    }
    private PhotoRecognitionTask OwnedRecognition(Guid id)
    {
        if (!_changes.Recognition.TryGetValue(id, out var task)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        CheckRecognitionOwner(task.Record); return task;
    }
    private Task SaveRecognitionAsync(PhotoRecognitionTask task) => SaveManagementRecordAsync(task.Record.Id, new(1, Recognition: task.Record));
    private static bool ActiveRecognition(PhotoRecognitionRecord record) => record.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled);
    private static bool RecognitionNeedsInput(PhotoRecognitionTask task) => ActiveRecognition(task.Record) && (task.Record.Manual is not null
        ? ManualCanResume(task.Record) && task.ManualInput is null && task.Record.Manual.Changes.Any(change => change.Kind != SynologyPhotoFaceChangeKind.Remove && change.State != ManualFaceStep.Completed)
        : RecognitionUsesName(task.Record.Kind) && task.Name is null);
    private static bool RecognitionCanContinue(PhotoRecognitionTask task) => task.Record.Similar is not null ? SimilarCanContinue(task.Record) : task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed && !RecognitionNeedsInput(task) &&
        (task.Record.Manual is null || ManualCanResume(task.Record));
    private SynologyPhotoRecognitionChange RecognitionSnapshot(PhotoRecognitionTask task) => new(task.Record.Id, task.Record.Kind, task.Record.Space,
        task.Record.State, task.Record.Failure, task.Running, !task.Running && RecognitionCanContinue(task), RecognitionNeedsInput(task),
        task.Record.Manual?.Changes.Length ?? RecognitionCompletionIds(task.Record).Length, task.Record.CompletedIds ?? [], task.People, task.Record.RemovedIds ?? [])
        { TargetIds = SimilarKind(task.Record.Kind) ? RecognitionCompletionIds(task.Record) : ConceptKind(task.Record.Kind) ? task.Record.Concepts!.Select(value => value.Id).ToArray() : RecognitionPersonIds(task.Record).Distinct().ToArray(),
            SimilarGroups = task.Record.Similar?.Select(step => new SynologyPhotoSimilarResult(step.OperationId, step.Group.Id, step.State, step.Result, step.Accepted)).ToArray() ?? [],
            CanUndo = SimilarCanUndo(task.Record), UndoOperationId = task.Record.UndoOperationId,
            Concepts = task.Concepts, PhotoIds = task.Record.Photos.Select(photo => photo.Id).ToArray(), RemovedPhotoIds = task.Record.RemovedPhotoIds ?? [],
            CompletedFaceChanges = task.Record.Manual?.Changes.Where(change => change.State == ManualFaceStep.Completed).Select(change => change.Id).ToArray() ?? [] };
    public async Task<IReadOnlyList<SynologyPhotoRecognitionChange>> RecognitionChangesAsync(CancellationToken cancellationToken = default)
    {
        var owner = UploadOwner(); await LoadChangesAsync().ConfigureAwait(false); cancellationToken.ThrowIfCancellationRequested();
        if (owner != UploadOwner()) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return _changes.Recognition.Values.Where(task => task.Record.Owner == owner).Select(RecognitionSnapshot).ToArray();
    }
    public async Task PrepareRecognitionAsync(SynologyPhotoRecognitionEdit edit, CancellationToken cancellationToken = default)
    {
        if (edit.Kind == SynologyPhotoRecognitionKind.ManualFaces) edit = edit with { FaceChanges = FreezeManualInput(edit)!, OriginalRegions = edit.OriginalRegions.ToArray() };
        var record = RecognitionRecord(Guid.NewGuid(), edit); await LoadChangesAsync().ConfigureAwait(false);
        _ = await PrepareRecognitionCoreAsync(record, false, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoRecognitionChange> EditRecognitionAsync(Guid operationId, SynologyPhotoRecognitionEdit edit, CancellationToken cancellationToken = default)
    {
        if (edit.Kind == SynologyPhotoRecognitionKind.ManualFaces) edit = edit with { FaceChanges = FreezeManualInput(edit)!, OriginalRegions = edit.OriginalRegions.ToArray() };
        var record = RecognitionRecord(operationId, edit); await LoadChangesAsync().ConfigureAwait(false); var existing = false;
        await _changes.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_changes.Tasks.ContainsKey(operationId) || _changes.Folders.ContainsKey(operationId) || _changes.Files.ContainsKey(operationId) ||
                _changes.Albums.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId) ||
                _changes.Requests.ContainsKey(operationId) || _changes.FolderSharing.ContainsKey(operationId) || _changes.Previews.ContainsKey(operationId) || _changes.Automatic.ContainsKey(operationId) || _changes.Settings.ContainsKey(operationId)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_changes.Recognition.TryGetValue(operationId, out var old))
            {
                CheckRecognitionOwner(old.Record); if (old.Record.Fingerprint != record.Fingerprint) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                if (!old.Running) { old.Name = edit.Name; old.ManualInput = FreezeManualInput(edit); } existing = true;
            }
            else
            {
                var photos = await PrepareRecognitionCoreAsync(record, false, cancellationToken).ConfigureAwait(false);
                var task = new PhotoRecognitionTask(record with { Photos = photos }) { Name = edit.Name, ManualInput = FreezeManualInput(edit) };
                await SaveRecognitionAsync(task).ConfigureAwait(false); _changes.Recognition.TryAdd(operationId, task);
            }
        }
        finally { _changes.Gate.Release(); }
        return existing ? await ReviewRecognitionAsync(operationId, cancellationToken).ConfigureAwait(false) : await ContinueRecognitionAsync(operationId, cancellationToken).ConfigureAwait(false);
    }
    public async Task<SynologyPhotoRecognitionChange> ContinueRecognitionAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedRecognition(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return RecognitionSnapshot(task);
        var owner = _changes.Owners.GetOrAdd(task.Record.Owner, _ => new(1, 1)); var owns = false; task.Running = true;
        try
        {
            await owner.WaitAsync(cancellationToken).ConfigureAwait(false); owns = true;
            await ReviewRecognitionCoreAsync(task, cancellationToken).ConfigureAwait(false);
            if (RecognitionCanContinue(task)) await SendRecognitionAsync(task, cancellationToken).ConfigureAwait(false);
        }
        finally { task.Running = false; if (owns) owner.Release(); task.Gate.Release(); }
        return RecognitionSnapshot(task);
    }
    public async Task<SynologyPhotoRecognitionChange> ReviewRecognitionAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedRecognition(operationId);
        if (!await task.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return RecognitionSnapshot(task);
        try { await ReviewRecognitionCoreAsync(task, cancellationToken).ConfigureAwait(false); return RecognitionSnapshot(task); }
        finally { task.Gate.Release(); }
    }
    public async Task<SynologyPhotoRecognitionChange> CancelRecognitionAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var task = OwnedRecognition(operationId); await task.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (task.Record.Similar is not null) { await CancelSimilarAsync(task).ConfigureAwait(false); return RecognitionSnapshot(task); }
            if (task.Record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)
            { task.Record = task.Record with { State = SynologyPhotoChangeState.Cancelled }; task.Name = null; task.ManualInput = null; await SaveRecognitionAsync(task).ConfigureAwait(false); }
            return RecognitionSnapshot(task);
        }
        finally { task.Gate.Release(); }
    }
}
