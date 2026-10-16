using LanStash.Domain;
using LanStash.Infrastructure;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;
using System.Buffers.Binary;
using Windows.Graphics.Imaging;

namespace LanStash.Tests.Photos;

public sealed class WindowsPhotoAutomaticConverterTests
{
    [Theory]
    [InlineData(0, false)][InlineData(90, false)][InlineData(180, true)][InlineData(270, true)]
    public async Task ActualNativeVideoTranscodesToH264AndLeavesOriginalUntouched(int rotation, bool audio)
    {
        var source = Temp(); var output = Temp();
        try
        {
            await CreateVideo(source, audio, 320, 192); Rotate(source, rotation, 320, 192); var before = await File.ReadAllBytesAsync(source);
            var converter = new WindowsPhotoPreviewConverter(); var support = await converter.SupportAsync();
            Assert.True(support.Video);
            try { await converter.ConvertVideoAsync(source, output); }
            catch (SynologyPhotoConversionException error)
            {
                var inputProfile = await MediaEncodingProfile.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(source));
                throw new InvalidOperationException($"Native conversion failed: {error.Data["TranscodeFailureReason"]}; synthetic video {inputProfile.Video.Subtype} {inputProfile.Video.Width}x{inputProfile.Video.Height}, bitrate {inputProfile.Video.Bitrate}, fps {inputProfile.Video.FrameRate.Numerator}/{inputProfile.Video.FrameRate.Denominator}, aspect {inputProfile.Video.PixelAspectRatio.Numerator}/{inputProfile.Video.PixelAspectRatio.Denominator}; audio {inputProfile.Audio?.Subtype} {inputProfile.Audio?.ChannelCount} {inputProfile.Audio?.SampleRate}");
            }
            catch (System.Runtime.InteropServices.COMException error)
            {
                var properties = await (await StorageFile.GetFileFromPathAsync(source)).Properties.GetVideoPropertiesAsync();
                throw new InvalidOperationException($"Native rotated encoding failed: {error.HResult:X8}, orientation {(int)properties.Orientation}, dimensions {properties.Width}x{properties.Height}");
            }
            var proof = await converter.VideoSignatureAsync(output); Assert.True(proof.IsValid);
            Assert.Contains(proof.Tracks, t => t.Type == "vide" && t.Formats.SequenceEqual(["avc1"]));
            Assert.Equal(audio, proof.Tracks.Any(t => t.Type == "soun" && t.Formats.SequenceEqual(["mp4a"])));
            var profile = await MediaEncodingProfile.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(output));
            Assert.Equal(320u * 192u, profile.Video.Width * profile.Video.Height);
            Assert.Equal(before, await File.ReadAllBytesAsync(source));
            var previews = await converter.ConvertAsync(output, "video"); var originalPreview = await converter.ConvertAsync(source, "video");
            Assert.Equal(await Dimensions(originalPreview.Large), await Dimensions(previews.Large));
            Assert.Equal(rotation is 90 or 270 ? (192u, 320u) : (320u, 192u), await Dimensions(previews.Large));
        }
        finally { File.Delete(source); File.Delete(output); }
    }
    [Fact]
    public async Task SmallNativeVideoNeverUpscalesAndUnsupportedPortraitDoesNotMarkMediaBroken()
    {
        var source = Temp(); var output = Temp(); var converter = new WindowsPhotoPreviewConverter();
        try
        {
            await CreateVideo(source); await converter.ConvertVideoAsync(source, output);
            Assert.Equal((160u, 96u), await Dimensions((await converter.ConvertAsync(output, "video")).Large)); File.Delete(output);
            Rotate(source, 90, 160, 96); var before = await File.ReadAllBytesAsync(source);
            try
            {
                await converter.ConvertVideoAsync(source, output);
                Assert.Equal((96u, 160u), await Dimensions((await converter.ConvertAsync(output, "video")).Large));
            }
            catch (System.Runtime.InteropServices.COMException error) when (unchecked((uint)error.HResult) == 0xC00D6D60)
            {
                // 此机器的原生转换器拒绝该极小竖屏尺寸；能力限制必须保留原件且清除输出。
                Assert.False(WindowsPhotoPreviewConverter.ShouldRecordFailure(error)); Assert.False(File.Exists(output));
            }
            Assert.Equal(before, await File.ReadAllBytesAsync(source));
        }
        finally { File.Delete(source); File.Delete(output); }
    }
    [Fact]
    public async Task ExistingDestinationAndCancellationCannotOverwriteContent()
    {
        var source = Temp(); var output = Temp();
        try
        {
            await CreateVideo(source); await File.WriteAllBytesAsync(output, [10, 20, 30]); var converter = new WindowsPhotoPreviewConverter();
            await Assert.ThrowsAsync<IOException>(() => converter.ConvertVideoAsync(source, output));
            Assert.Equal(new byte[] { 10, 20, 30 }, await File.ReadAllBytesAsync(output));
            using var cts = new CancellationTokenSource(); cts.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => converter.ConvertVideoAsync(source, output, cts.Token));
            Assert.Equal(new byte[] { 10, 20, 30 }, await File.ReadAllBytesAsync(output));
        }
        finally { File.Delete(source); File.Delete(output); }
    }
    [Theory]
    [InlineData(0x88982F60, true)][InlineData(0x88982F61, true)][InlineData(0x88982F70, true)][InlineData(0xC00D36CB, true)]
    [InlineData(0x8007000E, false)][InlineData(0x80070005, false)][InlineData(0xC00D5212, false)][InlineData(0xC00D36C4, false)]
    public void OnlyDocumentedCorruptMediaErrorsCanBeReportedToNas(uint code, bool expected) =>
        Assert.Equal(expected, WindowsPhotoPreviewConverter.ShouldRecordFailure(new System.Runtime.InteropServices.COMException("synthetic", unchecked((int)code))));
    [Fact]
    public void NetworkCancellationStorageAndCapabilityFailuresNeverMarkRemoteMediaBroken()
    {
        foreach (var error in new Exception[] { new OperationCanceledException(), new IOException(), new HttpRequestException(),
            new UnauthorizedAccessException(), new OutOfMemoryException(), new SynologyPhotoConversionException(false) })
            Assert.False(WindowsPhotoPreviewConverter.ShouldRecordFailure(error));
        Assert.True(WindowsPhotoPreviewConverter.ShouldRecordFailure(new SynologyPhotoConversionException(true)));
    }
    private static string Temp() => Path.Combine(Path.GetTempPath(), "LanStash-Video-Test-" + Guid.NewGuid().ToString("N") + ".mp4");
    private static async Task<(uint, uint)> Dimensions(byte[] bytes)
    {
        using var memory = new MemoryStream(bytes); using var stream = memory.AsRandomAccessStream(); var decoder = await BitmapDecoder.CreateAsync(stream);
        return (decoder.OrientedPixelWidth, decoder.OrientedPixelHeight);
    }
    private static void Rotate(string path, int angle, int width, int height)
    {
        var data = File.ReadAllBytes(path); var marker = data.AsSpan().IndexOf("tkhd"u8); Assert.True(marker > 0);
        var matrix = marker + 4 + 40; var unit = 65536; var a = angle is 0 ? unit : angle is 180 ? -unit : 0;
        var b = angle is 90 ? unit : angle is 270 ? -unit : 0;
        var values = new[] { a, b, 0, -b, a, 0, angle is 90 ? height * unit : angle is 180 ? width * unit : 0, angle is 180 ? height * unit : angle is 270 ? width * unit : 0, 0x40000000 };
        for (var i = 0; i < values.Length; i++) BinaryPrimitives.WriteInt32BigEndian(data.AsSpan(matrix + i * 4), values[i]);
        File.WriteAllBytes(path, data);
    }
    private static async Task CreateVideo(string path, bool audio = false, uint width = 160, uint height = 96)
    {
        await File.WriteAllBytesAsync(path, []); var file = await StorageFile.GetFileFromPathAsync(path); var composition = new MediaComposition();
        composition.Clips.Add(MediaClip.CreateFromColor(Windows.UI.Color.FromArgb(255, 255, 0, 0), TimeSpan.FromSeconds(0.4)));
        var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.Vga); profile.Video.Width = width; profile.Video.Height = height;
        var wave = Path.ChangeExtension(path, ".wav");
        try
        {
            if (audio)
            {
                var samples = new byte[44_100 * 2];
                for (var i = 0; i < samples.Length / 2; i++) BinaryPrimitives.WriteInt16LittleEndian(samples.AsSpan(i * 2), (short)(Math.Sin(i * 440 * 2 * Math.PI / 44_100) * 8000));
                using (var writer = new BinaryWriter(File.Create(wave)))
                {
                    writer.Write("RIFF"u8); writer.Write(samples.Length + 36); writer.Write("WAVEfmt "u8); writer.Write(16); writer.Write((short)1); writer.Write((short)1);
                    writer.Write(44_100); writer.Write(88_200); writer.Write((short)2); writer.Write((short)16); writer.Write("data"u8); writer.Write(samples.Length); writer.Write(samples);
                }
                composition.BackgroundAudioTracks.Add(await BackgroundAudioTrack.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(wave)));
            }
            else profile.Audio = null;
            Assert.Equal(TranscodeFailureReason.None, await composition.RenderToFileAsync(file, MediaTrimmingPreference.Precise, profile));
        }
        finally { File.Delete(wave); }
    }
}
