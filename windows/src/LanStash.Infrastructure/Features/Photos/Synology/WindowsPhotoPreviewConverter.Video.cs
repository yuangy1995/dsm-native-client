using LanStash.Domain;
using Windows.Graphics.Imaging;
using Windows.Media.Core;
using Windows.Media.Editing;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Storage;

namespace LanStash.Infrastructure;

public sealed partial class WindowsPhotoPreviewConverter
{
    public async Task<SynologyPhotoConversionSupport> SupportAsync(CancellationToken cancellationToken = default)
    {
        var query = new CodecQuery();
        async Task<bool> Has(CodecKind kind, CodecCategory category, string subtype) =>
            (await query.FindAllAsync(kind, category, subtype).AsTask(cancellationToken).ConfigureAwait(false)).Count > 0;
        var h264 = await Has(CodecKind.Video, CodecCategory.Encoder, "H264").ConfigureAwait(false);
        var aac = await Has(CodecKind.Audio, CodecCategory.Encoder, "{00001610-0000-0010-8000-00AA00389B71}").ConfigureAwait(false);
        var video = h264 && aac && await Has(CodecKind.Video, CodecCategory.Decoder, "H264").ConfigureAwait(false);
        var heic = BitmapDecoder.GetDecoderInformationEnumerator().Any(codec => codec.FileExtensions.Any(ext => ext.Equals(".heic", StringComparison.OrdinalIgnoreCase)));
        var hevc = heic && video && await Has(CodecKind.Video, CodecCategory.Decoder, "HEVC").ConfigureAwait(false);
        var vc1 = video && await Has(CodecKind.Video, CodecCategory.Decoder, "WVC1").ConfigureAwait(false) &&
            await Has(CodecKind.Video, CodecCategory.Decoder, "WMV3").ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested(); return new(hevc, vc1, video);
    }

    public Task<SynologyPhotoVideoSignature> VideoSignatureAsync(string source, CancellationToken cancellationToken = default) =>
        Task.Run(() => PhotoPreviewVideoSignature.Read(source, cancellationToken), cancellationToken);

    public async Task ConvertVideoAsync(string source, string destination, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested(); var created = false; var complete = false;
        try
        {
            var input = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(source)).AsTask(cancellationToken).ConfigureAwait(false);
            var original = await MediaEncodingProfile.CreateFromFileAsync(input).AsTask(cancellationToken).ConfigureAwait(false);
            if (original.Video is null || original.Video.Width == 0 || original.Video.Height == 0) throw new SynologyPhotoConversionException(true);
            var profile = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p);
            profile.Video.Width = original.Video.Width; profile.Video.Height = original.Video.Height;
            profile.Video.FrameRate.Numerator = original.Video.FrameRate.Numerator; profile.Video.FrameRate.Denominator = original.Video.FrameRate.Denominator;
            profile.Video.PixelAspectRatio.Numerator = original.Video.PixelAspectRatio.Numerator; profile.Video.PixelAspectRatio.Denominator = original.Video.PixelAspectRatio.Denominator;
            // 与缩略图共用系统合成器，把轨道方向落实到画面；输出不重复附加旋转元数据。
            var properties = await input.Properties.GetVideoPropertiesAsync().AsTask(cancellationToken).ConfigureAwait(false);
            if ((int)properties.Orientation is 90 or 270) (profile.Video.Width, profile.Video.Height) = (profile.Video.Height, profile.Video.Width);
            // 极短或静止视频的平均码率并非编码器可接受的目标码率；按原画面大小提供编码预算。
            var frameRate = original.Video.FrameRate.Denominator == 0 ? 30d : (double)original.Video.FrameRate.Numerator / original.Video.FrameRate.Denominator;
            profile.Video.Bitrate = (uint)Math.Clamp(original.Video.Width * (double)original.Video.Height * frameRate * 0.15, 1_000_000, 120_000_000);
            if (original.Audio is null) profile.Audio = null;
            else
            {
                profile.Audio = AudioEncodingProperties.CreateAac(original.Audio.SampleRate, original.Audio.ChannelCount, 192_000);
            }
            // 输出只允许本次新建；取消或系统失败时不留下不完整派生文件。
            for (var attempt = 1; ; attempt++)
            {
                using (new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { created = true; }
                var output = await StorageFile.GetFileFromPathAsync(Path.GetFullPath(destination)).AsTask(cancellationToken).ConfigureAwait(false);
                var composition = new MediaComposition();
                composition.Clips.Add(await MediaClip.CreateFromFileAsync(input).AsTask(cancellationToken).ConfigureAwait(false));
                var result = await composition.RenderToFileAsync(output, MediaTrimmingPreference.Precise, profile).AsTask(cancellationToken).ConfigureAwait(false);
                if (result != TranscodeFailureReason.None)
                {
                    var failure = new SynologyPhotoConversionException(false); failure.Data["TranscodeFailureReason"] = result;
                    throw failure;
                }
                cancellationToken.ThrowIfCancellationRequested();
                // 原生合成偶发忽略已交换的方向而输出横向画面；横竖不符时删除并重试一次，仍不符则不记为损坏媒体。
                var rendered = await MediaEncodingProfile.CreateFromFileAsync(output).AsTask(cancellationToken).ConfigureAwait(false);
                var renderedPortrait = rendered.Video?.Height > rendered.Video?.Width;
                if (renderedPortrait == (profile.Video.Height > profile.Video.Width)) break;
                if (attempt == 2) throw new SynologyPhotoConversionException(false);
                File.Delete(destination);
            }
            PhotoPreviewVideoSignature.RemoveMetadata(destination, cancellationToken);
            var signature = await VideoSignatureAsync(destination, cancellationToken).ConfigureAwait(false);
            if (signature.Tracks.Any(track => track.Formats.Any(format => track.Type == "vide" ? format is not ("avc1" or "avc3") : format != "mp4a")))
                throw new SynologyPhotoConversionException(true);
            cancellationToken.ThrowIfCancellationRequested(); complete = true;
        }
        finally { if (created && !complete) File.Delete(destination); }
    }

    internal static bool ShouldRecordFailure(Exception error) => error is SynologyPhotoConversionException { CanRecordFailure: true } ||
        error is System.Runtime.InteropServices.COMException && unchecked((uint)error.HResult) is 0x88982F60 or 0x88982F61 or 0x88982F70 or 0xC00D36CB;
}
