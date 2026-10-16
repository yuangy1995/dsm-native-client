using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private async Task SendTemporaryStageAsync(PhotoTemporaryTask task, CancellationToken token)
    {
        var sent = false;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration); var record = task.Record;
            var current = await PrepareTemporaryAsync(task, token).ConfigureAwait(false);
            if (record.Stage == SynologyPhotoTemporaryStage.Close && current!.Access == SynologyPhotoLinkAccess.Disabled)
            { await UpdateTemporaryAsync(task, value => value with { Stage = SynologyPhotoTemporaryStage.Delete, State = SynologyPhotoChangeState.Ready, Failure = null }).ConfigureAwait(false); return; }
            var route = record.Stage switch
            {
                SynologyPhotoTemporaryStage.Create => (Api: "Browse.NormalAlbum", Method: "create"),
                SynologyPhotoTemporaryStage.Copy => (Api: "Browse.NormalAlbum", Method: "copy"),
                SynologyPhotoTemporaryStage.Close => (Api: "Sharing.Passphrase", Method: "set_shared"),
                SynologyPhotoTemporaryStage.Delete => (Api: "Browse.Album", Method: "delete"), _ => throw Invalid(),
            };
            var capability = Capability(route.Api, 1, null);
            var fields = record.Stage switch
            {
                SynologyPhotoTemporaryStage.Create => Parameters(("name", task.Name!), ("item", record.Sources.Select(photo => photo.ItemId).ToArray()), ("shared", true)),
                SynologyPhotoTemporaryStage.Copy => Parameters(("name", current!.Album.Name), ("source_album_id", record.AlbumId!.Value)),
                SynologyPhotoTemporaryStage.Close => Parameters(("policy", "album"), ("album_id", record.AlbumId!.Value), ("enabled", false)),
                _ => Parameters(("id", new[] { record.AlbumId!.Value })),
            };
            await UpdateTemporaryAsync(task, value => value with { State = SynologyPhotoChangeState.Submitting, Accepted = false, Failure = null }).ConfigureAwait(false);
            RequireGeneration(generation, token); CheckTemporaryOwner(record);
            await PrepareTemporaryAsync(task, token).ConfigureAwait(false);
            if (record.Stage == SynologyPhotoTemporaryStage.Create && task.Record.CancelRequested)
            { await UpdateTemporaryAsync(task, value => value with { State = SynologyPhotoChangeState.Cancelled, Stage = SynologyPhotoTemporaryStage.Finished }).ConfigureAwait(false); return; }
            sent = true;
            var receipt = await _api.WritePhotoAsync(_profile, _session, capability, 1, route.Method, fields, token).ConfigureAwait(false);
            await UpdateTemporaryAsync(task, value => value with { State = receipt.Status == SynologyPhotoWriteStatus.Rejected ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview,
                Accepted = receipt.Status == SynologyPhotoWriteStatus.Accepted, Failure = receipt.Failure }).ConfigureAwait(false);
            if (receipt.Status == SynologyPhotoWriteStatus.Accepted && record.Stage is SynologyPhotoTemporaryStage.Create or SynologyPhotoTemporaryStage.Copy)
            {
                var id = Positive(Object(receipt.Data?["album"]), "id"); if (record.Stage == SynologyPhotoTemporaryStage.Copy && id == record.AlbumId) throw Invalid();
                await UpdateTemporaryAsync(task, value => record.Stage == SynologyPhotoTemporaryStage.Create ? value with { AlbumId = id } : value with { CopyId = id }).ConfigureAwait(false);
            }
            RequireGeneration(generation, token); CheckTemporaryOwner(record);
            await ReviewTemporaryCoreAsync(task, token).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error))
        {
            RequireManagementStore(); await UpdateTemporaryAsync(task, value => value with
            { State = sent ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, Failure = UploadFailure(error) }).ConfigureAwait(false);
        }
    }
    private async Task ReviewTemporaryCoreAsync(PhotoTemporaryTask task, CancellationToken token)
    {
        var record = task.Record; CheckTemporaryOwner(record);
        if (record.State is not (SynologyPhotoChangeState.PendingReview or SynologyPhotoChangeState.Submitting) || !record.Accepted) return;
        try
        {
            var generation = Volatile.Read(ref _accessGeneration);
            await FreshManagementAccessAsync([SynologyPhotoSpace.Personal], token).ConfigureAwait(false);
            SynologyPhotoSharing? current = null;
            switch (record.Stage)
            {
                case SynologyPhotoTemporaryStage.Create:
                    if (record.AlbumId is null) return;
                    current = await AlbumSharingAsync(record.AlbumId.Value, token).ConfigureAwait(false);
                    if (current.Temporary != true || current.Album.Conditional || current.Album.Frozen || PhotoTextHash(current.Album.Name) != record.NameHash ||
                        TemporaryMembersHash(await TemporaryMembersAsync(record.AlbumId.Value, token).ConfigureAwait(false)) != record.MembersHash) return;
                    break;
                case SynologyPhotoTemporaryStage.Copy:
                    if (!await TemporaryCopyMatchesAsync(record, token).ConfigureAwait(false)) return;
                    current = await RequireTemporarySourceAsync(record, token).ConfigureAwait(false);
                    if (current.Revision != record.Revision) return;
                    break;
                case SynologyPhotoTemporaryStage.Close:
                    current = await RequireTemporarySourceAsync(record, token).ConfigureAwait(false);
                    if (current.Access != SynologyPhotoLinkAccess.Disabled) return;
                    break;
                case SynologyPhotoTemporaryStage.Delete:
                    if (await ReadAlbumRawAsync(record.AlbumId!.Value, token).ConfigureAwait(false) is not null) return;
                    break;
                default: return;
            }
            RequireGeneration(generation, token); CheckTemporaryOwner(record);
            var next = record.Stage switch { SynologyPhotoTemporaryStage.Create => SynologyPhotoTemporaryStage.Configure,
                SynologyPhotoTemporaryStage.Copy => SynologyPhotoTemporaryStage.Close, SynologyPhotoTemporaryStage.Close => SynologyPhotoTemporaryStage.Delete, _ => SynologyPhotoTemporaryStage.Finished };
            task.Result = current; task.Name = null; task.Photos = null;
            await UpdateTemporaryAsync(task, value => value with { Stage = next, State = next == SynologyPhotoTemporaryStage.Finished ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.Ready,
                IdentityHash = current is null ? value.IdentityHash : ShareAlbumIdentity(current), Revision = current?.Revision ?? value.Revision,
                CopyVerified = value.CopyVerified || record.Stage == SynologyPhotoTemporaryStage.Copy, Accepted = false, Failure = null }).ConfigureAwait(false);
        }
        catch (Exception error) when (ManagementError(error)) { RequireManagementStore(); }
    }
}
