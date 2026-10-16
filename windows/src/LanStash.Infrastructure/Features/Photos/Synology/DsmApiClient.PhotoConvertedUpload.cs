using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public Task<SynologyPhotoWriteReceipt> UploadPhotoPreviewAsync(NasProfile profile, DsmSession session, ApiCapability capability,
        long unitId, SynologyPhotoConvertedPreview preview, CancellationToken cancellationToken = default)
        => UploadPhotoConvertedMediaAsync(profile, session, capability, unitId, preview, null, cancellationToken);

    public async Task<SynologyPhotoWriteReceipt> UploadPhotoConvertedMediaAsync(NasProfile profile, DsmSession session, ApiCapability capability,
        long unitId, SynologyPhotoConvertedPreview? preview, string? video, CancellationToken cancellationToken = default)
    {
        ValidatePhotoSession(profile, session); ValidatePhotoCapability(capability, 3);
        if (capability.Name is not ("SYNO.Foto.Upload.ConvertedFile" or "SYNO.FotoTeam.Upload.ConvertedFile") || unitId <= 0 || preview is null && video is null ||
            preview is not null && new[] { preview.Large, preview.Small, preview.Medium }.Any(bytes => bytes is not { Length: >= 5 and <= MaximumPhotoResponseBytes } ||
                bytes[0] != 255 || bytes[1] != 216 || bytes[2] != 255 || bytes[^2] != 255 || bytes[^1] != 217)) throw SynologyPhotosCodec.Invalid();
        using var multipart = new MultipartFormDataContent("LanStash-Preview-" + Guid.NewGuid().ToString("N"));
        foreach (var (key, value) in new[] { ("api", capability.Name), ("method", "upload"), ("version", "3"), ("unit_id", unitId.ToString(CultureInfo.InvariantCulture)) })
            multipart.Add(new StringContent(value), key);
        if (preview is not null) foreach (var (key, value) in new[] { ("thumb_xl", preview.Large), ("thumb_sm", preview.Small), ("thumb_m", preview.Medium) })
        {
            var part = new ByteArrayContent(value); part.Headers.ContentType = new MediaTypeHeaderValue("image/jpeg");
            multipart.Add(part, key, key + ".jpg");
        }
        if (video is not null)
        {
            var stream = new FileStream(video, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
            if (stream.Length <= 0) { stream.Dispose(); throw SynologyPhotosCodec.Invalid(); }
            var part = new StreamContent(stream, 64 * 1024); part.Headers.ContentType = new MediaTypeHeaderValue("video/mp4");
            part.Headers.ContentLength = stream.Length; multipart.Add(part, "film_h264", "preview.mp4");
        }
        using var request = PhotoRequest(profile, session, HttpMethod.Post, ResolveSafeApiUri(profile, capability.Path), "application/json");
        request.Content = new PhotoConvertedMultipartContent(multipart);
        SetNasConnectionContext(request, profile); cancellationToken.ThrowIfCancellationRequested();
        return await SendPhotoWriteAsync(request, cancellationToken, strictReceipt: true).ConfigureAwait(false);
    }

    /// <summary>转换内容只能发送一次；HTTP 重定向或处理程序不能自动重放未知上传。</summary>
    private sealed class PhotoConvertedMultipartContent : HttpContent
    {
        private readonly MultipartFormDataContent _body; private int _started;
        internal PhotoConvertedMultipartContent(MultipartFormDataContent body)
        {
            _body = body; Headers.ContentType = body.Headers.ContentType; Headers.ContentLength = body.Headers.ContentLength;
        }
        protected override bool TryComputeLength(out long length) { length = _body.Headers.ContentLength ?? 0; return _body.Headers.ContentLength is not null; }
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => SerializeAsync(stream, CancellationToken.None);
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context, CancellationToken cancellationToken) => SerializeAsync(stream, cancellationToken);
        private Task SerializeAsync(Stream stream, CancellationToken token)
        {
            if (Interlocked.Exchange(ref _started, 1) != 0) throw new InvalidOperationException("photos.preview.replay-blocked");
            return _body.CopyToAsync(stream, token);
        }
        protected override void Dispose(bool disposing) { if (disposing) _body.Dispose(); base.Dispose(disposing); }
    }
}
