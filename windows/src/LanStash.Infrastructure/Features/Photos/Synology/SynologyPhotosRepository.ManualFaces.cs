using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private enum ManualFaceStep { Ready, Submitting, Accepted, Rejected, Completed }
    private sealed record ManualRegion(long Id, long PersonId, string NameHash, SynologyPhotoFaceBounds Bounds);
    private sealed record ManualChange(string Id, SynologyPhotoFaceChangeKind Kind, string TemporaryId, ManualRegion? Original,
        SynologyPhotoFaceBounds? Bounds, long? PersonId, string? NameHash, string? ImageHash,
        long? FaceReceipt = null, long? PersonReceipt = null, ManualFaceStep State = ManualFaceStep.Ready,
        ManualFaceStep Upload = ManualFaceStep.Ready);
    private sealed record ManualFaceRecord(ManualRegion[] Originals, ManualChange[] Changes, ManualFaceStep Add = ManualFaceStep.Ready);
    private static string FaceImageHash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static ManualRegion ManualOriginal(SynologyPhotoFaceRegion face) => new(face.Id, face.PersonId, PhotoTextHash(face.Name), face.Bounds);
    private static bool ValidManualRegion(ManualRegion face) => face.Id > 0 && face.PersonId >= 0 && UploadHash(face.NameHash) && face.Bounds is { IsValid: true };
    private static bool SameManualRegion(ManualRegion original, SynologyPhotoFaceRegion current) => original.Id == current.Id && original.PersonId == current.PersonId &&
        original.NameHash == PhotoTextHash(current.Name) && original.Bounds.Matches(current.Bounds);
    private static SynologyPhotoFaceChange[]? FreezeManualInput(SynologyPhotoRecognitionEdit edit) => edit.Kind != SynologyPhotoRecognitionKind.ManualFaces ? null :
        edit.FaceChanges.Select(change => change with { Jpeg = change.Jpeg?.ToArray() }).ToArray();
    public bool SupportsManualFaceEditing(SynologyPhotoSpace space)
    {
        if (!SupportsRecognitionManagement) return false;
        try { RequireCategoryAccess(SynologyPhotoCategory.People, space); _ = Capability("Browse.Item", 6, space); _ = Capability("Browse.Person", 3, space); _ = Capability("Upload.Face", 1, space); return true; }
        catch (SynologyPhotoException) { return false; }
    }

    public async Task<IReadOnlyList<SynologyPhotoFaceRegion>> PhotoFacesAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        RequirePhoto(photo); RequireCategoryAccess(SynologyPhotoCategory.People, photo.Id.Space);
        if (photo.MediaType == "video") throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        var generation = Volatile.Read(ref _accessGeneration);
        if (photo.AlbumContext is not null)
        {
            var current = await DetailsAsync(photo, cancellationToken).ConfigureAwait(false);
            if (!photo.IsSameDeletionTarget(current) || photo.AlbumContext != current.AlbumContext) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            await AuthorizePhotoEditAsync(current, cancellationToken).ConfigureAwait(false);
        }
        var faces = List(await ReadAsync("Browse.Item", 6, "list_face", Parameters(("id_item", photo.Id.ItemId), ("additional", new[] { "thumbnail" })),
            cancellationToken, photo.Id.Space).ConfigureAwait(false)).Select(raw =>
        {
            var box = Object(raw["face_bounding_box"]); var top = Object(box["top_left"]); var bottom = Object(box["bottom_right"]);
            var x = Decimal(top, "x"); var y = Decimal(top, "y"); var bounds = new SynologyPhotoFaceBounds(x, y, Decimal(bottom, "x") - x, Decimal(bottom, "y") - y);
            var id = Positive(raw, "face_id"); var person = Number(raw, "person_id");
            if (person < 0 || !bounds.IsValid) throw Invalid();
            var thumbnail = OptionalObject(OptionalObject(raw, "additional") ?? new(), "thumbnail");
            return new SynologyPhotoFaceRegion(id, person, Text(raw, "name"), bounds, thumbnail is null ? null : new(id, Text(thumbnail, "cache_key"))
            { Space = photo.Id.Space, Type = SynologyPhotoThumbnailType.Face, NativeSize = true });
        }).ToArray();
        if (faces.DistinctBy(face => face.Id).Count() != faces.Length) throw Invalid();
        lock (_accessGate)
        {
            RequireGeneration(generation, cancellationToken);
            foreach (var face in _authorizedFaces.Values.Where(face => face.Photo.Id == photo.Id)) _authorizedFaces.TryRemove((photo.Id.Space, face.Id), out _);
            foreach (var face in faces) _authorizedFaces[(photo.Id.Space, face.Id)] = new(face.Id, face.PersonId, photo, face.Thumbnail);
        }
        return faces;
    }
    private PhotoRecognitionRecord ManualRecognitionRecord(Guid id, SynologyPhotoRecognitionEdit edit)
    {
        if (id == Guid.Empty || !Enum.IsDefined(edit.Space) || edit.ManualPhoto is not { } photo || photo.Id.Space != edit.Space || photo.MediaType == "video" ||
            edit.People.Count != 0 || edit.Name is not null || edit.Visible || edit.CoverPhoto is not null || edit.Faces.Count != 0 ||
            edit.FaceChanges is not { Count: > 0 and <= 100 }) throw Invalid();
        RequirePhoto(photo);
        var regions = edit.OriginalRegions.Select(ManualOriginal).OrderBy(face => face.Id).ToArray();
        if (regions.Any(face => !ValidManualRegion(face)) || regions.DistinctBy(face => face.Id).Count() != regions.Length) throw Invalid();
        var people = new Dictionary<long, RecognitionPerson>();
        var changes = edit.FaceChanges.Select(change =>
        {
            if (!Enum.IsDefined(change.Kind)) throw Invalid();
            var original = change.Original is null ? null : ManualOriginal(change.Original);
            var add = change.Kind == SynologyPhotoFaceChangeKind.Add; var remove = change.Kind == SynologyPhotoFaceChangeKind.Remove;
            if (add ? original is not null || string.IsNullOrWhiteSpace(change.TemporaryId) || change.TemporaryId.Length > 256 || change.Bounds is not { IsValid: true } ||
                    change.Jpeg is not { Length: >= 3 and <= DsmApiClient.MaximumPhotoResponseBytes } || change.Jpeg[0] != 255 || change.Jpeg[1] != 216 || change.Jpeg[2] != 255
                : original is null || !regions.Contains(original) || change.Bounds is not null || change.Jpeg is not null || change.TemporaryId.Length != 0) throw Invalid();
            if (remove ? change.Person is not null || change.Name is not null : change.Name is null || change.Person is null && string.IsNullOrWhiteSpace(change.Name)) throw Invalid();
            if (change.Person is { } person)
            {
                if (person.Id <= 0 || person.Space != edit.Space || person.Name != change.Name) throw Invalid();
                var item = new RecognitionPerson(person.Id, PhotoTextHash(person.Name), null, null);
                if (people.TryGetValue(person.Id, out var prior) && prior != item) throw Invalid(); people[person.Id] = item;
            }
            return new ManualChange(change.Id, change.Kind, change.TemporaryId, original, change.Bounds, change.Person?.Id,
                change.Name is null ? null : PhotoTextHash(change.Name), change.Jpeg is null ? null : FaceImageHash(change.Jpeg));
        }).ToArray();
        if (changes.DistinctBy(change => change.Id).Count() != changes.Length) throw Invalid();
        var photos = new[] { new RecognitionPhoto(photo.Id.ItemId, photo.FolderId, RecognitionPhotoHash(photo), photo.AlbumContext) };
        var manual = new ManualFaceRecord(regions, changes); var targets = people.Values.OrderBy(person => person.Id).ToArray();
        var fingerprint = PhotoTextHash(JsonSerializer.Serialize(new { edit.Kind, edit.Space, Photos = photos, People = targets, Manual = manual }));
        return new(id, ProfileId, UploadOwner(), fingerprint, edit.Kind, edit.Space, targets, null, false, photos, Manual: manual);
    }
    private static bool ManualHasPending(ManualFaceRecord manual) => manual.Add == ManualFaceStep.Submitting || manual.Changes.Any(change => change.State != ManualFaceStep.Completed &&
        (change.State is ManualFaceStep.Submitting or ManualFaceStep.Accepted || change.Upload is ManualFaceStep.Submitting or ManualFaceStep.Accepted));
    private static bool ManualCanResume(PhotoRecognitionRecord record)
    {
        if (record.Manual is not { } manual || ManualHasPending(manual)) return false;
        return manual.Add != ManualFaceStep.Accepted || manual.Changes.Where(change => change.Kind == SynologyPhotoFaceChangeKind.Add).All(change => change.FaceReceipt is not null);
    }
    private static PhotoRecognitionRecord RestoreManualRecognition(Guid id, PhotoRecognitionRecord record)
    {
        if (id == Guid.Empty || id != record.Id || record.ProfileId == Guid.Empty || !UploadHash(record.Owner) || !UploadHash(record.Fingerprint) ||
            !Enum.IsDefined(record.Space) || !Enum.IsDefined(record.State) || record.Failure is { } failure && !Enum.IsDefined(failure) ||
            record.Manual is not { } manual || manual.Originals is null || manual.Originals.Any(face => !ValidManualRegion(face)) ||
            manual.Originals.DistinctBy(face => face.Id).Count() != manual.Originals.Length || manual.Changes is not { Length: > 0 and <= 100 } ||
            !Enum.IsDefined(manual.Add) || manual.Add == ManualFaceStep.Completed || manual.Changes.DistinctBy(change => change.Id).Count() != manual.Changes.Length ||
            record.People is null || record.People.Length > 100 || record.People.Any(person => person.Id <= 0 || !UploadHash(person.NameHash) || person.Count is not null || person.Visible is not null) ||
            record.People.DistinctBy(person => person.Id).Count() != record.People.Length || record.Photos is not { Length: 1 } ||
            record.NameHash is not null || record.Visible || (record.Faces ?? []).Length != 0 || record.CoverReceipt is not null || record.PersonReceipt is not null ||
            (record.CompletedIds ?? []).Length != 0 || (record.RemovedIds ?? []).Length != 0 || (record.RemovedPhotoIds ?? []).Length != 0) throw Invalid();
        var photo = record.Photos[0];
        if (photo.Id <= 0 || photo.FolderId <= 0 || !UploadHash(photo.IdentityHash) || photo.Album is { } album &&
            (album.AlbumId <= 0 || album.OwnerUserId < 0 || album.ProviderUserId < 0 || record.Space != (album.OwnerUserId == 0 ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal))) throw Invalid();
        foreach (var change in manual.Changes)
        {
            if (!Enum.IsDefined(change.Kind) || !Enum.IsDefined(change.State) || !Enum.IsDefined(change.Upload)) throw Invalid();
            var add = change.Kind == SynologyPhotoFaceChangeKind.Add; var remove = change.Kind == SynologyPhotoFaceChangeKind.Remove;
            if (add ? change.Original is not null || string.IsNullOrWhiteSpace(change.TemporaryId) || change.TemporaryId.Length > 256 || change.Id != "new-" + change.TemporaryId ||
                    change.Bounds is not { IsValid: true } || !UploadHash(change.ImageHash) || change.State is not (ManualFaceStep.Ready or ManualFaceStep.Completed)
                : change.Original is null || !manual.Originals.Contains(change.Original) || change.Id != "face-" + change.Original.Id.ToString(System.Globalization.CultureInfo.InvariantCulture) ||
                    change.TemporaryId != "" || change.Bounds is not null || change.ImageHash is not null || change.FaceReceipt is not null || change.Upload != ManualFaceStep.Ready) throw Invalid();
            if (remove ? change.NameHash is not null || change.PersonId is not null || change.PersonReceipt is not null : !UploadHash(change.NameHash)) throw Invalid();
            if (change.PersonId is { } person && !record.People.Any(target => target.Id == person && target.NameHash == change.NameHash)) throw Invalid();
            if (change.FaceReceipt is { } face && (face <= 0 || manual.Add != ManualFaceStep.Accepted || manual.Originals.Any(original => original.Id == face)) ||
                change.Upload != ManualFaceStep.Ready && change.FaceReceipt is null ||
                change.PersonReceipt is { } receipt && (receipt <= 0 || remove || change.State is not (ManualFaceStep.Accepted or ManualFaceStep.Completed) || add && change.State != ManualFaceStep.Completed || change.PersonId is { } target && target != receipt) ||
                change.Kind == SynologyPhotoFaceChangeKind.Reassign && change.State is ManualFaceStep.Accepted or ManualFaceStep.Completed && change.PersonReceipt is null ||
                add && (change.State == ManualFaceStep.Completed != (change.Upload == ManualFaceStep.Completed) ||
                    change.State == ManualFaceStep.Completed && (change.FaceReceipt is null || change.PersonReceipt is null))) throw Invalid();
        }
        var additions = manual.Changes.Where(change => change.Kind == SynologyPhotoFaceChangeKind.Add).ToArray();
        var receipts = additions.Select(change => change.FaceReceipt).OfType<long>().ToArray();
        if (receipts.Distinct().Count() != receipts.Length || additions.Length == 0 && manual.Add != ManualFaceStep.Ready ||
            record.People.Any(person => !manual.Changes.Any(change => change.PersonId == person.Id)) ||
            manual.Changes.Any(change => change.Kind != SynologyPhotoFaceChangeKind.Add && change.State != ManualFaceStep.Ready) && additions.Any(change => change.State != ManualFaceStep.Completed) ||
            record.State == SynologyPhotoChangeState.Completed && manual.Changes.Any(change => change.State != ManualFaceStep.Completed) ||
            record.State is SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed or SynologyPhotoChangeState.Cancelled && ManualHasPending(manual)) throw Invalid();
        return record with { State = record.State == SynologyPhotoChangeState.Submitting ? SynologyPhotoChangeState.PendingReview : record.State };
    }
    private async Task<RecognitionPhoto[]> PrepareManualFacesAsync(PhotoRecognitionRecord record, CancellationToken token)
    {
        CheckRecognitionOwner(record); var generation = Volatile.Read(ref _accessGeneration); var manual = record.Manual!;
        await FreshPeopleAccessAsync(record.Space, token).ConfigureAwait(false);
        if (!RecognitionSafety.CorrectFaces) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        _ = Capability("Browse.Item", 6, record.Space); _ = Capability("Browse.Person", 3, record.Space); _ = Capability("Upload.Face", 1, record.Space);
        if (_changes.Recognition.Values.Any(task => task.Record.Id != record.Id && task.Record.Owner == record.Owner && task.Record.Space == record.Space &&
            ActiveRecognition(task.Record) && RecognitionPersonIds(task.Record).Intersect(RecognitionPersonIds(record)).Any())) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        var photo = (await RecognitionOriginalsAsync(record, token).ConfigureAwait(false)).Single();
        if (photo.MediaType == "video") throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        await AuthorizePhotoEditAsync(photo, token).ConfigureAwait(false);
        if (photo.AlbumContext is { } album) await CheckAlbumBusyAsync(album.AlbumId, token, record.Id).ConfigureAwait(false);
        if (FilePhotoBusy(photo.Id) || AlbumPhotoBusy(photo.Id) || RecognitionPhotoBusy(photo.Id, record.Id) || PreviewPhotoBusy(photo.Id) ||
            _changes.Tasks.Values.Any(task => task.Record.Owner == record.Owner && task.Record.Items.Any(item => item.Original.Id == photo.Id && item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled))) ||
            _changes.Folders.Values.Any(task => task.Record.Owner == record.Owner && ActiveFolderChange(task.Record) && task.Record.Edit.Photo?.Id == photo.Id)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        await CheckManagedFolderConflictsAsync(photo.FolderId, record.Space, null, token, exceptRecognition: record.Id).ConfigureAwait(false);
        if (photo.AlbumContext is null || photo.AlbumContext.OwnerUserId == _currentUserId || record.Space == SynologyPhotoSpace.Shared)
        {
            var folder = PhotoFolder(await ReadPhotoFolderAsync(photo.FolderId, record.Space, PhotoFolderRight.View, token).ConfigureAwait(false), record.Space);
            await CheckRecognitionUploadLocksAsync(folder, record.Owner, token).ConfigureAwait(false);
        }
        var faces = await PhotoFacesAsync(photo, token).ConfigureAwait(false);
        // 第一次写入前固定全图人脸；后续阶段只允许本任务已确认的变化，不用旧草稿覆盖他端更改。
        var started = manual.Add is ManualFaceStep.Submitting or ManualFaceStep.Accepted || manual.Changes.Any(change => change.State is ManualFaceStep.Submitting or ManualFaceStep.Accepted or ManualFaceStep.Completed);
        if (!started && (faces.Count != manual.Originals.Length || manual.Originals.Any(original => !faces.Any(face => SameManualRegion(original, face))))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        foreach (var change in manual.Changes.Where(change => change.Original is not null && change.State is ManualFaceStep.Ready or ManualFaceStep.Rejected))
            if (!faces.Any(face => SameManualRegion(change.Original!, face))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        foreach (var original in manual.Originals)
        {
            var changed = manual.Changes.SingleOrDefault(change => change.Original?.Id == original.Id);
            if (changed?.State == ManualFaceStep.Completed)
            {
                var face = faces.SingleOrDefault(face => face.Id == original.Id);
                if (changed.Kind == SynologyPhotoFaceChangeKind.Remove ? face is not null : face is null || face.PersonId != changed.PersonReceipt ||
                    PhotoTextHash(face.Name) != changed.NameHash || !original.Bounds.Matches(face.Bounds)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            }
            else if (changed is null && !faces.Any(face => SameManualRegion(original, face))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        foreach (var addition in manual.Changes.Where(change => change.Kind == SynologyPhotoFaceChangeKind.Add && change.State == ManualFaceStep.Completed))
            if (!faces.Any(face => face.Thumbnail is not null && MatchesManualAddition(addition, face))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        if (record.People.Length > 0)
        {
            var people = await PersonStatesAsync(record.People.Select(person => person.Id).ToArray(), record.Space, token).ConfigureAwait(false);
            if (record.People.Any(person => !people.Any(current => current.Person.Id == person.Id && PhotoTextHash(current.Person.Name) == person.NameHash))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        }
        RequireGeneration(generation, token); CheckRecognitionOwner(record); return record.Photos;
    }
}
