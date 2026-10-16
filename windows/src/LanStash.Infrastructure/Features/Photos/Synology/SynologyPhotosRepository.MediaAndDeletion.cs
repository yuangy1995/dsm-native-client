using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public async Task<byte[]> ThumbnailAsync(SynologyPhoto photo, bool large = false, CancellationToken cancellationToken = default)
    {
        RequirePhoto(photo);
        if (photo.Thumbnail is not { UnitId: > 0, FolderCoverSequence: null, Type: SynologyPhotoThumbnailType.Unit, NativeSize: false } thumbnail) throw Invalid();
        var generation = Volatile.Read(ref _accessGeneration);
        var bytes = await _api.ReadPhotoThumbnailAsync(_profile, _session, thumbnail with { Space = photo.Id.Space, AlbumId = photo.AlbumContext?.AlbumId }, large, cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken);
        return bytes;
    }

    public async Task<SynologyPhoto> DetailsAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        RequirePhoto(photo);
        var payload = await ReadAsync("Browse.Item", 5, "get", ReadParameters(photo, ("id", new[] { photo.Id.ItemId }),
            ("additional", new[] { "description", "tag", "exif", "resolution", "orientation", "gps", "video_meta", "video_convert", "thumbnail", "address", "geocoding_id", "rating", "motion_photo", "person", "provider_user_id" })), cancellationToken, ReadSpace(photo)).ConfigureAwait(false);
        var entries = List(payload);
        if (entries.Length != 1) throw Invalid();
        var result = Photo(entries[0], ProfileId, photo.Id.Space, photo.AlbumContext?.AlbumId);
        if (result.Id != photo.Id || result.AlbumContext?.OwnerUserId != photo.AlbumContext?.OwnerUserId) throw Invalid();
        return result with { SimilarGroup = result.SimilarGroup ?? photo.SimilarGroup };
    }

    /// <summary>实况只选择唯一视频单元，普通视频只选择服务端实际提供的转换质量。</summary>
    internal async Task<SynologyPhotoMediaRequest> VideoRequestAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        RequirePhoto(photo);
        if (photo.MediaType is not ("video" or "live")) throw Invalid();
        JsonObject entry;
        var id = photo.Id.ItemId;
        var type = "item";
        if (photo.MediaType == "live")
        {
            var payload = await ReadAsync("Browse.Unit", 1, "get", ReadParameters(photo, ("id_item", new[] { id }),
                ("additional", new[] { "orientation", "resolution", "thumbnail", "video_meta", "video_convert" })), cancellationToken, ReadSpace(photo)).ConfigureAwait(false);
            var parents = List(payload);
            if (parents.Length != 1 || Number(parents[0], "id_item") != id) throw Invalid();
            var videos = List(parents[0], "unit").Where(item => Text(item, "live_type") == "video").ToArray();
            if (videos.Length != 1) throw Invalid();
            entry = videos[0];
            id = Positive(entry, "id");
            type = "unit";
        }
        else
        {
            var payload = await ReadAsync("Browse.Item", 5, "get", ReadParameters(photo, ("id", new[] { id }),
                ("additional", new[] { "video_convert" })), cancellationToken, ReadSpace(photo)).ConfigureAwait(false);
            var entries = List(payload);
            if (entries.Length != 1 || Number(entries[0], "id") != id || Text(entries[0], "type") != "video") throw Invalid();
            entry = entries[0];
        }
        var additional = OptionalObject(entry, "additional");
        var conversions = (additional is null ? [] : OptionalList(additional, "video_convert"))
            .Select(item => Text(item, "quality")).ToHashSet(StringComparer.Ordinal);
        var quality = new[] { "raw", "orig_h264", "high", "medium", "low", "mobile" }.FirstOrDefault(conversions.Contains);
        return quality is null or "raw"
            ? new(Capability("Download", 2, ReadSpace(photo)), "download", ReadParameters(photo, (type == "unit" ? "unit_id" : "item_id", new[] { id })))
            : new(Capability("Streaming", 2, ReadSpace(photo)), "streaming", ReadParameters(photo, ("id", id), ("type", type), ("quality", quality), ("use_mov", true)));
    }

    public async Task<IReadOnlyMediaSource> VideoSourceAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        RequirePhoto(photo);
        var generation = Volatile.Read(ref _accessGeneration);
        var request = await VideoRequestAsync(photo, cancellationToken).ConfigureAwait(false);
        var source = await _api.OpenPhotoMediaAsync(_profile, _session, request, cancellationToken).ConfigureAwait(false);
        try { RequireGeneration(generation, cancellationToken); return source; }
        catch { source.Dispose(); throw; }
    }

    public async Task DownloadOriginalAsync(SynologyPhoto photo, string destination, IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
        => _ = await DownloadAsync(photo, SynologyPhotoDownloadFormat.Original, destination, progress, cancellationToken).ConfigureAwait(false);

    public Task PrepareDeletionAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        RequireDeletablePhoto(photo);
        return PrepareFilesAsync(new(SynologyPhotoFileAction.Delete, photo.Id.Space, [photo], []), cancellationToken);
    }

    public async Task<SynologyPhotoDeletionResult> DeleteAsync(SynologyPhoto photo, Guid operationId,
        CancellationToken cancellationToken = default)
    {
        RequireDeletablePhoto(photo); if (operationId == Guid.Empty) throw Invalid();
        await LoadChangesAsync().ConfigureAwait(false);
        if (_changes.Files.ContainsKey(operationId) || _changes.Tasks.ContainsKey(operationId) || _changes.Folders.ContainsKey(operationId) || _changes.Albums.ContainsKey(operationId) || _changes.Sharing.ContainsKey(operationId) || _changes.Temporary.ContainsKey(operationId))
            return SingleDeletionResult(await ChangeFilesAsync(operationId, new(SynologyPhotoFileAction.Delete, photo.Id.Space, [photo], []), cancellationToken).ConfigureAwait(false));
        var prior = FindSingleDeletion(photo);
        if (prior is not null) return SingleDeletionResult(await ReviewFileChangeAsync(prior.Record.Id, cancellationToken).ConfigureAwait(false));
        return SingleDeletionResult(await ChangeFilesAsync(operationId, new(SynologyPhotoFileAction.Delete, photo.Id.Space, [photo], []), cancellationToken).ConfigureAwait(false));
    }

    public async Task<SynologyPhotoDeletionResult> ReviewDeletionAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        RequireDeletablePhoto(photo); await LoadChangesAsync().ConfigureAwait(false);
        var task = FindSingleDeletion(photo) ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        return SingleDeletionResult(await ReviewFileChangeAsync(task.Record.Id, cancellationToken).ConfigureAwait(false));
    }
    private PhotoFileChangeTask? FindSingleDeletion(SynologyPhoto photo)
    {
        var matches = _changes.Files.Values.Where(task => task.Record.Owner == UploadOwner() && task.Record.Command.Action == SynologyPhotoFileAction.Delete &&
            task.Record.State != SynologyPhotoFileState.Cancelled && task.Record.Command.Folders.Count == 0 && task.Record.Command.Photos.Count == 1 &&
            task.Record.Command.Photos[0].Id == photo.Id).ToArray();
        if (matches.Any(task => !task.Record.Command.Photos[0].IsSameDeletionTarget(photo))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        return matches.FirstOrDefault(task => ActiveFileChange(task.Record)) ?? matches.FirstOrDefault();
    }
    private static SynologyPhotoDeletionResult SingleDeletionResult(SynologyPhotoFileChange change) => change.State switch
    {
        SynologyPhotoFileState.Completed => SynologyPhotoDeletionResult.Confirmed,
        SynologyPhotoFileState.Failed => throw new SynologyPhotoException(change.Failure ?? SynologyPhotoFailure.WriteFailed),
        SynologyPhotoFileState.Partial or SynologyPhotoFileState.Cancelled => throw new SynologyPhotoException(SynologyPhotoFailure.WriteFailed),
        _ => SynologyPhotoDeletionResult.PendingReview,
    };
}
