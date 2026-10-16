using LanStash.Domain;
using LanStash.Infrastructure;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using Windows.Storage.Streams;

namespace LanStash.Tests.Photos;

public sealed class WindowsPhotoPreviewConverterTests
{
    [Theory]
    [InlineData(4000, 2000, 2560, 1280, 480, 240, 640, 320)]
    [InlineData(2000, 4000, 1280, 2560, 240, 480, 320, 640)]
    [InlineData(80, 40, 80, 40, 80, 40, 80, 40)]
    public async Task ThreeActualJpegsKeepAspectRatioAndNeverEnlargeSmallImages(int width, int height,
        int largeWidth, int largeHeight, int smallWidth, int smallHeight, int mediumWidth, int mediumHeight)
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".tiff");
        try
        {
            await ImageAsync(path, width, height, 1); var before = await File.ReadAllBytesAsync(path);
            var result = await new WindowsPhotoPreviewConverter().ConvertAsync(path, "photo");
            Assert.Equal((largeWidth, largeHeight), (await Decode(result.Large)).Size);
            Assert.Equal((smallWidth, smallHeight), (await Decode(result.Small)).Size);
            Assert.Equal((mediumWidth, mediumHeight), (await Decode(result.Medium)).Size);
            Assert.Equal(before, await File.ReadAllBytesAsync(path));
        }
        finally { File.Delete(path); }
    }

    [Theory]
    [InlineData(1, 255, 0, 0)][InlineData(2, 0, 255, 0)][InlineData(3, 255, 255, 0)][InlineData(4, 0, 0, 255)]
    [InlineData(5, 255, 0, 0)][InlineData(6, 0, 0, 255)][InlineData(7, 255, 255, 0)][InlineData(8, 0, 255, 0)]
    public async Task EveryExifOrientationIsAppliedToAllThreeOutputs(int orientation, int red, int green, int blue)
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".tiff");
        try
        {
            await ImageAsync(path, 600, 400, (ushort)orientation);
            var result = await new WindowsPhotoPreviewConverter().ConvertAsync(path, "photo");
            foreach (var bytes in new[] { result.Large, result.Small, result.Medium })
            {
                var decoded = await Decode(bytes); Assert.Equal(orientation < 5, decoded.Size.Width > decoded.Size.Height);
                var position = (decoded.Size.Height / 8 * decoded.Size.Width + decoded.Size.Width / 8) * 4;
                Assert.InRange(Math.Abs(decoded.Pixels[position] - blue), 0, 15);
                Assert.InRange(Math.Abs(decoded.Pixels[position + 1] - green), 0, 15);
                Assert.InRange(Math.Abs(decoded.Pixels[position + 2] - red), 0, 15);
            }
        }
        finally { File.Delete(path); }
    }

    [Theory]
    [InlineData(0.4)]
    [InlineData(2)]
    public async Task NativeVideoFrameExtractionWorksForShortAndRegularSyntheticClips(double seconds)
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".mp4");
        try
        {
            await File.WriteAllBytesAsync(path, []); var file = await StorageFile.GetFileFromPathAsync(path);
            var composition = new MediaComposition(); composition.Clips.Add(MediaClip.CreateFromColor(Windows.UI.Color.FromArgb(255, 255, 0, 0), TimeSpan.FromSeconds(seconds)));
            var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.Vga); profile.Video.Width = 160; profile.Video.Height = 96; profile.Audio = null;
            TranscodeFailureReason rendered;
            try { rendered = await composition.RenderToFileAsync(file, MediaTrimmingPreference.Precise, profile); }
            catch (System.Runtime.InteropServices.COMException error) { throw new InvalidOperationException($"Synthetic video render failed: {error.HResult:X8}"); }
            Assert.Equal(TranscodeFailureReason.None, rendered);
            var before = await File.ReadAllBytesAsync(path); var result = await new WindowsPhotoPreviewConverter().ConvertAsync(path, "video");
            foreach (var bytes in new[] { result.Large, result.Small, result.Medium })
            {
                var decoded = await Decode(bytes); Assert.Equal((160, 96), decoded.Size);
                Assert.InRange(decoded.Pixels[2], (byte)235, (byte)255); Assert.InRange(decoded.Pixels[0], (byte)0, (byte)20);
            }
            Assert.Equal(before, await File.ReadAllBytesAsync(path));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public async Task InvalidInputAndCancellationDoNotProduceMedia()
    {
        var converter = new WindowsPhotoPreviewConverter(); using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => converter.ConvertAsync("unused", "photo", cancellation.Token));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => converter.ConvertAsync("unused", "live"));
        Assert.Throws<SynologyPhotoException>(() => WindowsPhotoPreviewConverter.Size(0, 400, 320));
        Assert.Throws<SynologyPhotoException>(() => WindowsPhotoPreviewConverter.Size(uint.MaxValue, 1, 1280));
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".jpg");
        try { await File.WriteAllBytesAsync(path, [255, 216, 255, 217]); await Assert.ThrowsAnyAsync<Exception>(() => converter.ConvertAsync(path, "photo")); }
        finally { File.Delete(path); }
    }

    private static async Task ImageAsync(string path, int width, int height, ushort orientation)
    {
        var pixels = new byte[width * height * 4];
        for (var y = 0; y < height; y++) for (var x = 0; x < width; x++)
        {
            var index = (y * width + x) * 4; var left = x < width / 2; var top = y < height / 2;
            pixels[index] = !top && left ? (byte)255 : (byte)0; pixels[index + 1] = !left ? (byte)255 : (byte)0;
            pixels[index + 2] = top && left || !top && !left ? (byte)255 : (byte)0; pixels[index + 3] = 255;
        }
        await using var file = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite); using var stream = file.AsRandomAccessStream();
        var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.TiffEncoderId, stream);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)width, (uint)height, 96, 96, pixels);
        await encoder.BitmapProperties.SetPropertiesAsync(new BitmapPropertySet { ["System.Photo.Orientation"] = new(orientation, PropertyType.UInt16) }); await encoder.FlushAsync();
    }
    private static async Task<((int Width, int Height) Size, byte[] Pixels)> Decode(byte[] bytes)
    {
        Assert.Equal(new byte[] { 255, 216, 255 }, bytes.Take(3)); Assert.Equal(new byte[] { 255, 217 }, bytes.TakeLast(2));
        using var input = new MemoryStream(bytes); using var stream = input.AsRandomAccessStream(); var decoder = await BitmapDecoder.CreateAsync(BitmapDecoder.JpegDecoderId, stream);
        var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, new BitmapTransform(), ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
        return (((int)decoder.OrientedPixelWidth, (int)decoder.OrientedPixelHeight), data.DetachPixelData());
    }
}
