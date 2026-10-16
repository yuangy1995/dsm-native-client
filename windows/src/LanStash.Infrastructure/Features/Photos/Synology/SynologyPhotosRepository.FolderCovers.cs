using System.Text.Json.Nodes;
using LanStash.Domain;
using Windows.Graphics.Imaging;
using static LanStash.Infrastructure.SynologyPhotosCodec;

namespace LanStash.Infrastructure;

public sealed partial class SynologyPhotosRepository
{
    public async Task<IReadOnlyList<byte[]>> FolderCoverImagesAsync(SynologyPhotoCollection folder, CancellationToken cancellationToken = default)
    {
        var generation = Volatile.Read(ref _accessGeneration);
        var raw = await ReadPhotoFolderAsync(folder.Id, folder.Space, PhotoFolderRight.View, cancellationToken).ConfigureAwait(false);
        var current = PhotoFolder(raw, folder.Space);
        if (folder.Path is { } path && current.Path != path || folder.ParentId is { } parent && current.ParentId != parent)
            throw new SynologyPhotoException(SynologyPhotoFailure.TargetChanged);
        var images = new List<byte[]>();
        foreach (var cover in OptionalList(OptionalObject(raw, "additional") ?? new(), "thumbnail").Take(4))
        {
            try { images.Add(await ReadFolderCoverAsync(cover, current, cancellationToken).ConfigureAwait(false)); }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) when (ManagementError(error)) { RequireAccess(folder.Space); }
        }
        RequireGeneration(generation, cancellationToken); return images;
    }
    private async Task<byte[]> ReadFolderCoverAsync(JsonObject cover, SynologyPhotoFolder folder, CancellationToken token)
    {
        var sequence = OptionalInt(cover, "folder_cover_seq");
        var thumbnail = new SynologyPhotoThumbnail(sequence is not null ? folder.Id : Positive(cover, "unit_id"), Text(cover, "cache_key"))
        { Space = folder.Space, FolderCoverSequence = sequence };
        var bytes = await _api.ReadPhotoThumbnailAsync(_profile, _session, thumbnail, false, token).ConfigureAwait(false);
        // 使用现有 Windows 解码器实际解码一个缩放像素，不能仅凭 MIME 或图片头声称封面可用。
        try
        {
            using var stream = new MemoryStream(bytes, false); using var random = stream.AsRandomAccessStream();
            var decoder = await BitmapDecoder.CreateAsync(random).AsTask(token).ConfigureAwait(false);
            if (decoder.PixelWidth == 0 || decoder.PixelHeight == 0) throw Invalid();
            _ = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                new BitmapTransform { ScaledWidth = 1, ScaledHeight = 1 }, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage).AsTask(token).ConfigureAwait(false);
        }
        catch (Exception error) when (error is System.Runtime.InteropServices.COMException or ArgumentException or InvalidOperationException)
        { throw new SynologyPhotoException(SynologyPhotoFailure.Media); }
        return bytes;
    }
    private async Task<bool> VerifyFolderCoverAsync(JsonObject raw, SynologyPhotoFolder folder, CancellationToken token)
    {
        var covers = OptionalList(OptionalObject(raw, "additional") ?? new(), "thumbnail").Where(cover => OptionalInt(cover, "folder_cover_seq") == 0).ToArray();
        if (covers.Length != 1) return false;
        _ = await ReadFolderCoverAsync(covers[0], folder, token).ConfigureAwait(false); return true;
    }
}
