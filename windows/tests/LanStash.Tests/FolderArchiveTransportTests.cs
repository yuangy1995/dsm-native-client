using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class FolderArchiveTransportTests
{
    private static readonly Guid ProfileId =
        Guid.Parse("11111111-1111-1111-1111-111111111111");

    [Fact]
    public async Task RepositoryReaderUsesOfficialDownloadRequestAndConnectionContext()
    {
        var payload = ZipPayload(32);
        HttpMethod? method = null;
        Uri? requestUri = null;
        string? range = null;
        string? token = null;
        Guid? contextProfile = null;
        DsmConnectionSource? contextSource = null;
        using var handler = new StubHttpMessageHandler((request, _) =>
        {
            method = request.Method;
            requestUri = request.RequestUri;
            range = request.Headers.Range?.ToString();
            token = Assert.Single(request.Headers.GetValues("X-SYNO-TOKEN"));
            if (WindowsCertificateTrustHandler.TryGetConnectionContext(
                    request,
                    out var profileId,
                    out var source))
            {
                contextProfile = profileId;
                contextSource = source;
            }
            return Task.FromResult(ArchiveResponse(payload, "application/zip"));
        });
        using var http = new HttpClient(handler);
        IFileArchiveReader reader = new DsmRepository(
            Profile(),
            Session(),
            new DsmApiClient(http),
            new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
            {
                ["SYNO.FileStation.Download"] = Capability(),
            });
        using var forwarded = new MemoryStream();

        await reader.StreamFolderArchiveAsync(
            "/synthetic/folder",
            (chunk, cancellationToken) => forwarded.WriteAsync(chunk, cancellationToken));

        Assert.Equal(HttpMethod.Get, method);
        Assert.NotNull(requestUri);
        Assert.Equal("/webapi/entry.cgi", requestUri!.AbsolutePath);
        var query = ParseQuery(requestUri.Query);
        Assert.Equal("SYNO.FileStation.Download", query["api"]);
        Assert.Equal("2", query["version"]);
        Assert.Equal("download", query["method"]);
        Assert.Equal("download", query["mode"]);
        Assert.Equal(
            new[] { "/synthetic/folder" },
            JsonSerializer.Deserialize<string[]>(query["path"]));
        Assert.Null(range);
        Assert.Equal("synthetic-token", token);
        Assert.Equal(ProfileId, contextProfile);
        Assert.Equal(DsmConnectionSource.DirectAddress, contextSource);
        Assert.Equal(payload, forwarded.ToArray());
    }

    [Fact]
    public async Task HigherAdvertisedVersionStillUsesFrozenV2()
    {
        Uri? requestUri = null;
        using var handler = new StubHttpMessageHandler((request, _) =>
        {
            requestUri = request.RequestUri;
            return Task.FromResult(ArchiveResponse(ZipPayload(8), "application/zip"));
        });
        using var http = new HttpClient(handler);

        await new DsmApiClient(http).StreamFolderArchiveAsync(
            Profile(),
            Session(),
            Capability() with { MaxVersion = 3 },
            "/synthetic/folder",
            (_, _) => ValueTask.CompletedTask);

        Assert.Equal("2", ParseQuery(requestUri!.Query)["version"]);
    }

    [Fact]
    public async Task MissingV2FailsBeforeSendingOrWriting()
    {
        var requests = 0;
        var writes = 0;
        using var handler = new StubHttpMessageHandler((_, _) =>
        {
            requests++;
            return Task.FromResult(ArchiveResponse(ZipPayload(8), "application/zip"));
        });
        using var http = new HttpClient(handler);

        var error = await Assert.ThrowsAsync<FileArchiveContractException>(() =>
            new DsmApiClient(http).StreamFolderArchiveAsync(
                Profile(),
                Session(),
                Capability() with { MinVersion = 3, MaxVersion = 3 },
                "/synthetic/folder",
                (_, _) =>
                {
                    writes++;
                    return ValueTask.CompletedTask;
                }));

        Assert.Equal(FileArchiveContractFailure.UnsupportedVersion, error.Failure);
        Assert.Equal(0, requests);
        Assert.Equal(0, writes);
    }

    [Theory]
    [InlineData("application/zip")]
    [InlineData("application/octet-stream")]
    public async Task AcceptedArchiveMediaTypesForwardChunkedStreamCompletely(string mediaType)
    {
        var payload = ZipPayload(DsmApiClient.FolderArchiveChunkSize + 257);
        using var handler = new StubHttpMessageHandler((request, _) =>
        {
            Assert.Null(request.Headers.Range);
            return Task.FromResult(ArchiveResponse(
                new ChunkedReadStream(payload, maximumRead: 137),
                mediaType));
        });
        using var http = new HttpClient(handler);
        var writes = new List<byte[]>();

        await new DsmApiClient(http).StreamFolderArchiveAsync(
            Profile(),
            Session(),
            Capability(),
            "/synthetic/folder",
            (chunk, _) =>
            {
                writes.Add(chunk.ToArray());
                return ValueTask.CompletedTask;
            });

        Assert.True(writes.Count > 2);
        Assert.Equal(payload, writes.SelectMany(chunk => chunk).ToArray());
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.InternalServerError)]
    public async Task NonSuccessStatusFailsBeforeAnyWrite(HttpStatusCode statusCode)
    {
        var response = ArchiveResponse(ZipPayload(16), "application/zip", statusCode);

        var error = await AssertRejectedBeforeWriteAsync(response);

        Assert.Equal(FileArchiveContractFailure.UnexpectedStatus, error.Failure);
        Assert.Equal((int)statusCode, error.StatusCode);
    }

    [Theory]
    [InlineData("application/json")]
    [InlineData("text/plain")]
    public async Task JsonOrOtherMediaTypeFailsBeforeAnyWrite(string mediaType)
    {
        var response = ArchiveResponse(
            Encoding.UTF8.GetBytes("{\"success\":false}"),
            mediaType);

        var error = await AssertRejectedBeforeWriteAsync(response);

        Assert.Equal(FileArchiveContractFailure.UnexpectedMediaType, error.Failure);
    }

    [Fact]
    public async Task EmptyResponseFailsBeforeAnyWrite()
    {
        var error = await AssertRejectedBeforeWriteAsync(
            ArchiveResponse([], "application/zip"));

        Assert.Equal(FileArchiveContractFailure.EmptyResponse, error.Failure);
    }

    [Theory]
    [MemberData(nameof(InvalidZipPrefixes))]
    public async Task InvalidZipSignatureFailsBeforeAnyWrite(byte[] payload)
    {
        var error = await AssertRejectedBeforeWriteAsync(
            ArchiveResponse(payload, "application/zip"));

        Assert.Equal(FileArchiveContractFailure.InvalidZipSignature, error.Failure);
    }

    [Fact]
    public async Task CancellationAfterFirstWriteStopsAllSubsequentWrites()
    {
        var payload = ZipPayload(64);
        using var handler = new StubHttpMessageHandler((_, _) =>
            Task.FromResult(ArchiveResponse(
                new ChunkedReadStream(payload, maximumRead: 8),
                "application/zip")));
        using var http = new HttpClient(handler);
        using var cancellation = new CancellationTokenSource();
        var writes = new List<byte[]>();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new DsmApiClient(http).StreamFolderArchiveAsync(
                Profile(),
                Session(),
                Capability(),
                "/synthetic/folder",
                (chunk, _) =>
                {
                    writes.Add(chunk.ToArray());
                    cancellation.Cancel();
                    return ValueTask.CompletedTask;
                },
                cancellation.Token));

        var first = Assert.Single(writes);
        Assert.Equal(payload[..4], first);
    }

    public static TheoryData<byte[]> InvalidZipPrefixes => new()
    {
        new byte[] { 0x50 },
        new byte[] { 0x50, 0x4B, 0x03 },
        new byte[] { 0x50, 0x4B, 0x01, 0x02, 0x00 },
        new byte[] { 0x7B, 0x22, 0x65, 0x72, 0x72, 0x6F, 0x72 },
    };

    private static async Task<FileArchiveContractException> AssertRejectedBeforeWriteAsync(
        HttpResponseMessage response)
    {
        using var handler = new StubHttpMessageHandler((_, _) => Task.FromResult(response));
        using var http = new HttpClient(handler);
        var writes = 0;

        var error = await Assert.ThrowsAsync<FileArchiveContractException>(() =>
            new DsmApiClient(http).StreamFolderArchiveAsync(
                Profile(),
                Session(),
                Capability(),
                "/synthetic/folder",
                (_, _) =>
                {
                    writes++;
                    return ValueTask.CompletedTask;
                }));

        Assert.Equal(0, writes);
        return error;
    }

    private static HttpResponseMessage ArchiveResponse(
        byte[] payload,
        string mediaType,
        HttpStatusCode statusCode = HttpStatusCode.OK) =>
        ArchiveResponse(new MemoryStream(payload, writable: false), mediaType, statusCode);

    private static HttpResponseMessage ArchiveResponse(
        Stream payload,
        string mediaType,
        HttpStatusCode statusCode = HttpStatusCode.OK)
    {
        var content = new StreamContent(payload);
        content.Headers.ContentType = new MediaTypeHeaderValue(mediaType);
        return new HttpResponseMessage(statusCode) { Content = content };
    }

    private static Dictionary<string, string> ParseQuery(string query) =>
        query.TrimStart('?')
            .Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.Split('=', 2))
            .ToDictionary(
                part => Uri.UnescapeDataString(part[0]),
                part => Uri.UnescapeDataString(part[1]),
                StringComparer.Ordinal);

    private static byte[] ZipPayload(int length)
    {
        var payload = Enumerable.Range(0, Math.Max(length, 4))
            .Select(index => (byte)(index % 251))
            .ToArray();
        payload[0] = 0x50;
        payload[1] = 0x4B;
        payload[2] = 0x03;
        payload[3] = 0x04;
        return payload;
    }

    private static NasProfile Profile() =>
        new(ProfileId, "Synthetic NAS", "nas.invalid", 5001, "tester");

    private static DsmSession Session() =>
        new(ProfileId, "synthetic-sid", "synthetic-token", null);

    private static ApiCapability Capability() =>
        new("SYNO.FileStation.Download", "entry.cgi", 1, 2, "FORM");

    private sealed class StubHttpMessageHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> response) :
        HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => response(request, cancellationToken);
    }

    private sealed class ChunkedReadStream(byte[] bytes, int maximumRead) : Stream
    {
        private int _position;

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => bytes.Length;
        public override long Position
        {
            get => _position;
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            var length = Math.Min(Math.Min(count, maximumRead), bytes.Length - _position);
            if (length <= 0)
            {
                return 0;
            }
            bytes.AsSpan(_position, length).CopyTo(buffer.AsSpan(offset, length));
            _position += length;
            return length;
        }

        public override ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var length = Math.Min(
                Math.Min(buffer.Length, maximumRead),
                bytes.Length - _position);
            if (length <= 0)
            {
                return ValueTask.FromResult(0);
            }
            bytes.AsMemory(_position, length).CopyTo(buffer);
            _position += length;
            return ValueTask.FromResult(length);
        }

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();
    }
}
