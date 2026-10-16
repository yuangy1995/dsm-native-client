using System.Text.Json;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private static string TemporaryMembersHash(IEnumerable<SynologyPhoto> photos) => PhotoTextHash(JsonSerializer.Serialize(photos
        .OrderBy(photo => photo.Id.Space).ThenBy(photo => photo.Id.ItemId).Select(photo => new
        { photo.Id, photo.Filename, photo.SizeBytes, photo.FolderId, photo.IndexedAt })));
    private async Task<IReadOnlyList<SynologyPhoto>> TemporaryMembersAsync(long id, CancellationToken token)
    {
        var result = new List<SynologyPhoto>(); var seen = new HashSet<SynologyPhotoIdentity>();
        for (var offset = 0; ;)
        {
            var page = await PhotosAsync(new SynologyPhotoQuery.Album(id), offset, 100, token).ConfigureAwait(false);
            if (page.Offset != offset || page.NextOffset != offset + page.Items.Count || page.Items.Any(photo => !seen.Add(photo.Id))) throw Invalid();
            result.AddRange(page.Items); if (!page.HasMore) return result;
            if (page.Items.Count == 0) throw Invalid(); offset = page.NextOffset;
        }
    }
    public Task<SynologyPhotoTemporaryChange> CreateTemporarySharingAsync(Guid operationId, string name, IReadOnlyList<SynologyPhoto> photos, CancellationToken cancellationToken = default)
    {
        if (operationId == Guid.Empty || photos.Count is 0 or > 100 || string.IsNullOrWhiteSpace(name) || name.Contains('\0')) throw Invalid();
        var edit = new SynologyPhotoAlbumEdit(SynologyPhotoAlbumEditKind.Create) { Name = name, Photos = photos };
        _ = CreateAlbumRecord(operationId, edit);
        var nameHash = PhotoTextHash(name); var members = TemporaryMembersHash(photos);
        var record = new PhotoTemporaryRecord(operationId, ProfileId, UploadOwner(), PhotoTextHash($"create:{nameHash}:{members}"), true, false,
            nameHash, members, photos.Select(photo => photo.Id).ToArray());
        return RegisterTemporaryAsync(new(record) { Name = name, Photos = photos.ToArray() }, cancellationToken);
    }
    public async Task<SynologyPhotoTemporaryChange> StopTemporarySharingAsync(Guid operationId, SynologyPhotoSharing original, bool keepCopy, CancellationToken cancellationToken = default)
    {
        if (operationId == Guid.Empty || original.Album.ProfileId != ProfileId || original.Temporary != true || original.Album.Conditional || original.Album.Frozen) throw Invalid();
        var generation = Volatile.Read(ref _accessGeneration);
        var members = await TemporaryMembersAsync(original.Album.Id, cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken);
        var record = new PhotoTemporaryRecord(operationId, ProfileId, UploadOwner(), PhotoTextHash($"stop:{original.Album.Id}:{original.Revision}:{keepCopy}"), false,
            keepCopy, PhotoTextHash(original.Album.Name), TemporaryMembersHash(members), members.Select(photo => photo.Id).ToArray(), original.Album.Id,
            ShareAlbumIdentity(original), original.Revision, Stage: keepCopy ? SynologyPhotoTemporaryStage.Copy : SynologyPhotoTemporaryStage.Close);
        return await RegisterTemporaryAsync(new(record), cancellationToken).ConfigureAwait(false);
    }
    private async Task<SynologyPhotoSharing?> PrepareTemporaryAsync(PhotoTemporaryTask task, CancellationToken token)
    {
        var record = task.Record; CheckTemporaryOwner(record); var generation = Volatile.Read(ref _accessGeneration);
        await FreshManagementAccessAsync([SynologyPhotoSpace.Personal], token).ConfigureAwait(false);
        if (record.Stage == SynologyPhotoTemporaryStage.Create)
        {
            if (!SharingSafety.Publish || !SharingSafety.TemporaryCleanup) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
            if (task.Name is null || task.Photos is null) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            _ = Capability("Sharing.Passphrase", 1, null);
            var album = CreateAlbumRecord(record.Id, new(SynologyPhotoAlbumEditKind.Create) { Name = task.Name, Photos = task.Photos });
            await PrepareAlbumCoreAsync(album, token).ConfigureAwait(false);
        }
        else
        {
            if (!SharingSafety.TemporaryCleanup) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
            if (record.Sources.Any(id => RecognitionPhotoBusy(id) || PreviewPhotoBusy(id) || FilePhotoBusy(id) ||
                _changes.Tasks.Values.Any(change => change.Record.Owner == record.Owner && change.Record.Items.Any(item => item.Original.Id == id && item.State is not (SynologyPhotoChangeState.Completed or SynologyPhotoChangeState.Cancelled))) ||
                _changes.Folders.Values.Any(change => change.Record.Owner == record.Owner && ActiveFolderChange(change.Record) && change.Record.Edit.Photo?.Id == id) ||
                _changes.Albums.Values.Any(change => change.Record.Owner == record.Owner && ActiveAlbumChange(change.Record) && change.Record.Edit.Photos.Any(photo => photo.Id == id))))
                throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
            await CheckAlbumBusyAsync(record.AlbumId!.Value, token, record.Id).ConfigureAwait(false);
            await CheckAlbumContentBusyAsync(record.AlbumId.Value, record.Owner, token).ConfigureAwait(false);
            var current = await RequireTemporarySourceAsync(record, token).ConfigureAwait(false);
            if (current.Revision != record.Revision || record.Stage == SynologyPhotoTemporaryStage.Delete && current.Access != SynologyPhotoLinkAccess.Disabled)
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (record.KeepCopy && record.Stage is SynologyPhotoTemporaryStage.Close or SynologyPhotoTemporaryStage.Delete)
            {
                if (!record.CopyVerified || !await TemporaryCopyMatchesAsync(record, token).ConfigureAwait(false)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                await CheckAlbumBusyAsync(record.CopyId!.Value, token, record.Id).ConfigureAwait(false);
                await CheckAlbumContentBusyAsync(record.CopyId.Value, record.Owner, token).ConfigureAwait(false);
                if ((await AlbumSharingAsync(record.AlbumId.Value, token).ConfigureAwait(false)).Revision != record.Revision) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            }
            RequireGeneration(generation, token); CheckTemporaryOwner(record); return current;
        }
        RequireGeneration(generation, token); CheckTemporaryOwner(record); return null;
    }
    private async Task<SynologyPhotoSharing> RequireTemporarySourceAsync(PhotoTemporaryRecord record, CancellationToken token)
    {
        var current = await AlbumSharingAsync(record.AlbumId!.Value, token).ConfigureAwait(false);
        if (current.Temporary != true || current.Album.Conditional || current.Album.Frozen || ShareAlbumIdentity(current) != record.IdentityHash ||
            TemporaryMembersHash(await TemporaryMembersAsync(record.AlbumId.Value, token).ConfigureAwait(false)) != record.MembersHash)
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        return current;
    }
    private async Task<bool> TemporaryCopyMatchesAsync(PhotoTemporaryRecord record, CancellationToken token)
    {
        if (record.CopyId is null || record.CopyId == record.AlbumId) return false;
        var copy = await AlbumSharingAsync(record.CopyId.Value, token).ConfigureAwait(false);
        return copy.Temporary == false && copy.Access == SynologyPhotoLinkAccess.Disabled && !copy.Album.Conditional && !copy.Album.Frozen &&
            PhotoTextHash(copy.Album.Name) == record.NameHash && TemporaryMembersHash(await TemporaryMembersAsync(copy.Album.Id, token).ConfigureAwait(false)) == record.MembersHash;
    }
    private async Task AdvanceTemporaryCancellationAsync(PhotoTemporaryTask task, CancellationToken token)
    {
        var record = task.Record;
        if (!record.CancelRequested || record.State is not (SynologyPhotoChangeState.Ready or SynologyPhotoChangeState.Failed)) return;
        if (record.Stage == SynologyPhotoTemporaryStage.Create)
        { await UpdateTemporaryAsync(task, value => value with { Stage = SynologyPhotoTemporaryStage.Finished, State = SynologyPhotoChangeState.Cancelled }).ConfigureAwait(false); task.Name = null; task.Photos = null; }
        else if (record.Stage == SynologyPhotoTemporaryStage.Configure)
        {
            try
            {
                var current = await RequireTemporarySourceAsync(record, token).ConfigureAwait(false);
                if (current.Revision != record.Revision) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                await UpdateTemporaryAsync(task, value => value with { Stage = SynologyPhotoTemporaryStage.Close, Revision = current.Revision,
                    State = SynologyPhotoChangeState.Ready, Accepted = false, Failure = null }).ConfigureAwait(false);
            }
            catch (Exception error) when (ManagementError(error))
            { RequireManagementStore(); await UpdateTemporaryAsync(task, value => value with { Failure = UploadFailure(error) }).ConfigureAwait(false); }
        }
    }
}
