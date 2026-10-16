using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static string RecognitionPhotoHash(SynologyPhoto photo) => PhotoTextHash(JsonSerializer.Serialize(new
    { photo.Id, photo.Filename, photo.SizeBytes, photo.TakenAt, photo.IndexedAt, photo.FolderId, photo.MediaType }));
    private static bool SameRecognitionPerson(RecognitionPerson original, SynologyPhotoPerson current, bool visibility) =>
        original.Id == current.Person.Id && original.NameHash == PhotoTextHash(current.Person.Name) &&
        (original.Count is null || original.Count == current.Person.Count) && (!visibility || original.Visible == current.Visible);
    private async Task<RecognitionPhoto[]> PrepareRecognitionCoreAsync(PhotoRecognitionRecord record, bool comparePhotos, CancellationToken token)
    {
        CheckRecognitionOwner(record); var generation = Volatile.Read(ref _accessGeneration);
        if (record.Space == SynologyPhotoSpace.Shared && MembersBusy()) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        if (record.Similar is not null)
        {
            foreach (var step in record.Similar) await PrepareSimilarStepAsync(record, step, token).ConfigureAwait(false);
            RequireGeneration(generation, token); return record.Photos;
        }
        if (ConceptKind(record.Kind)) return await PrepareConceptAsync(record, token).ConfigureAwait(false);
        if (record.Manual is not null) return await PrepareManualFacesAsync(record, token).ConfigureAwait(false);
        await FreshPeopleAccessAsync(record.Space, token).ConfigureAwait(false);
        _ = Capability("Browse.Person", record.Kind == SynologyPhotoRecognitionKind.MergePeople ? 2 : 1, record.Space);
        if (record.Kind == SynologyPhotoRecognitionKind.MergePeople)
        {
            if (!RecognitionSafety.MergePeople) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
            _ = Capability("Browse.Timeline", 5, record.Space); _ = Capability("Browse.Item", 4, record.Space); _ = Capability("Browse.Folder", 2, record.Space);
        }
        if (_changes.Recognition.Values.Any(task => task.Record.Id != record.Id && task.Record.Owner == record.Owner && task.Record.Space == record.Space &&
            ActiveRecognition(task.Record) && RecognitionPersonIds(task.Record).Intersect(RecognitionPersonIds(record)).Any()))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        await ValidateRecognitionPeopleAsync(record, token).ConfigureAwait(false);
        var photos = new Dictionary<long, RecognitionPhoto>();
        if (RecognitionUsesPhotos(record.Kind))
        {
            if (RecognitionCorrectsFaces(record.Kind) && !RecognitionSafety.CorrectFaces) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
            _ = Capability("Browse.Item", 5, record.Space); _ = Capability("Browse.Folder", 2, record.Space);
            var originals = await RecognitionOriginalsAsync(record, token).ConfigureAwait(false);
            foreach (var photo in originals)
            {
                await CheckRecognitionPhotoLocksAsync(record, photo, token).ConfigureAwait(false);
                photos[photo.Id.ItemId] = new(photo.Id.ItemId, photo.FolderId, RecognitionPhotoHash(photo));
            }
            var faces = await PersonFacesAsync(record.People[0].Id, originals, token).ConfigureAwait(false);
            if (record.Kind == SynologyPhotoRecognitionKind.SetPersonCover ? faces.Count == 0 :
                (record.Faces ?? []).Any(face => !faces.Any(current => current.Id == face.Id && current.Photo.Id.ItemId == face.PhotoId)))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            await ValidateRecognitionPeopleAsync(record, token).ConfigureAwait(false);
        }
        if (record.Kind == SynologyPhotoRecognitionKind.MergePeople)
        {
            var folders = new HashSet<long>();
            foreach (var person in record.People)
            {
                var items = await CategoryPhotosAsync(SynologyPhotoCategory.People, person.Id, record.Space, token).ConfigureAwait(false);
                if (person.Count is { } count && items.Length != count) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                foreach (var photo in items)
                {
                    if (photo.Id.Space != record.Space || photo.Id.ProfileId != ProfileId || photo.AlbumContext is not null) throw Invalid();
                    var entry = new RecognitionPhoto(photo.Id.ItemId, photo.FolderId, RecognitionPhotoHash(photo));
                    if (photos.TryGetValue(entry.Id, out var existing) && existing != entry) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                    photos[entry.Id] = entry;
                    if (FilePhotoBusy(photo.Id) || AlbumPhotoBusy(photo.Id) || RecognitionPhotoBusy(photo.Id, record.Id) || PreviewPhotoBusy(photo.Id) ||
                        _changes.Tasks.Values.Any(task => task.Record.Owner == record.Owner && task.Record.Items.Any(item => item.Original.Id == photo.Id && item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled))) ||
                        _changes.Folders.Values.Any(task => task.Record.Owner == record.Owner && ActiveFolderChange(task.Record) && task.Record.Edit.Photo?.Id == photo.Id))
                        throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
                    if (!folders.Add(photo.FolderId)) continue;
                    var folder = PhotoFolder(await ReadPhotoFolderAsync(photo.FolderId, record.Space, PhotoFolderRight.Manage, token).ConfigureAwait(false), record.Space);
                    await CheckManagedFolderConflictsAsync(photo.FolderId, record.Space, null, token, exceptRecognition: record.Id).ConfigureAwait(false);
                    await CheckRecognitionUploadLocksAsync(folder, record.Owner, token).ConfigureAwait(false);
                }
            }
            if (comparePhotos && !photos.Values.ToHashSet().SetEquals(record.Photos)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            await ValidateRecognitionPeopleAsync(record, token).ConfigureAwait(false);
        }
        RequireGeneration(generation, token); CheckRecognitionOwner(record); return photos.Values.OrderBy(photo => photo.Id).ToArray();
    }
    private async Task CheckRecognitionPhotoLocksAsync(PhotoRecognitionRecord record, SynologyPhoto photo, CancellationToken token)
    {
        if (FilePhotoBusy(photo.Id) || AlbumPhotoBusy(photo.Id) || RecognitionPhotoBusy(photo.Id, record.Id) || PreviewPhotoBusy(photo.Id) ||
            _changes.Tasks.Values.Any(task => task.Record.Owner == record.Owner && task.Record.Items.Any(item => item.Original.Id == photo.Id && item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled))) ||
            _changes.Folders.Values.Any(task => task.Record.Owner == record.Owner && ActiveFolderChange(task.Record) && task.Record.Edit.Photo?.Id == photo.Id))
            throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        var folder = PhotoFolder(await ReadPhotoFolderAsync(photo.FolderId, record.Space, PhotoFolderRight.Manage, token).ConfigureAwait(false), record.Space);
        await CheckManagedFolderConflictsAsync(photo.FolderId, record.Space, null, token, exceptRecognition: record.Id).ConfigureAwait(false);
        await CheckRecognitionUploadLocksAsync(folder, record.Owner, token).ConfigureAwait(false);
    }
    private async Task ValidateRecognitionPeopleAsync(PhotoRecognitionRecord record, CancellationToken token)
    {
        var current = record.Kind == SynologyPhotoRecognitionKind.ShowPeople
            ? await PersonStatesAsync(record.People.Select(person => person.Id).ToArray(), record.Space, token).ConfigureAwait(false)
            : await PeopleAsync(record.Space, false, token).ConfigureAwait(false);
        if (record.People.Any(person => !current.Any(value => SameRecognitionPerson(person, value, record.Kind == SynologyPhotoRecognitionKind.ShowPeople))))
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
    }
    private bool RecognitionPhotoBusy(SynologyPhotoIdentity id, Guid except = default) => _changes.Recognition.Values.Any(task =>
        task.Record.Id != except && task.Record.Owner == UploadOwner() && task.Record.Space == id.Space && ActiveRecognition(task.Record) && task.Record.Photos.Any(photo => photo.Id == id.ItemId));
    private IEnumerable<long> RecognitionFolders(SynologyPhotoSpace space, Guid except = default) => _changes.Recognition.Values.Where(task => task.Record.Id != except &&
        task.Record.Owner == UploadOwner() && task.Record.Space == space && ActiveRecognition(task.Record)).SelectMany(task => task.Record.Photos).Select(photo => photo.FolderId).Distinct();
    private async Task CheckRecognitionFolderLocksAsync(SynologyPhotoFolder folder, CancellationToken token, bool includeChildren = false, Guid except = default)
    {
        if (AutomaticBackgroundBusy(folder.Space)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        foreach (var id in RecognitionFolders(folder.Space, except).Concat(PreviewFolders(folder.Space)))
        {
            if (id == folder.Id) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            if (!includeChildren) continue;
            var target = PhotoFolder(await ReadPhotoFolderAsync(id, folder.Space, PhotoFolderRight.View, token).ConfigureAwait(false), folder.Space);
            if (FolderContains(folder.Path, target.Path)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        }
    }
    private async Task CheckRecognitionUploadLocksAsync(SynologyPhotoFolder folder, string owner, CancellationToken token)
    {
        if (_uploadStore is null) return; await LoadUploadsAsync().ConfigureAwait(false);
        foreach (var upload in _uploads.Tasks.Values.Where(task => task.Record.Owner == owner && task.Record.Target.Space == folder.Space && !task.Record.Target.DirectToAlbum &&
            task.Record.Items.Any(item => item.State is not (SynologyPhotoUploadState.Completed or SynologyPhotoUploadState.Skipped or SynologyPhotoUploadState.Cancelled))))
        {
            if ((upload.Record.Root?.Id ?? upload.Record.Target.FolderId) is not { } id) continue;
            var target = PhotoFolder(await ReadPhotoFolderAsync(id, folder.Space, PhotoFolderRight.View, token).ConfigureAwait(false), folder.Space);
            if (FolderContains(target.Path, folder.Path) || FolderContains(folder.Path, target.Path)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        }
    }
}
