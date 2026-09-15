using System.Text.Json.Nodes;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public async Task<byte[]> ThumbnailAsync(SynologyPhoto photo, bool large = false, CancellationToken cancellationToken = default)
    {
        RequirePhoto(photo);
        if (photo.Thumbnail is not { UnitId: > 0 } thumbnail) throw Invalid();
        var generation = Volatile.Read(ref _accessGeneration);
        var bytes = await _api.ReadPhotoThumbnailAsync(_profile, _session, thumbnail, large, cancellationToken).ConfigureAwait(false);
        RequireGeneration(generation, cancellationToken);
        return bytes;
    }

    public async Task<SynologyPhoto> DetailsAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        RequirePhoto(photo);
        var payload = await ReadAsync("Browse.Item", 5, "get", Parameters(("id", new[] { photo.Id.ItemId }),
            ("additional", new[] { "description", "tag", "exif", "resolution", "orientation", "gps", "video_meta", "video_convert", "thumbnail", "address", "geocoding_id", "rating", "motion_photo", "person" })), cancellationToken).ConfigureAwait(false);
        var entries = List(payload);
        if (entries.Length != 1) throw Invalid();
        var result = Photo(entries[0], ProfileId);
        if (result.Id != photo.Id) throw Invalid();
        return result;
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
            var payload = await ReadAsync("Browse.Unit", 1, "get", Parameters(("id_item", new[] { id }),
                ("additional", new[] { "orientation", "resolution", "thumbnail", "video_meta", "video_convert" })), cancellationToken).ConfigureAwait(false);
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
            var payload = await ReadAsync("Browse.Item", 5, "get", Parameters(("id", new[] { id }),
                ("additional", new[] { "video_convert" })), cancellationToken).ConfigureAwait(false);
            var entries = List(payload);
            if (entries.Length != 1 || Number(entries[0], "id") != id || Text(entries[0], "type") != "video") throw Invalid();
            entry = entries[0];
        }
        var additional = OptionalObject(entry, "additional");
        var conversions = (additional is null ? [] : OptionalList(additional, "video_convert"))
            .Select(item => Text(item, "quality")).ToHashSet(StringComparer.Ordinal);
        var quality = new[] { "raw", "orig_h264", "high", "medium", "low", "mobile" }.FirstOrDefault(conversions.Contains);
        return quality is null or "raw"
            ? new(Capability("Download", 2), "download", Parameters((type == "unit" ? "unit_id" : "item_id", new[] { id })))
            : new(Capability("Streaming", 2), "streaming", Parameters(("id", id), ("type", type), ("quality", quality), ("use_mov", true)));
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
    {
        RequirePhoto(photo);
        var generation = Volatile.Read(ref _accessGeneration);
        ArgumentException.ThrowIfNullOrWhiteSpace(destination);
        if (File.Exists(destination)) throw new IOException("photos.destination-exists");
        var parent = Path.GetDirectoryName(Path.GetFullPath(destination)) ?? throw Invalid();
        var staging = Path.Combine(parent, $".{Guid.NewGuid():N}.photos-download");
        try
        {
            await _api.DownloadPhotoOriginalAsync(_profile, _session,
                new(Capability("Download", 2), "download", Parameters(("item_id", new[] { photo.Id.ItemId }),
                    ("force_download", true), ("download_type", "source"))), staging, photo.SizeBytes, progress, cancellationToken).ConfigureAwait(false);
            RequireGeneration(generation, cancellationToken);
            // 只有当前会话的完整响应才提升，且绝不覆盖已有目标。
            File.Move(staging, destination, overwrite: false);
        }
        finally { if (File.Exists(staging)) File.Delete(staging); }
    }

    public async Task PrepareDeletionAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        RequirePhoto(photo);
        if (!CanDeleteOriginals) throw new SynologyPhotoException(SynologyPhotoFailure.DeletionUnverified);
        _ = Capability("BackgroundTask.File", 1);
        var generation = Volatile.Read(ref _accessGeneration);
        if (!photo.IsSameDeletionTarget(await DetailsAsync(photo, cancellationToken).ConfigureAwait(false)))
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var payload = await ReadAsync("Browse.Folder", 2, "get", Parameters(("id", photo.FolderId),
            ("additional", new[] { "access_permission" })), cancellationToken).ConfigureAwait(false);
        var folder = Object(payload["folder"]);
        var additional = OptionalObject(folder, "additional");
        var permission = additional is null ? null : OptionalObject(additional, "access_permission");
        if (Number(folder, "id") != photo.FolderId || !Permission(permission, "view") || !Permission(permission, "manage"))
            throw new SynologyPhotoException(SynologyPhotoFailure.DeleteDenied);
        RequireGeneration(generation, cancellationToken);
    }

    public async Task<SynologyPhotoDeletionResult> DeleteAsync(SynologyPhoto photo, Guid operationId,
        CancellationToken cancellationToken = default)
    {
        await _deletionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            RequirePhoto(photo);
            if (operationId == Guid.Empty) throw Invalid();
            if (_operations.TryGetValue(operationId, out var operation) && !operation.IsSameDeletionTarget(photo))
                throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            if (_confirmedDeletions.TryGetValue(photo.Id, out var confirmed) && confirmed.IsSameDeletionTarget(photo))
                return SynologyPhotoDeletionResult.Confirmed;
            if (_pendingDeletions.TryGetValue(photo.Id, out var pending))
            {
                if (!pending.IsSameDeletionTarget(photo)) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                return await ReviewDeletionLockedAsync(photo, cancellationToken).ConfigureAwait(false);
            }
            var generation = Volatile.Read(ref _accessGeneration);
            await PrepareDeletionAsync(photo, cancellationToken).ConfigureAwait(false);
            RequireGeneration(generation, cancellationToken);
            // 在唯一一次发送前保存提交身份。发送后的异常只能核对，绝不自动重放。
            _operations[operationId] = photo;
            _pendingDeletions[photo.Id] = photo;
            try
            {
                _ = await CallAsync("BackgroundTask.File", 1, "delete", Parameters(("item_id", new[] { photo.Id.ItemId }),
                    ("folder_id", Array.Empty<long>())), cancellationToken).ConfigureAwait(false);
                return await ReviewDeletionLockedAsync(photo, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            {
                return SynologyPhotoDeletionResult.PendingReview;
            }
        }
        finally { _deletionGate.Release(); }
    }

    public async Task<SynologyPhotoDeletionResult> ReviewDeletionAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        await _deletionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return await ReviewDeletionLockedAsync(photo, cancellationToken).ConfigureAwait(false); }
        finally { _deletionGate.Release(); }
    }

    private async Task<SynologyPhotoDeletionResult> ReviewDeletionLockedAsync(SynologyPhoto photo, CancellationToken cancellationToken)
    {
        RequirePhoto(photo);
        if (_confirmedDeletions.TryGetValue(photo.Id, out var confirmed) && confirmed.IsSameDeletionTarget(photo))
            return SynologyPhotoDeletionResult.Confirmed;
        if (!_pendingDeletions.TryGetValue(photo.Id, out var pending) || !pending.IsSameDeletionTarget(photo))
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var payload = await ReadAsync("Browse.Item", 5, "get", Parameters(("id", new[] { photo.Id.ItemId })), cancellationToken).ConfigureAwait(false);
        if (List(payload).Length != 0) return SynologyPhotoDeletionResult.PendingReview;
        _pendingDeletions.Remove(photo.Id);
        _confirmedDeletions[photo.Id] = photo;
        return SynologyPhotoDeletionResult.Confirmed;
    }
}
