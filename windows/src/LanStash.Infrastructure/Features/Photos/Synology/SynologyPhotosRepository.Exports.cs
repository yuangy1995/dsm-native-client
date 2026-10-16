using System.Collections.Concurrent;
using System.Text.Json.Nodes;
using Windows.Graphics.Imaging;
using LanStash.Domain;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    private readonly ConcurrentDictionary<SynologyPhotoIdentity, byte> _jpegConversions = new();
    private static string DownloadType(SynologyPhotoDownloadFormat format) => format switch
    {
        SynologyPhotoDownloadFormat.Original => "source", SynologyPhotoDownloadFormat.OptimizedJpeg => "optimized_jpeg",
        SynologyPhotoDownloadFormat.OriginalSizeJpeg => "original_size_jpeg", _ => throw Invalid(),
    };

    public async Task<SynologyPhotoDownloadResult> DownloadAsync(SynologyPhoto photo, SynologyPhotoDownloadFormat format, string destination,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        RequirePhoto(photo); _ = DownloadType(format);
        if (photo.SizeBytes < 0 || photo.FolderId <= 0) throw Invalid();
        var generation = Volatile.Read(ref _accessGeneration);
        var capability = Capability("Download", 2, ReadSpace(photo));
        var staging = ExportStaging(destination);
        var converting = format == SynologyPhotoDownloadFormat.OriginalSizeJpeg;
        if (converting && (!SupportsOriginalSizeJpeg || !photo.SupportsOriginalSizeJpeg)) throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
        if (converting && !_jpegConversions.TryAdd(photo.Id, 0)) throw new SynologyPhotoException(SynologyPhotoFailure.UploadBusy);
        try
        {
            await FreshManagementAccessAsync(photo.AlbumContext is null ? [photo.Id.Space] : [], cancellationToken).ConfigureAwait(false);
            var context = await DownloadPhotoContextAsync(photo, cancellationToken).ConfigureAwait(false);
            if (converting)
            {
                var user = await ReadAsync("Setting.User", 1, "get", cancellationToken: cancellationToken, space: null).ConfigureAwait(false);
                var admin = await ReadAsync("Setting.Admin", 1, "get", cancellationToken: cancellationToken, space: null).ConfigureAwait(false);
                if (!Permission(OptionalObject(user, "ame_status"), "has_hevc") || !Permission(admin, "enable_converted_original_jpeg"))
                    throw new SynologyPhotoException(SynologyPhotoFailure.Unavailable);
                RequireGeneration(generation, cancellationToken);
                var conversion = new Dictionary<string, string>(context);
                Add(conversion, Parameters(("item_id", photo.Id.ItemId)));
                // 这是派生缓存转换；仅接受本次明确回执，取消或丢回执后绝不自动重放。
                var receipt = await _api.WritePhotoAsync(_profile, _session, capability, 2, "convert", conversion, cancellationToken).ConfigureAwait(false);
                RequireGeneration(generation, cancellationToken);
                if (receipt.Status != SynologyPhotoWriteStatus.Accepted) throw new SynologyPhotoException(receipt.Failure ?? SynologyPhotoFailure.Media);
            }
            else context = ReadParameters(photo);
            Add(context, Parameters(("item_id", new[] { photo.Id.ItemId }), ("force_download", true), ("download_type", DownloadType(format))));
            RequireGeneration(generation, cancellationToken);
            var binary = await _api.DownloadPhotoAsync(_profile, _session, new(capability, "download", context), staging,
                format == SynologyPhotoDownloadFormat.Original ? photo.SizeBytes : null, false, progress, cancellationToken).ConfigureAwait(false);
            RequireGeneration(generation, cancellationToken);
            if (new FileInfo(staging).Length != binary.Length) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
            var actual = format;
            if (format != SynologyPhotoDownloadFormat.Original)
            {
                await using var input = File.OpenRead(staging);
                var header = new byte[3]; var count = await input.ReadAsync(header, cancellationToken).ConfigureAwait(false);
                if (count == 3 && header.AsSpan().SequenceEqual(new byte[] { 255, 216, 255 }))
                    await ValidateExportJpegAsync(input, cancellationToken).ConfigureAwait(false);
                else if (format == SynologyPhotoDownloadFormat.OptimizedJpeg && !binary.ContentType.Contains("jpeg", StringComparison.OrdinalIgnoreCase) && binary.Length == photo.SizeBytes)
                    actual = SynologyPhotoDownloadFormat.Original;
                else throw new SynologyPhotoException(SynologyPhotoFailure.Media);
            }
            RequireGeneration(generation, cancellationToken);
            File.Move(staging, destination, overwrite: false);
            return new(actual, binary.Length);
        }
        finally
        {
            if (converting) _jpegConversions.TryRemove(photo.Id, out _);
            if (File.Exists(staging)) File.Delete(staging);
        }
    }

    private async Task<Dictionary<string, string>> DownloadPhotoContextAsync(SynologyPhoto photo, CancellationToken token)
    {
        var entries = List(await ReadAsync("Browse.Item", 5, "get", ReadParameters(photo, ("id", new[] { photo.Id.ItemId }),
            ("additional", new[] { "provider_user_id" })), token, ReadSpace(photo)).ConfigureAwait(false));
        if (entries.Length != 1 || !photo.IsSameDeletionTarget(OriginalFilePhoto(entries[0], ProfileId, photo.Id.Space)))
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        if (photo.AlbumContext is { } album)
        {
            if (Number(entries[0], "owner_user_id") != album.OwnerUserId) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var raw = await ReadAlbumRawAsync(album.AlbumId, token).ConfigureAwait(false) ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
            var provider = OptionalObject(entries[0], "additional")?["provider_user_id"];
            var own = provider is JsonValue value && value.TryGetValue<long>(out var id) && id == _currentUserId &&
                (photo.Id.Space == SynologyPhotoSpace.Personal ? _personalAllowed : _sharedAllowed);
            if (own) await FreshManagementAccessAsync([photo.Id.Space], token).ConfigureAwait(false);
            return await DownloadAlbumContextAsync(raw, false, own, token).ConfigureAwait(false);
        }
        _ = await DownloadFolderAsync(photo.FolderId, photo.Id.Space, token).ConfigureAwait(false);
        return [];
    }

    private async Task<Dictionary<string, string>> DownloadAlbumContextAsync(JsonObject album, bool archive, bool ownContribution, CancellationToken token)
    {
        if (_currentUserId is not > 0) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var id = Positive(album, "id");
        if (Positive(album, "owner_user_id") == _currentUserId) return Parameters((archive ? "id" : "album_id", id));
        var sharing = OptionalObject(OptionalObject(album, "additional") ?? new(), "sharing_info");
        var passphrase = OptionalText(album, "passphrase") ?? (sharing is null ? null : OptionalText(sharing, "passphrase"));
        if (string.IsNullOrWhiteSpace(passphrase)) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var payload = await ReadAsync("Sharing.Passphrase", 1, "get_permission", Parameters(("passphrase", passphrase), ("exclude_public", false)), token, null).ConfigureAwait(false);
        if (!Permission(Object(payload["permission"]), "download") && !ownContribution) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return Parameters(("passphrase", passphrase));
    }

    private async Task<SynologyPhotoFolder> DownloadFolderAsync(long id, SynologyPhotoSpace space, CancellationToken token)
    {
        var raw = await ReadPhotoFolderAsync(id, space, PhotoFolderRight.View, token).ConfigureAwait(false);
        var rights = OptionalObject(OptionalObject(raw, "additional") ?? new(), "access_permission");
        if (!(space == SynologyPhotoSpace.Shared && _managesSharedSpace) &&
            (space == SynologyPhotoSpace.Personal ? rights?["download"] is not null && !Boolean(rights, "download") : !Permission(rights, "download")))
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        return PhotoFolder(raw, space);
    }

    public async Task<long> DownloadArchiveAsync(SynologyPhotoArchiveTarget target, SynologyPhotoDownloadFormat format, string destination,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        _ = DownloadType(format); if (format == SynologyPhotoDownloadFormat.OriginalSizeJpeg) throw Invalid();
        var staging = ExportStaging(destination); var generation = Volatile.Read(ref _accessGeneration);
        ApiCapability capability; Dictionary<string, string> parameters;
        switch (target)
        {
            case SynologyPhotoArchiveTarget.Album(var expected):
                RequireAccess(); if (expected.ProfileId != ProfileId) throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
                await FreshManagementAccessAsync([], cancellationToken).ConfigureAwait(false);
                var raw = await ReadAlbumRawAsync(expected.Id, cancellationToken).ConfigureAwait(false) ?? throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                if (!SameAlbumIdentity(expected, AlbumSnapshot(raw))) throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                parameters = await DownloadAlbumContextAsync(raw, true, false, cancellationToken).ConfigureAwait(false);
                capability = Capability("Browse.Album", 2, null); break;
            case SynologyPhotoArchiveTarget.Folder(var folder):
                RequireAccess(folder.Space); ValidatePhotoFolder(folder);
                await FreshManagementAccessAsync([folder.Space], cancellationToken).ConfigureAwait(false);
                if (!SamePhotoFolder(folder, await DownloadFolderAsync(folder.Id, folder.Space, cancellationToken).ConfigureAwait(false)))
                    throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                parameters = Parameters(("folder_id", new[] { folder.Id }), ("force_download", true));
                capability = Capability("Download", 2, folder.Space); break;
            case SynologyPhotoArchiveTarget.Selection(var photos, var folders):
                if (photos is null || folders is not { Count: > 0 } || folders.DistinctBy(value => value.Id).Count() != folders.Count ||
                    photos.DistinctBy(value => value.Id).Count() != photos.Count) throw Invalid();
                var first = folders[0]; RequireAccess(first.Space);
                if (first.ParentId <= 0) throw Invalid();
                await FreshManagementAccessAsync([first.Space], cancellationToken).ConfigureAwait(false);
                foreach (var item in folders)
                {
                    ValidatePhotoFolder(item);
                    if (item.Space != first.Space || item.ParentId != first.ParentId ||
                        !SamePhotoFolder(item, await DownloadFolderAsync(item.Id, item.Space, cancellationToken).ConfigureAwait(false)))
                        throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                }
                foreach (var photo in photos)
                {
                    RequirePhoto(photo);
                    if (photo.Id.Space != first.Space || photo.AlbumContext is not null || photo.FolderId != first.ParentId) throw Invalid();
                }
                if (photos.Count > 0) _ = await DownloadFolderAsync(first.ParentId, first.Space, cancellationToken).ConfigureAwait(false);
                foreach (var batch in photos.Chunk(100))
                {
                    var current = List(await ReadAsync("Browse.Item", 5, "get", Parameters(("id", batch.Select(value => value.Id.ItemId).ToArray())), cancellationToken, first.Space).ConfigureAwait(false));
                    if (current.Length != batch.Length || batch.Any(photo => current.Count(value => photo.IsSameDeletionTarget(OriginalFilePhoto(value, ProfileId, first.Space))) != 1))
                        throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
                }
                parameters = Parameters(("folder_id", folders.Select(value => value.Id).ToArray()), ("force_download", true));
                if (photos.Count > 0) Add(parameters, Parameters(("item_id", photos.Select(value => value.Id.ItemId).ToArray())));
                capability = Capability("Download", 2, first.Space); break;
            default: throw Invalid();
        }
        Add(parameters, Parameters(("download_type", DownloadType(format))));
        RequireGeneration(generation, cancellationToken);
        try
        {
            var binary = await _api.DownloadPhotoAsync(_profile, _session, new(capability, "download", parameters), staging, null, true, progress, cancellationToken).ConfigureAwait(false);
            RequireGeneration(generation, cancellationToken);
            await ValidateExportZipAsync(staging, binary.Length, cancellationToken).ConfigureAwait(false);
            RequireGeneration(generation, cancellationToken);
            File.Move(staging, destination, overwrite: false); return binary.Length;
        }
        finally { if (File.Exists(staging)) File.Delete(staging); }
    }

    private static string ExportStaging(string destination)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(destination);
        if (File.Exists(destination)) throw new IOException("photos.destination-exists");
        return Path.Combine(Path.GetDirectoryName(Path.GetFullPath(destination))!, $".{Guid.NewGuid():N}.photos-download");
    }

    private static async Task ValidateExportJpegAsync(FileStream input, CancellationToken token)
    {
        // Windows 解码器可以容忍截断；完整 EOI 与实际像素解码必须同时满足。
        if (input.Length < 4) throw new SynologyPhotoException(SynologyPhotoFailure.Media);
        input.Position = input.Length - 2;
        if (input.ReadByte() != 255 || input.ReadByte() != 217) throw new SynologyPhotoException(SynologyPhotoFailure.Media);
        input.Position = 0;
        using var stream = input.AsRandomAccessStream();
        try
        {
            var decoder = await BitmapDecoder.CreateAsync(BitmapDecoder.JpegDecoderId, stream).AsTask(token).ConfigureAwait(false);
            using var bitmap = await decoder.GetSoftwareBitmapAsync().AsTask(token).ConfigureAwait(false);
            if (bitmap.PixelWidth <= 0 || bitmap.PixelHeight <= 0) throw new SynologyPhotoException(SynologyPhotoFailure.Media);
        }
        catch (Exception error) when (error is not OperationCanceledException && error is not SynologyPhotoException)
        { throw new SynologyPhotoException(SynologyPhotoFailure.Media); }
    }

    private static async Task ValidateExportZipAsync(string path, long expectedLength, CancellationToken token)
    {
        await using var input = File.OpenRead(path);
        if (input.Length < 22 || input.Length != expectedLength) throw new SynologyPhotoException(SynologyPhotoFailure.LengthMismatch);
        var header = new byte[4]; await input.ReadExactlyAsync(header, token).ConfigureAwait(false);
        if (!DsmApiClient.IsPhotoZipHeader(header)) throw Invalid();
        var tail = new byte[(int)Math.Min(65557, input.Length)]; input.Position = input.Length - tail.Length;
        await input.ReadExactlyAsync(tail, token).ConfigureAwait(false);
        for (var index = tail.Length - 22; index >= 0; index--)
            if (tail[index] == 0x50 && tail[index + 1] == 0x4b && tail[index + 2] == 5 && tail[index + 3] == 6 &&
                index + 22 + tail[index + 20] + (tail[index + 21] << 8) == tail.Length) return;
        throw Invalid();
    }
}
