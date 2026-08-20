using System.Buffers;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    private sealed class ExactLengthMultipartUploadContent : HttpContent
    {
        private const int BufferSize = 64 * 1024;
        private readonly byte[] _prefix;
        private readonly byte[] _suffix;
        private readonly Stream _source;
        private readonly long _sourceLength;
        private readonly IProgress<long>? _progress;
        private readonly long _contentLength;
        private int _serializationStarted;

        public ExactLengthMultipartUploadContent(
            string boundary,
            IReadOnlyList<KeyValuePair<string, string>> fields,
            string fileName,
            Stream source,
            long sourceLength,
            IProgress<long>? progress)
        {
            _source = source;
            _sourceLength = sourceLength;
            _progress = progress;
            _prefix = BuildPrefix(boundary, fields, fileName);
            _suffix = Encoding.UTF8.GetBytes($"\r\n--{boundary}--\r\n");
            _contentLength = checked((long)_prefix.Length + sourceLength + _suffix.Length);
            Headers.ContentType = new MediaTypeHeaderValue("multipart/form-data");
            Headers.ContentType.Parameters.Add(new NameValueHeaderValue("boundary", boundary));
            Headers.ContentLength = _contentLength;
        }

        protected override bool TryComputeLength(out long length)
        {
            length = _contentLength;
            return true;
        }

        protected override Task SerializeToStreamAsync(
            Stream stream,
            TransportContext? context) =>
            SerializeToStreamCoreAsync(stream, CancellationToken.None);

        protected override Task SerializeToStreamAsync(
            Stream stream,
            TransportContext? context,
            CancellationToken cancellationToken) =>
            SerializeToStreamCoreAsync(stream, cancellationToken);

        private async Task SerializeToStreamCoreAsync(
            Stream destination,
            CancellationToken cancellationToken)
        {
            if (Interlocked.Exchange(ref _serializationStarted, 1) != 0)
            {
                throw new InvalidOperationException("upload.automatic_replay_blocked");
            }
            await destination.WriteAsync(_prefix, cancellationToken).ConfigureAwait(false);
            var buffer = ArrayPool<byte>.Shared.Rent(BufferSize);
            try
            {
                long copied = 0;
                _progress?.Report(0);
                while (copied < _sourceLength)
                {
                    var requested = (int)Math.Min(BufferSize, _sourceLength - copied);
                    var read = await _source.ReadAsync(
                        buffer.AsMemory(0, requested),
                        cancellationToken).ConfigureAwait(false);
                    if (read == 0)
                    {
                        throw new EndOfStreamException("upload.source_shorter_than_declared");
                    }
                    await destination.WriteAsync(
                        buffer.AsMemory(0, read),
                        cancellationToken).ConfigureAwait(false);
                    copied += read;
                    _progress?.Report(copied);
                }
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(buffer);
            }
            await destination.WriteAsync(_suffix, cancellationToken).ConfigureAwait(false);
        }

        private static byte[] BuildPrefix(
            string boundary,
            IReadOnlyList<KeyValuePair<string, string>> fields,
            string fileName)
        {
            var builder = new StringBuilder();
            foreach (var (name, value) in fields)
            {
                builder.Append("--").Append(boundary).Append("\r\n")
                    .Append("Content-Disposition: form-data; name=\"")
                    .Append(name).Append("\"\r\n\r\n")
                    .Append(value).Append("\r\n");
            }
            var safeFileName = fileName.Replace('"', '\'');
            builder.Append("--").Append(boundary).Append("\r\n")
                .Append("Content-Disposition: form-data; name=\"file\"; filename=\"")
                .Append(safeFileName).Append("\"\r\n")
                .Append("Content-Type: application/octet-stream\r\n\r\n");
            return Encoding.UTF8.GetBytes(builder.ToString());
        }
    }
}
