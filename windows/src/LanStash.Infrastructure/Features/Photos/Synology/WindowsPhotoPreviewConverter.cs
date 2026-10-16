using LanStash.Domain;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Editing;
using Windows.Storage;
using Windows.Storage.Streams;

namespace LanStash.Infrastructure;

/// <summary>使用实际 Windows 解码器生成三档 JPEG；保持方向、比例及小图片原尺寸。</summary>
public sealed partial class WindowsPhotoPreviewConverter : ISynologyPhotoPreviewConverter
{
    public async Task<SynologyPhotoConvertedPreview> ConvertAsync(string source, string mediaType, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (mediaType == "photo")
        {
            await using var file = File.OpenRead(source); using var stream = file.AsRandomAccessStream();
            return await ConvertImageAsync(stream, cancellationToken).ConfigureAwait(false);
        }
        if (mediaType != "video") throw new SynologyPhotoException(SynologyPhotoFailure.Media);
        var input = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(source)).AsTask(cancellationToken).ConfigureAwait(false);
        var clip = await MediaClip.CreateFromFileAsync(input).AsTask(cancellationToken).ConfigureAwait(false);
        if (clip.OriginalDuration <= TimeSpan.Zero) throw new SynologyPhotoException(SynologyPhotoFailure.Media);
        var composition = new MediaComposition(); composition.Clips.Add(clip);
        var seconds = Math.Min(clip.OriginalDuration.TotalSeconds > 3 ? 3 : 1, Math.Max(0, clip.OriginalDuration.TotalSeconds - 1d / 30));
        // 不同时强制宽高；系统按轨道方向输出原比例，再与图片共用缩放流程。
        using var frame = await composition.GetThumbnailAsync(TimeSpan.FromSeconds(seconds), 0, 0, VideoFramePrecision.NearestFrame)
            .AsTask(cancellationToken).ConfigureAwait(false);
        return await ConvertImageAsync(frame, cancellationToken).ConfigureAwait(false);
    }

    internal static (uint Width, uint Height) Size(uint width, uint height, uint shortEdge)
    {
        if (width == 0 || height == 0 || shortEdge == 0) throw new SynologyPhotoException(SynologyPhotoFailure.Media);
        var scale = Math.Min(1, (double)shortEdge / Math.Min(width, height));
        var result = ((uint)Math.Max(1, Math.Round(width * scale)), (uint)Math.Max(1, Math.Round(height * scale)));
        if ((long)result.Item1 * result.Item2 > 64 * 1024 * 1024) throw new SynologyPhotoException(SynologyPhotoFailure.Media);
        return result;
    }
    private static async Task<SynologyPhotoConvertedPreview> ConvertImageAsync(IRandomAccessStream stream, CancellationToken token)
    {
        var decoder = await BitmapDecoder.CreateAsync(stream).AsTask(token).ConfigureAwait(false);
        var size = Size(decoder.PixelWidth, decoder.PixelHeight, 1280);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore,
            new BitmapTransform { ScaledWidth = size.Width, ScaledHeight = size.Height, InterpolationMode = BitmapInterpolationMode.Fant },
            ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb).AsTask(token).ConfigureAwait(false);
        return new(await JpegAsync(bitmap, 1280, token).ConfigureAwait(false), await JpegAsync(bitmap, 240, token).ConfigureAwait(false),
            await JpegAsync(bitmap, 320, token).ConfigureAwait(false));
    }
    private static async Task<byte[]> JpegAsync(SoftwareBitmap bitmap, uint shortEdge, CancellationToken token)
    {
        using var output = new InMemoryRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output,
            new Dictionary<string, BitmapTypedValue> { ["ImageQuality"] = new(0.9f, PropertyType.Single) }).AsTask(token).ConfigureAwait(false);
        encoder.SetSoftwareBitmap(bitmap); var size = Size((uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, shortEdge);
        encoder.BitmapTransform.ScaledWidth = size.Width; encoder.BitmapTransform.ScaledHeight = size.Height;
        encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Fant;
        await encoder.FlushAsync().AsTask(token).ConfigureAwait(false);
        if (output.Size is 0 or > DsmApiClient.MaximumPhotoResponseBytes) throw new SynologyPhotoException(SynologyPhotoFailure.Media);
        output.Seek(0); using var reader = new DataReader(output); await reader.LoadAsync((uint)output.Size).AsTask(token).ConfigureAwait(false);
        var bytes = new byte[(int)output.Size]; reader.ReadBytes(bytes); return bytes;
    }
}
