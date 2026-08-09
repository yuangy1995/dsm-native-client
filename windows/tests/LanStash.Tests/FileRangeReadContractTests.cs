using System.Net;
using System.Net.Http.Headers;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class FileRangeReadContractTests
{
    [Fact]
    public async Task RepositoryExposesTypedRangeContractWithoutDroppingExpectations()
    {
        var api = new RecordingRangeApiClient();
        IDsmRepository repository = new DsmRepository(
            Profile(),
            Session(),
            api,
            new Dictionary<string, ApiCapability>
            {
                ["SYNO.FileStation.Download"] = Capability(),
            });

        var result = await repository.ReadFileRangeResultAsync(
            "/shared/example.bin",
            28,
            4,
            "\"version-1\"",
            32);

        Assert.Equal("/shared/example.bin", api.RemotePath);
        Assert.Equal(28, api.Offset);
        Assert.Equal(4, api.Length);
        Assert.Equal("\"version-1\"", api.ExpectedContentVersion);
        Assert.Equal(32, api.ExpectedTotalLength);
        Assert.Equal(32, result.TotalLength);
    }

    [Fact]
    public async Task Valid206ReturnsTypedRangeAndStrongVersion()
    {
        using var handler = new StubHttpMessageHandler(request =>
        {
            Assert.Equal(new RangeHeaderValue(8, 11).ToString(), request.Headers.Range?.ToString());
            return RangeResponse(8, 11, 32, [1, 2, 3, 4], "\"version-1\"");
        });
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var result = await client.ReadFileRangeResultAsync(
            Profile(),
            Session(),
            Capability(),
            "/shared/example.bin",
            8,
            4);

        Assert.Equal(206, result.StatusCode);
        Assert.Equal(8, result.RequestedStart);
        Assert.Equal(4, result.RequestedLength);
        Assert.Equal(8, result.ResponseStart);
        Assert.Equal(4, result.ResponseLength);
        Assert.Equal(32, result.TotalLength);
        Assert.Equal(4, result.ActualByteCount);
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, result.Bytes);
        Assert.Equal("\"version-1\"", result.ServerContentVersion);
        Assert.True(result.CanSafelyReadInSegments);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("W/\"weak-version\"")]
    public async Task MissingOrWeakVersionCannotBeUsedForSafeSegments(string? entityTag)
    {
        using var handler = new StubHttpMessageHandler(_ =>
            RangeResponse(0, 3, 12, [1, 2, 3, 4], entityTag));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var result = await client.ReadFileRangeResultAsync(
            Profile(), Session(), Capability(), "/shared/example.bin", 0, 4);

        Assert.Null(result.ServerContentVersion);
        Assert.False(result.CanSafelyReadInSegments);
    }

    [Fact]
    public async Task FullResponseIsRejectedInsteadOfSkippingClientSide()
    {
        using var handler = new StubHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new ByteArrayContent([0, 1, 2, 3]),
        });
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(), Session(), Capability(), "/shared/example.bin", 8, 4));

        Assert.Equal(FileRangeContractFailure.UnexpectedStatus, error.Failure);
        Assert.Equal(200, error.StatusCode);
    }

    [Fact]
    public async Task MissingContentRangeIsRejected()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.PartialContent)
            {
                Content = new ByteArrayContent([1, 2, 3, 4]),
            });
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(), Session(), Capability(), "/shared/example.bin", 8, 4));

        Assert.Equal(FileRangeContractFailure.MissingContentRange, error.Failure);
    }

    [Fact]
    public async Task ContentRangeWithoutTotalLengthIsRejected()
    {
        using var handler = new StubHttpMessageHandler(_ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.PartialContent)
            {
                Content = new ByteArrayContent([1, 2, 3, 4]),
            };
            response.Content.Headers.ContentRange = new ContentRangeHeaderValue(8, 11);
            return response;
        });
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(), Session(), Capability(), "/shared/example.bin", 8, 4));

        Assert.Equal(FileRangeContractFailure.MissingContentRange, error.Failure);
    }

    [Fact]
    public async Task WrongResponseStartIsRejected()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            RangeResponse(7, 10, 32, [1, 2, 3, 4]));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(), Session(), Capability(), "/shared/example.bin", 8, 4));

        Assert.Equal(FileRangeContractFailure.UnexpectedRangeStart, error.Failure);
    }

    [Fact]
    public async Task WrongResponseLengthIsRejected()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            RangeResponse(8, 10, 32, [1, 2, 3]));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(), Session(), Capability(), "/shared/example.bin", 8, 4));

        Assert.Equal(FileRangeContractFailure.UnexpectedRangeLength, error.Failure);
    }

    [Fact]
    public async Task ChangedTotalLengthIsRejected()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            RangeResponse(8, 11, 32, [1, 2, 3, 4]));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(),
                Session(),
                Capability(),
                "/shared/example.bin",
                8,
                4,
                expectedTotalLength: 31));

        Assert.Equal(FileRangeContractFailure.UnexpectedTotalLength, error.Failure);
    }

    [Fact]
    public async Task ShortResponseBodyIsRejected()
    {
        using var handler = new StubHttpMessageHandler(_ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.PartialContent)
            {
                Content = new StreamingContent([1, 2, 3]),
            };
            response.Content.Headers.ContentRange = new ContentRangeHeaderValue(8, 11, 32);
            return response;
        });
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(), Session(), Capability(), "/shared/example.bin", 8, 4));

        Assert.Equal(FileRangeContractFailure.UnexpectedBodyLength, error.Failure);
    }

    [Fact]
    public async Task ChangedStrongVersionIsRejected()
    {
        using var handler = new StubHttpMessageHandler(request =>
        {
            Assert.Equal("\"version-1\"", Assert.Single(request.Headers.IfMatch).Tag);
            return RangeResponse(8, 11, 32, [1, 2, 3, 4], "\"version-2\"");
        });
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(),
                Session(),
                Capability(),
                "/shared/example.bin",
                8,
                4,
                "\"version-1\""));

        Assert.Equal(FileRangeContractFailure.ContentVersionMismatch, error.Failure);
    }

    [Fact]
    public async Task PreconditionFailedMapsToContentVersionMismatch()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.PreconditionFailed));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(),
                Session(),
                Capability(),
                "/shared/example.bin",
                8,
                4,
                "\"version-1\""));

        Assert.Equal(FileRangeContractFailure.ContentVersionMismatch, error.Failure);
        Assert.Equal(412, error.StatusCode);
    }

    [Fact]
    public async Task SuccessfulIfMatchCanProveVersionWhenResponseOmitsEntityTag()
    {
        using var handler = new StubHttpMessageHandler(request =>
        {
            Assert.Equal("\"version-1\"", Assert.Single(request.Headers.IfMatch).Tag);
            return RangeResponse(8, 11, 32, [1, 2, 3, 4]);
        });
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var result = await client.ReadFileRangeResultAsync(
            Profile(),
            Session(),
            Capability(),
            "/shared/example.bin",
            8,
            4,
            "\"version-1\"");

        Assert.Equal("\"version-1\"", result.ServerContentVersion);
        Assert.True(result.CanSafelyReadInSegments);
    }

    [Fact]
    public async Task WeakResponseVersionIsRejectedWhenStrongVersionWasRequired()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            RangeResponse(8, 11, 32, [1, 2, 3, 4], "W/\"version-1\""));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(),
                Session(),
                Capability(),
                "/shared/example.bin",
                8,
                4,
                "\"version-1\""));

        Assert.Equal(FileRangeContractFailure.ContentVersionMismatch, error.Failure);
    }

    [Fact]
    public async Task MismatchedContentLengthIsRejectedBeforeReadingBody()
    {
        using var handler = new StubHttpMessageHandler(_ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.PartialContent)
            {
                Content = new StreamingContent([1, 2, 3, 4]),
            };
            response.Content.Headers.ContentRange = new ContentRangeHeaderValue(8, 11, 32);
            response.Content.Headers.ContentLength = 5;
            return response;
        });
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(), Session(), Capability(), "/shared/example.bin", 8, 4));

        Assert.Equal(FileRangeContractFailure.UnexpectedContentLength, error.Failure);
    }

    [Fact]
    public async Task LongResponseBodyIsRejected()
    {
        using var handler = new StubHttpMessageHandler(_ =>
        {
            var response = new HttpResponseMessage(HttpStatusCode.PartialContent)
            {
                Content = new StreamingContent([1, 2, 3, 4, 5]),
            };
            response.Content.Headers.ContentRange = new ContentRangeHeaderValue(8, 11, 32);
            return response;
        });
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(), Session(), Capability(), "/shared/example.bin", 8, 4));

        Assert.Equal(FileRangeContractFailure.UnexpectedBodyLength, error.Failure);
    }

    [Fact]
    public async Task OffsetAndLengthOverflowIsRejectedBeforeSendingRequest()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            throw new InvalidOperationException("The request must not be sent."));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(), Session(), Capability(), "/shared/example.bin", long.MaxValue, 2));

        Assert.Equal(0, handler.RequestCount);
    }

    [Fact]
    public async Task RangeBeyondExpectedTotalIsRejectedBeforeSendingRequest()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            throw new InvalidOperationException("The request must not be sent."));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(),
                Session(),
                Capability(),
                "/shared/example.bin",
                8,
                4,
                expectedTotalLength: 11));

        Assert.Equal(0, handler.RequestCount);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not-an-etag")]
    [InlineData("W/\"weak-version\"")]
    public async Task InvalidOrWeakExpectedVersionIsRejectedBeforeSendingRequest(
        string expectedContentVersion)
    {
        using var handler = new StubHttpMessageHandler(_ =>
            throw new InvalidOperationException("The request must not be sent."));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        await Assert.ThrowsAsync<ArgumentException>(() =>
            client.ReadFileRangeResultAsync(
                Profile(),
                Session(),
                Capability(),
                "/shared/example.bin",
                8,
                4,
                expectedContentVersion));

        Assert.Equal(0, handler.RequestCount);
    }

    [Fact]
    public async Task ExpectedTotalLengthAcceptsAConsistentLastSegment()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            RangeResponse(28, 31, 32, [1, 2, 3, 4], "\"version-1\""));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var result = await client.ReadFileRangeResultAsync(
            Profile(),
            Session(),
            Capability(),
            "/shared/example.bin",
            28,
            4,
            "\"version-1\"",
            32);

        Assert.Equal(28, result.ResponseStart);
        Assert.Equal(32, result.TotalLength);
        Assert.True(result.CanSafelyReadInSegments);
    }

    [Fact]
    public async Task FirstSegmentWithoutStrongVersionIsNotSafeForMoreSegments()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            RangeResponse(0, 3, 32, [1, 2, 3, 4]));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var result = await client.ReadFileRangeResultAsync(
            Profile(), Session(), Capability(), "/shared/example.bin", 0, 4);

        Assert.Null(result.ServerContentVersion);
        Assert.False(result.CanSafelyReadInSegments);
    }

    [Fact]
    public async Task CompatibleByteArrayMethodUsesStrictValidation()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            RangeResponse(0, 3, 4, [1, 2, 3, 4]));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var bytes = await client.ReadFileRangeAsync(
            Profile(), Session(), Capability(), "/shared/example.bin", 0, 4);

        Assert.Equal(new byte[] { 1, 2, 3, 4 }, bytes);
    }

    [Fact]
    public async Task CompatibleByteArrayMethodRejectsPartialSegments()
    {
        using var handler = new StubHttpMessageHandler(_ =>
            RangeResponse(4, 7, 12, [1, 2, 3, 4], "\"version-1\""));
        using var httpClient = new HttpClient(handler);
        var client = new DsmApiClient(httpClient);

        var error = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            client.ReadFileRangeAsync(
                Profile(), Session(), Capability(), "/shared/example.bin", 4, 4));

        Assert.Equal(FileRangeContractFailure.UnsafeSegmentedRead, error.Failure);
    }

    private static HttpResponseMessage RangeResponse(
        long from,
        long to,
        long totalLength,
        byte[] bytes,
        string? entityTag = null)
    {
        var response = new HttpResponseMessage(HttpStatusCode.PartialContent)
        {
            Content = new ByteArrayContent(bytes),
        };
        response.Content.Headers.ContentRange = new ContentRangeHeaderValue(from, to, totalLength);
        if (entityTag is not null)
        {
            response.Headers.ETag = EntityTagHeaderValue.Parse(entityTag);
        }
        return response;
    }

    private static NasProfile Profile() =>
        new(Guid.NewGuid(), "Test NAS", "nas.example.com", null, "tester");

    private static DsmSession Session() =>
        new(Guid.NewGuid(), "synthetic-session", "synthetic-token", null);

    private static ApiCapability Capability() =>
        new("SYNO.FileStation.Download", "entry.cgi", 1, 2, "FORM");

    private sealed class StubHttpMessageHandler(
        Func<HttpRequestMessage, HttpResponseMessage> responseFactory) : HttpMessageHandler
    {
        public int RequestCount { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestCount++;
            return Task.FromResult(responseFactory(request));
        }
    }

    private sealed class StreamingContent(byte[] bytes) : HttpContent
    {
        protected override Task SerializeToStreamAsync(
            Stream stream,
            TransportContext? context) =>
            stream.WriteAsync(bytes).AsTask();

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }
    }

    private sealed class RecordingRangeApiClient : IDsmApiClient
    {
        public string? RemotePath { get; private set; }
        public long Offset { get; private set; }
        public long Length { get; private set; }
        public string? ExpectedContentVersion { get; private set; }
        public long? ExpectedTotalLength { get; private set; }

        public Task<FileRangeReadResult> ReadFileRangeResultAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string remotePath,
            long offset,
            long length,
            string? expectedContentVersion = null,
            long? expectedTotalLength = null,
            CancellationToken cancellationToken = default)
        {
            RemotePath = remotePath;
            Offset = offset;
            Length = length;
            ExpectedContentVersion = expectedContentVersion;
            ExpectedTotalLength = expectedTotalLength;
            return Task.FromResult(new FileRangeReadResult(
                206,
                offset,
                length,
                offset,
                length,
                expectedTotalLength ?? offset + length,
                length,
                new byte[checked((int)length)],
                expectedContentVersion,
                expectedContentVersion is not null));
        }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid");

        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<DsmSession> LoginAsync(
            NasProfile profile,
            string password,
            string? otp,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task LogoutAsync(
            NasProfile profile,
            DsmSession session,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<System.Text.Json.Nodes.JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string remotePath,
            long offset,
            long length,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }
}
