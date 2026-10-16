using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private readonly ConcurrentDictionary<(SynologyPhotoSpace, long), SynologyPhotoFace> _authorizedFaces = new();
    public async Task<IReadOnlyList<SynologyPhotoFace>> PersonFacesAsync(long personId, IReadOnlyList<SynologyPhoto> photos, CancellationToken cancellationToken = default)
    {
        if (personId <= 0 || photos is not { Count: > 0 and <= 100 } || photos.DistinctBy(photo => photo.Id).Count() != photos.Count) throw Invalid();
        var space = photos[0].Id.Space; RequireCategoryAccess(SynologyPhotoCategory.People, space); var generation = Volatile.Read(ref _accessGeneration);
        foreach (var photo in photos) { RequirePhoto(photo); if (photo.Id.Space != space || photo.AlbumContext is not null) throw Invalid(); }
        var result = new List<SynologyPhotoFace>(); var seen = new HashSet<long>();
        foreach (var photo in photos)
        {
            var data = await ReadAsync("Browse.Person", 1, "list_face", Parameters(("person_id", personId), ("item_id", new[] { photo.Id.ItemId })), cancellationToken, space).ConfigureAwait(false);
            foreach (var raw in List(data))
            {
                var id = Positive(raw, "id"); if (!seen.Add(id)) throw Invalid();
                var thumb = OptionalObject(OptionalObject(raw, "additional") ?? new(), "thumbnail");
                result.Add(new(id, personId, photo, thumb is null ? null : new(id, Text(thumb, "cache_key")) { Space = space, Type = SynologyPhotoThumbnailType.Face, NativeSize = true }));
            }
        }
        lock (_accessGate)
        {
            RequireGeneration(generation, cancellationToken);
            foreach (var face in _authorizedFaces.Values.Where(face => face.PersonId == personId && face.Photo.Id.Space == space && photos.Any(photo => photo.Id == face.Photo.Id)))
                _authorizedFaces.TryRemove((space, face.Id), out _);
            foreach (var face in result) _authorizedFaces[(space, face.Id)] = face;
        }
        return result;
    }
    public async Task<byte[]> FaceImageAsync(SynologyPhotoFace face, CancellationToken cancellationToken = default)
    {
        RequirePhoto(face.Photo); RequireCategoryAccess(SynologyPhotoCategory.People, face.Photo.Id.Space); var generation = Volatile.Read(ref _accessGeneration);
        if (face.Thumbnail is not { } thumbnail || !_authorizedFaces.TryGetValue((face.Photo.Id.Space, face.Id), out var known) || known != face)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var bytes = await _api.ReadPhotoThumbnailAsync(_profile, _session, thumbnail, false, cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken); return bytes;
    }
    private async Task<JsonObject> PersonDetailsAsync(long id, SynologyPhotoSpace space, CancellationToken token)
    {
        var list = List(await ReadAsync("Browse.Person", 1, "get", Parameters(("id", new[] { id })), token, space).ConfigureAwait(false));
        if (list.Length != 1 || Positive(list[0], "id") != id) throw Invalid(); return list[0];
    }
    private async Task<SynologyPhoto[]> RecognitionOriginalsAsync(PhotoRecognitionRecord record, CancellationToken token)
    {
        var photos = new List<SynologyPhoto>();
        foreach (var original in record.Photos)
        {
            var fields = Parameters(("id", new[] { original.Id }));
            if (original.Album is { } album) Add(fields, Parameters(("album_id", album.AlbumId), ("additional", new[] { "provider_user_id" })));
            var list = List(await ReadAsync("Browse.Item", 5, "get", fields, token, original.Album is null ? record.Space : null).ConfigureAwait(false));
            if (list.Length != 1) throw Invalid(); var photo = Photo(list[0], ProfileId, record.Space, original.Album?.AlbumId);
            if (photo.Id.ItemId != original.Id || photo.FolderId != original.FolderId || RecognitionPhotoHash(photo) != original.IdentityHash || photo.AlbumContext != original.Album)
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            photos.Add(photo);
        }
        return photos.ToArray();
    }
    public async Task<IReadOnlyList<SynologyPhoto>> RecognitionPhotosAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        await LoadChangesAsync().ConfigureAwait(false); var record = OwnedRecognition(operationId).Record;
        if (!RecognitionUsesPhotos(record.Kind)) throw Invalid(); var generation = Volatile.Read(ref _accessGeneration);
        await FreshRecognitionAccessAsync(ConceptKind(record.Kind) ? SynologyPhotoCategory.Subjects : SynologyPhotoCategory.People, record.Space, cancellationToken).ConfigureAwait(false);
        var photos = await RecognitionOriginalsAsync(record, cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken); CheckRecognitionOwner(record); return photos;
    }
}
