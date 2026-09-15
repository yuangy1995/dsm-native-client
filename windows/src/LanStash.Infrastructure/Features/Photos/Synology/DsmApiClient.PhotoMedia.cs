using System.Net;
using System.Net.Http.Headers;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public async Task<IReadOnlyMediaSource> OpenPhotoMediaAsync(NasProfile profile, DsmSession session,
        SynologyPhotoMediaRequest media, CancellationToken cancellationToken = default)
    {
        ValidatePhotoSession(profile, session);
        var uri = PhotoMediaUri(profile, media);
        using var request = PhotoRequest(profile, session, HttpMethod.Get, uri, "video/*, application/octet-stream");
        request.Headers.Range = new RangeHeaderValue(0, PhotoRangeSource.InitialBytes - 1);
        using var response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        ValidatePhotoResponse(response, HttpStatusCode.PartialContent);
        ValidatePhotoBinaryType(response);
        var range = response.Content.Headers.ContentRange;
        if (range?.From != 0 || range.Length is not > 0 || range.To != Math.Min(range.Length.Value, PhotoRangeSource.InitialBytes) - 1)
            throw PhotoMediaFailure();
        var bytes = await ReadBoundedPhotoBodyAsync(response.Content, PhotoRangeSource.InitialBytes, cancellationToken).ConfigureAwait(false);
        if (bytes.LongLength != range.To.Value + 1 || IsPhotoErrorBody(bytes)) throw PhotoMediaFailure();
        var type = response.Content.Headers.ContentType?.MediaType ?? "application/octet-stream";
        if (!type.StartsWith("video/", StringComparison.OrdinalIgnoreCase)) type = PhotoRangeSource.DetectVideoType(bytes);
        cancellationToken.ThrowIfCancellationRequested();
        return new PhotoRangeSource(this, profile, session, uri, range.Length.Value, type,
            response.Headers.ETag?.ToString(), response.Content.Headers.LastModified, bytes);
    }

    /// <summary>共享会话只保留首块，最多两条有界 Range 请求；关闭会立即取消全部读取。</summary>
    private sealed class PhotoRangeSource(DsmApiClient owner, NasProfile profile, DsmSession session, Uri uri,
        long length, string contentType, string? entityTag, DateTimeOffset? lastModified, byte[] initial) : IReadOnlyMediaSource
    {
        internal const int InitialBytes = 64 * 1024;
        private const int MaximumRangeBytes = 4 * 1024 * 1024;
        private readonly CancellationTokenSource _lifetime = new();
        private readonly SemaphoreSlim _concurrency = new(2, 2);
        private byte[]? _initial = initial;
        private int _closed;
        public long Length { get; } = length;
        public string ContentType { get; } = contentType;

        public async Task<byte[]> ReadAsync(long offset, int count, CancellationToken cancellationToken = default)
        {
            if (Volatile.Read(ref _closed) != 0) throw new ObjectDisposedException(nameof(PhotoRangeSource));
            if (offset < 0 || offset > Length || count < 0) throw new ArgumentOutOfRangeException(nameof(offset));
            if (offset == Length || count == 0) return [];
            count = (int)Math.Min(Math.Min(count, MaximumRangeBytes), Length - offset);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _lifetime.Token);
            linked.Token.ThrowIfCancellationRequested();
            var cached = _initial;
            if (cached is not null && offset + count <= cached.LongLength)
                return cached.AsSpan(checked((int)offset), count).ToArray();
            await _concurrency.WaitAsync(linked.Token).ConfigureAwait(false);
            try
            {
                using var request = PhotoRequest(profile, session, HttpMethod.Get, uri, "video/*, application/octet-stream");
                request.Headers.Range = new RangeHeaderValue(offset, checked(offset + count - 1));
                if (entityTag is not null && EntityTagHeaderValue.TryParse(entityTag, out var tag) && !tag.IsWeak)
                    request.Headers.IfRange = new RangeConditionHeaderValue(tag);
                else if (lastModified is not null) request.Headers.IfRange = new RangeConditionHeaderValue(lastModified.Value);
                using var response = await owner._http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, linked.Token).ConfigureAwait(false);
                ValidatePhotoResponse(response, HttpStatusCode.PartialContent);
                ValidatePhotoBinaryType(response);
                var range = response.Content.Headers.ContentRange;
                if (range?.From != offset || range.To != offset + count - 1 || range.Length != Length ||
                    (entityTag is not null && response.Headers.ETag?.ToString() != entityTag) ||
                    (lastModified is not null && response.Content.Headers.LastModified != lastModified)) throw PhotoMediaFailure();
                var bytes = await ReadBoundedPhotoBodyAsync(response.Content, count, linked.Token).ConfigureAwait(false);
                if (bytes.Length != count) throw PhotoMediaFailure();
                linked.Token.ThrowIfCancellationRequested();
                return bytes;
            }
            finally { _concurrency.Release(); }
        }

        internal static string DetectVideoType(ReadOnlySpan<byte> bytes)
        {
            if (bytes.Length >= 12 && bytes[4..8].SequenceEqual("ftyp"u8)) return "video/mp4";
            if (bytes.Length >= 8 && (bytes[4..8].SequenceEqual("moov"u8) || bytes[4..8].SequenceEqual("mdat"u8) || bytes[4..8].SequenceEqual("wide"u8)))
                return "video/quicktime";
            if (bytes.Length >= 4 && bytes[..4].SequenceEqual(new byte[] { 0x1a, 0x45, 0xdf, 0xa3 })) return "video/webm";
            if (bytes.Length >= 12 && bytes[..4].SequenceEqual("RIFF"u8) && bytes[8..12].SequenceEqual("AVI "u8)) return "video/x-msvideo";
            if (bytes.Length >= 4 && bytes[..4].SequenceEqual("OggS"u8)) return "video/ogg";
            throw PhotoMediaFailure();
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _closed, 1) != 0) return;
            _lifetime.Cancel();
            _initial = null;
            // 在途读取的 finally 仍需 Release，不在这里销毁同步基元。
        }
    }
}
