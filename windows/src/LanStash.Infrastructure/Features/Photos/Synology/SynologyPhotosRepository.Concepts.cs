using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private sealed record RecognitionConcept(long Id, string NameHash, int? Count, bool Visible, int? Threshold, long? CoverId, string? CoverHash);
    private static bool ConceptKind(SynologyPhotoRecognitionKind kind) => kind is SynologyPhotoRecognitionKind.ShowConcepts or SynologyPhotoRecognitionKind.SetConceptCover or SynologyPhotoRecognitionKind.RemoveConceptPhotos;
    private static RecognitionConcept ConceptSnapshot(SynologyPhotoConcept value) => new(value.Concept.Id, PhotoTextHash(value.Concept.Name), value.Concept.Count,
        value.Visible, value.DisplayThreshold, value.Concept.Thumbnail?.UnitId, value.Concept.Thumbnail is { } thumb ? PhotoTextHash(thumb.Revision) : null);
    public bool SupportsConceptManagement(SynologyPhotoSpace space)
    {
        if (!SupportsRecognitionManagement) return false;
        try { RequireCategoryAccess(SynologyPhotoCategory.Subjects, space); _ = Capability("Browse.Concept", 2, space); return true; }
        catch (SynologyPhotoException) { return false; }
    }
    private SynologyPhotoConcept Concept(JsonObject raw, SynologyPhotoSpace space)
    {
        var count = OptionalInt(raw, "item_count"); var threshold = OptionalInt(raw, "display_threshold"); if (count < 0 || threshold < 0) throw Invalid();
        var thumb = OptionalObject(OptionalObject(raw, "additional") ?? new(), "thumbnail");
        SynologyPhotoThumbnail? thumbnail = thumb is null ? null : new(Positive(thumb, "unit_id"), Text(thumb, "cache_key")) { Space = space, NativeSize = true };
        return new(new(Positive(raw, "id"), Text(raw, "name"), Count: count) { Space = space, Thumbnail = thumbnail }, Boolean(raw, "visibility"), threshold);
    }
    private void CacheConcepts(IReadOnlyList<SynologyPhotoConcept> concepts, SynologyPhotoSpace space, bool replace)
    {
        if (replace) foreach (var key in _categoryThumbnails.Keys.Where(key => key.Item1 == space && key.Item2 == SynologyPhotoCategory.Subjects)) _categoryThumbnails.TryRemove(key, out _);
        foreach (var value in concepts)
        {
            var key = (space, SynologyPhotoCategory.Subjects, value.Concept.Id);
            if (value.Concept.Thumbnail is { } thumbnail) _categoryThumbnails[key] = thumbnail; else _categoryThumbnails.TryRemove(key, out _);
        }
    }
    public async Task<IReadOnlyList<SynologyPhotoConcept>> ConceptsAsync(SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    {
        RequireCategoryAccess(SynologyPhotoCategory.Subjects, space); var generation = Volatile.Read(ref _accessGeneration);
        var result = new List<SynologyPhotoConcept>(); var seen = new HashSet<long>();
        while (true)
        {
            var data = await ReadAsync("Browse.Concept", 2, "list", Parameters(("offset", result.Count), ("limit", 500), ("show_hidden", true), ("additional", new[] { "thumbnail" })), cancellationToken, space).ConfigureAwait(false);
            var page = List(data).Select(raw => Concept(raw, space)).ToArray(); if (page.Length > 500) throw Invalid();
            foreach (var item in page) { if (!seen.Add(item.Concept.Id)) throw Invalid(); result.Add(item); }
            RequireGeneration(generation, cancellationToken); if (page.Length == 500) continue;
            lock (_accessGate) { RequireGeneration(generation, cancellationToken); CacheConcepts(result, space, true); } return result;
        }
    }
    public async Task<SynologyPhotoConcept> ConceptAsync(long id, SynologyPhotoSpace space, CancellationToken cancellationToken = default)
    { if (id <= 0) throw Invalid(); return (await ConceptStatesAsync([id], space, cancellationToken).ConfigureAwait(false)).Single(); }
    private async Task<SynologyPhotoConcept[]> ConceptStatesAsync(long[] ids, SynologyPhotoSpace space, CancellationToken token)
    {
        RequireCategoryAccess(SynologyPhotoCategory.Subjects, space); var generation = Volatile.Read(ref _accessGeneration);
        var values = List(await ReadAsync("Browse.Concept", 2, "get", Parameters(("id", ids), ("additional", new[] { "thumbnail" })), token, space).ConfigureAwait(false)).Select(raw => Concept(raw, space)).ToArray();
        if (values.Length != ids.Length || values.DistinctBy(value => value.Concept.Id).Count() != ids.Length || !values.Select(value => value.Concept.Id).ToHashSet().SetEquals(ids)) throw Invalid();
        lock (_accessGate) { RequireGeneration(generation, token); CacheConcepts(values, space, false); } return values;
    }
    private PhotoRecognitionRecord ConceptRecognitionRecord(Guid id, SynologyPhotoRecognitionEdit edit)
    {
        if (id == Guid.Empty || !Enum.IsDefined(edit.Space) || edit.People.Count != 0 || edit.Name is not null || edit.Faces.Count != 0 || edit.CoverPhoto is not null ||
            edit.ManualPhoto is not null || edit.OriginalRegions.Count != 0 || edit.FaceChanges.Count != 0 || edit.Concepts is not { Count: > 0 and <= 100 } ||
            edit.Concepts.Any(value => value.Concept.Id <= 0 || value.Concept.Space != edit.Space || value.Concept.Count < 0 || value.DisplayThreshold < 0) ||
            edit.Concepts.DistinctBy(value => value.Concept.Id).Count() != edit.Concepts.Count ||
            edit.Kind == SynologyPhotoRecognitionKind.ShowConcepts && (edit.ConceptPhotos.Count != 0 || edit.Concepts.Any(value => value.Visible == edit.Visible)) ||
            edit.Kind != SynologyPhotoRecognitionKind.ShowConcepts && (edit.Concepts.Count != 1 || edit.ConceptPhotos.Count is not (> 0 and <= 100)) ||
            edit.Kind == SynologyPhotoRecognitionKind.SetConceptCover && edit.ConceptPhotos.Count != 1 ||
            edit.Kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos && (edit.Concepts[0].Concept.Count is not { } count || count < edit.ConceptPhotos.Count || edit.Concepts[0].DisplayThreshold is null)) throw Invalid();
        foreach (var photo in edit.ConceptPhotos) { RequirePhoto(photo); if (photo.Id.Space != edit.Space || photo.AlbumContext is not null) throw Invalid(); }
        if (edit.ConceptPhotos.DistinctBy(photo => photo.Id).Count() != edit.ConceptPhotos.Count) throw Invalid();
        var concepts = edit.Concepts.Select(ConceptSnapshot).ToArray();
        var photos = edit.ConceptPhotos.Select(photo => new RecognitionPhoto(photo.Id.ItemId, photo.FolderId, RecognitionPhotoHash(photo))).OrderBy(photo => photo.Id).ToArray();
        var fingerprint = PhotoTextHash(JsonSerializer.Serialize(new { edit.Kind, edit.Space, Concepts = concepts, Photos = photos, edit.Visible }));
        return new(id, ProfileId, UploadOwner(), fingerprint, edit.Kind, edit.Space, [], null, edit.Visible, photos, Concepts: concepts);
    }
    private static PhotoRecognitionRecord RestoreConceptRecognition(Guid id, PhotoRecognitionRecord record)
    {
        if (id == Guid.Empty || id != record.Id || record.ProfileId == Guid.Empty || !UploadHash(record.Owner) || !UploadHash(record.Fingerprint) ||
            !Enum.IsDefined(record.Space) || !Enum.IsDefined(record.State) || record.Failure is { } failure && !Enum.IsDefined(failure) || record.People is not { Length: 0 } ||
            record.NameHash is not null || record.Manual is not null || (record.Faces ?? []).Length != 0 || record.CoverReceipt is not null || record.PersonReceipt is not null ||
            (record.RemovedIds ?? []).Length != 0 || record.Concepts is not { Length: > 0 and <= 100 } ||
            record.Concepts.Any(value => value.Id <= 0 || !UploadHash(value.NameHash) || value.Count < 0 || value.Threshold < 0 || value.CoverId <= 0 ||
                (value.CoverId is null) != (value.CoverHash is null) || value.CoverHash is { } hash && !UploadHash(hash)) ||
            record.Concepts.DistinctBy(value => value.Id).Count() != record.Concepts.Length || record.Photos is null ||
            record.Photos.Any(photo => photo.Id <= 0 || photo.FolderId <= 0 || !UploadHash(photo.IdentityHash) || photo.Album is not null) ||
            record.Photos.DistinctBy(photo => photo.Id).Count() != record.Photos.Length ||
            record.Kind == SynologyPhotoRecognitionKind.ShowConcepts && (record.Photos.Length != 0 || record.Concepts.Any(value => value.Visible == record.Visible)) ||
            record.Kind != SynologyPhotoRecognitionKind.ShowConcepts && (record.Concepts.Length != 1 || record.Photos.Length is not (> 0 and <= 100)) ||
            record.Kind == SynologyPhotoRecognitionKind.SetConceptCover && record.Photos.Length != 1 ||
            record.Kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos && (record.Concepts[0].Count is not { } count || count < record.Photos.Length || record.Concepts[0].Threshold is null) ||
            (record.CompletedIds ?? []).Any(value => !RecognitionCompletionIds(record).Contains(value)) ||
            (record.CompletedIds ?? []).Distinct().Count() != (record.CompletedIds ?? []).Length || (record.CompletedIds ?? []).Length > 0 && !record.Accepted ||
            record.Accepted && record.State is not (SynologyPhotoChangeState.PendingReview or SynologyPhotoChangeState.Completed) ||
            !(record.RemovedPhotoIds ?? []).ToHashSet().SetEquals(record.Kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos ? record.CompletedIds ?? [] : []) ||
            record.State == SynologyPhotoChangeState.Completed && (!record.Accepted || (record.CompletedIds ?? []).Length != RecognitionCompletionIds(record).Length)) throw Invalid();
        return record with { State = record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview : record.State };
    }
    private async Task ValidateConceptSnapshotAsync(PhotoRecognitionRecord record, CancellationToken token)
    {
        var current = await ConceptStatesAsync(record.Concepts!.Select(value => value.Id).ToArray(), record.Space, token).ConfigureAwait(false);
        foreach (var original in record.Concepts!)
        {
            var value = ConceptSnapshot(current.Single(value => value.Concept.Id == original.Id));
            if (record.Kind == SynologyPhotoRecognitionKind.ShowConcepts ? value.NameHash != original.NameHash || value.Visible != original.Visible || original.Count is { } count && value.Count != count : value != original)
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
    }
    private async Task<RecognitionPhoto[]> PrepareConceptAsync(PhotoRecognitionRecord record, CancellationToken token)
    {
        var generation = Volatile.Read(ref _accessGeneration); await FreshRecognitionAccessAsync(SynologyPhotoCategory.Subjects, record.Space, token).ConfigureAwait(false);
        _ = Capability("Browse.Concept", record.Kind == SynologyPhotoRecognitionKind.ShowConcepts ? 2 : 1, record.Space);
        if (record.Kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos && !RecognitionSafety.RemoveConceptPhotos) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        if (_changes.Recognition.Values.Any(task => task.Record.Id != record.Id && task.Record.Owner == record.Owner && task.Record.Space == record.Space && ActiveRecognition(task.Record) &&
            (task.Record.Concepts ?? []).Any(value => record.Concepts!.Any(original => original.Id == value.Id)))) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        await ValidateConceptSnapshotAsync(record, token).ConfigureAwait(false);
        if (record.Photos.Length > 0)
        {
            var originals = await RecognitionOriginalsAsync(record, token).ConfigureAwait(false);
            foreach (var photo in originals) await CheckRecognitionPhotoLocksAsync(record, photo, token).ConfigureAwait(false);
            var members = await CategoryPhotosAsync(SynologyPhotoCategory.Subjects, record.Concepts![0].Id, record.Space, token).ConfigureAwait(false);
            if (record.Concepts[0].Count is { } count && count != members.Length || originals.Any(photo => !members.Any(member => member.Id == photo.Id && RecognitionPhotoHash(member) == RecognitionPhotoHash(photo))))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            await ValidateConceptSnapshotAsync(record, token).ConfigureAwait(false);
        }
        RequireGeneration(generation, token); CheckRecognitionOwner(record); return record.Photos;
    }
    private async Task ReviewConceptAsync(PhotoRecognitionTask task, CancellationToken token)
    {
        var record = task.Record; if (!record.Accepted) return;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); await FreshRecognitionAccessAsync(SynologyPhotoCategory.Subjects, record.Space, token).ConfigureAwait(false);
            var concepts = await ConceptStatesAsync(record.Concepts!.Select(value => value.Id).ToArray(), record.Space, token).ConfigureAwait(false);
            if (concepts.Any(value => PhotoTextHash(value.Concept.Name) != record.Concepts!.Single(original => original.Id == value.Concept.Id).NameHash)) return;
            long[] completed; IReadOnlyList<SynologyPhotoConcept> updated = concepts;
            if (record.Kind == SynologyPhotoRecognitionKind.ShowConcepts)
            {
                updated = concepts.Where(value => value.Visible == record.Visible).ToArray(); completed = updated.Select(value => value.Concept.Id).ToArray();
            }
            else if (record.Kind == SynologyPhotoRecognitionKind.SetConceptCover)
            {
                if (concepts[0].Concept.Thumbnail?.UnitId != record.Photos[0].Id) return;
                _ = await RecognitionOriginalsAsync(record, token).ConfigureAwait(false); completed = [record.Concepts![0].Id];
            }
            else
            {
                var remaining = await CategoryPhotosAsync(SynologyPhotoCategory.Subjects, record.Concepts![0].Id, record.Space, token).ConfigureAwait(false);
                if (concepts[0].Concept.Count != remaining.Length || concepts[0].DisplayThreshold is null) return;
                var confirmed = new List<long>();
                foreach (var original in record.Photos.Where(photo => !remaining.Any(member => member.Id.ItemId == photo.Id)))
                {
                    try { _ = await RecognitionOriginalsAsync(record with { Photos = [original] }, token).ConfigureAwait(false); confirmed.Add(original.Id); }
                    catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
                }
                completed = confirmed.ToArray();
            }
            RequireGeneration(generation, token); CheckRecognitionOwner(record);
            var all = (record.CompletedIds ?? []).Concat(completed).Distinct().ToArray();
            task.Concepts = updated; task.Record = record with { State = completed.Length == RecognitionCompletionIds(record).Length ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview,
                CompletedIds = all, RemovedPhotoIds = record.Kind == SynologyPhotoRecognitionKind.RemoveConceptPhotos ? all : [], Failure = null };
            await SaveRecognitionAsync(task).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
}
