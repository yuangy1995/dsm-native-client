using System.Net;
using System.Text;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class FileUploadContractTests
{
    private static readonly NasProfile Profile = new(
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        "synthetic",
        "nas.invalid",
        5001,
        "tester");
    private static readonly DsmSession Session = new(
        Profile.Id,
        "synthetic-sid",
        "synthetic-token",
        null);
    private static readonly ApiCapability Capability = new(
        "SYNO.FileStation.Upload",
        "entry.cgi",
        1,
        2,
        "MULTIPART");

    [Fact]
    public async Task MultipartHasExactLengthAndFileIsLastPart()
    {
        byte[]? body = null;
        long? declaredLength = null;
        Uri? requestUri = null;
        using var handler = new AsyncStubHandler(async (request, cancellationToken) =>
        {
            declaredLength = request.Content!.Headers.ContentLength;
            requestUri = request.RequestUri;
            body = await request.Content.ReadAsByteArrayAsync(cancellationToken);
            return JsonResponse("{\"success\":true}");
        });
        using var http = new HttpClient(handler);
        var client = new DsmApiClient(http);
        var source = new MemoryStream([0x00, 0x01, 0xFE, 0xFF]);
        var upload = new FileUploadRequest(source, 4, "/projects", "sample.bin");

        var result = await client.UploadFileAsync(Profile, Session, Capability, upload);

        Assert.Equal(FileUploadTransportStatus.Accepted, result.Status);
        Assert.NotNull(body);
        Assert.Equal(body!.LongLength, declaredLength);
        Assert.NotNull(requestUri);
        Assert.DoesNotContain("synthetic-sid", requestUri!.OriginalString);
        Assert.DoesNotContain("/projects", requestUri.OriginalString);
        Assert.True(source.CanRead);

        var text = Encoding.UTF8.GetString(body);
        var api = text.IndexOf("name=\"api\"", StringComparison.Ordinal);
        var version = text.IndexOf("name=\"version\"", StringComparison.Ordinal);
        var method = text.IndexOf("name=\"method\"", StringComparison.Ordinal);
        var sid = text.IndexOf("name=\"_sid\"", StringComparison.Ordinal);
        var path = text.IndexOf("name=\"path\"", StringComparison.Ordinal);
        var createParents = text.IndexOf("name=\"create_parents\"", StringComparison.Ordinal);
        var overwrite = text.IndexOf("name=\"overwrite\"", StringComparison.Ordinal);
        var file = text.IndexOf("name=\"file\"", StringComparison.Ordinal);
        var fileDisposition = text.IndexOf(
            "Content-Disposition: form-data; name=\"file\"",
            StringComparison.Ordinal);
        Assert.True(api >= 0 && api < version);
        Assert.True(version < method && method < sid);
        Assert.True(sid < path && path < createParents);
        Assert.True(createParents < overwrite && overwrite < file);
        Assert.True(fileDisposition >= 0);
        Assert.Equal(
            fileDisposition,
            text.LastIndexOf("Content-Disposition: form-data", StringComparison.Ordinal));
        Assert.Contains("name=\"api\"\r\n\r\nSYNO.FileStation.Upload\r\n", text);
        Assert.Contains("name=\"version\"\r\n\r\n2\r\n", text);
        Assert.Contains("name=\"method\"\r\n\r\nupload\r\n", text);
        Assert.Contains("name=\"path\"\r\n\r\n/projects\r\n", text);
        Assert.Contains("name=\"create_parents\"\r\n\r\nfalse\r\n", text);
        Assert.Contains("name=\"overwrite\"\r\n\r\nfalse\r\n", text);
        Assert.Contains("\r\nfalse\r\n", text);
        Assert.Contains("filename=\"sample.bin\"", text);
        Assert.True(body.AsSpan().IndexOf(new byte[] { 0x00, 0x01, 0xFE, 0xFF }) > 0);
        Assert.Equal(nameof(FileUploadRequest), upload.ToString());
    }

    [Fact]
    public async Task UploadStreamsInBoundedChunksAndReportsNumericBytes()
    {
        using var handler = new AsyncStubHandler(async (request, cancellationToken) =>
        {
            _ = await request.Content!.ReadAsByteArrayAsync(cancellationToken);
            return JsonResponse("{\"success\":true}");
        });
        using var http = new HttpClient(handler);
        var source = new TrackingReadStream(new byte[200_000]);
        var reports = new List<long>();

        var result = await new DsmApiClient(http).UploadFileAsync(
            Profile,
            Session,
            Capability,
            new FileUploadRequest(source, 200_000, "/projects", "large.bin"),
            new InlineProgress(reports.Add));

        Assert.Equal(FileUploadTransportStatus.Accepted, result.Status);
        Assert.InRange(source.LargestRequestedRead, 1, 64 * 1024);
        Assert.Equal(200_000, reports.Last());
        Assert.True(source.CanRead);
    }

    [Fact]
    public async Task CancellationBeforeSendDoesNotReachHandlerOrReadSource()
    {
        var sendCount = 0;
        using var handler = new AsyncStubHandler((_, _) =>
        {
            sendCount++;
            return Task.FromResult(JsonResponse("{\"success\":true}"));
        });
        using var http = new HttpClient(handler);
        var source = new TrackingReadStream(new byte[32]);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var result = await new DsmApiClient(http).UploadFileAsync(
            Profile,
            Session,
            Capability,
            new FileUploadRequest(source, 32, "/projects", "cancel.bin"),
            cancellationToken: cancellation.Token);

        Assert.Equal(FileUploadTransportStatus.CancelledBeforeSubmission, result.Status);
        Assert.Equal(0, sendCount);
        Assert.Equal(0, source.ReadCount);
    }

    [Fact]
    public async Task InvalidUploadCapabilityOrSessionDoesNotReachHandler()
    {
        var sendCount = 0;
        using var handler = new AsyncStubHandler((_, _) =>
        {
            sendCount++;
            return Task.FromResult(JsonResponse("{\"success\":true}"));
        });
        using var http = new HttpClient(handler);
        var client = new DsmApiClient(http);

        var wrongSession = await client.UploadFileAsync(
            Profile,
            Session with { ProfileId = Guid.NewGuid() },
            Capability,
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "file.bin"));
        var wrongFormat = await client.UploadFileAsync(
            Profile,
            Session,
            Capability with { RequestFormat = "FORM" },
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "file.bin"));

        Assert.Equal(FileUploadTransportStatus.Unsupported, wrongSession.Status);
        Assert.Equal(FileUploadTransportStatus.Unsupported, wrongFormat.Status);
        Assert.Equal(0, sendCount);
    }

    [Fact]
    public async Task CancellationAfterSendIsNotReportedAsSafeRetry()
    {
        var sendCount = 0;
        using var handler = new AsyncStubHandler((_, cancellationToken) =>
        {
            sendCount++;
            throw new OperationCanceledException(cancellationToken);
        });
        using var http = new HttpClient(handler);

        var result = await new DsmApiClient(http).UploadFileAsync(
            Profile,
            Session,
            Capability,
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "cancel.bin"));

        Assert.Equal(FileUploadTransportStatus.CancellationRequestedAfterSubmission, result.Status);
        Assert.Equal(1, sendCount);
    }

    [Fact]
    public async Task NetworkFailureAfterSendIsUnverifiedAndNeverReplayed()
    {
        var sendCount = 0;
        using var handler = new AsyncStubHandler((_, _) =>
        {
            sendCount++;
            throw new HttpRequestException("synthetic network failure");
        });
        using var http = new HttpClient(handler);

        var result = await new DsmApiClient(http).UploadFileAsync(
            Profile,
            Session,
            Capability,
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "network.bin"));

        Assert.Equal(FileUploadTransportStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(1, sendCount);
    }

    [Fact]
    public async Task AHandlerCannotSerializeTheUploadBodyTwice()
    {
        using var handler = new AsyncStubHandler(async (request, cancellationToken) =>
        {
            await request.Content!.CopyToAsync(Stream.Null, cancellationToken);
            await Assert.ThrowsAsync<InvalidOperationException>(() =>
                request.Content.CopyToAsync(Stream.Null, cancellationToken));
            return JsonResponse("{\"success\":true}");
        });
        using var http = new HttpClient(handler);

        var result = await new DsmApiClient(http).UploadFileAsync(
            Profile,
            Session,
            Capability,
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "once.bin"));

        Assert.Equal(FileUploadTransportStatus.Accepted, result.Status);
    }

    [Fact]
    public async Task ExplicitOverwriteWritesTrueWithoutChangingTheOtherFields()
    {
        string? body = null;
        using var handler = new AsyncStubHandler(async (request, cancellationToken) =>
        {
            body = Encoding.UTF8.GetString(
                await request.Content!.ReadAsByteArrayAsync(cancellationToken));
            return JsonResponse("{\"success\":true}");
        });
        using var http = new HttpClient(handler);

        var result = await new DsmApiClient(http).UploadFileAsync(
            Profile,
            Session,
            Capability,
            new FileUploadRequest(
                new MemoryStream([1]),
                1,
                "/projects",
                "replace.bin",
                overwrite: true));

        Assert.Equal(FileUploadTransportStatus.Accepted, result.Status);
        Assert.NotNull(body);
        Assert.Contains("name=\"overwrite\"\r\n\r\ntrue\r\n", body!);
        Assert.Contains("name=\"create_parents\"\r\n\r\nfalse\r\n", body);
    }

    [Fact]
    public async Task SourceShorterThanDeclaredCannotBeReportedAsSuccess()
    {
        var sendCount = 0;
        using var handler = new AsyncStubHandler(async (request, cancellationToken) =>
        {
            sendCount++;
            _ = await request.Content!.ReadAsByteArrayAsync(cancellationToken);
            return JsonResponse("{\"success\":true}");
        });
        using var http = new HttpClient(handler);
        var source = new MemoryStream([1, 2]);

        var result = await new DsmApiClient(http).UploadFileAsync(
            Profile,
            Session,
            Capability,
            new FileUploadRequest(source, 3, "/projects", "short.bin"));

        Assert.Equal(FileUploadTransportStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(1, sendCount);
        Assert.True(source.CanRead);
    }

    [Theory]
    [InlineData("/projects\rnext")]
    [InlineData("/projects\nnext")]
    [InlineData("/projects\0next")]
    public void FolderControlCharactersAreRejectedBeforeAnyRequest(string folderPath)
    {
        Assert.Throws<ArgumentException>(() => new FileUploadRequest(
            new MemoryStream([]),
            0,
            folderPath,
            "empty.bin"));
    }

    [Theory]
    [InlineData(105, MutationErrorCategory.Permission)]
    [InlineData(106, MutationErrorCategory.Authentication)]
    [InlineData(1805, MutationErrorCategory.Conflict)]
    [InlineData(1804, MutationErrorCategory.Server)]
    public async Task ExplicitDsmFailureIsConfirmed(int code, MutationErrorCategory category)
    {
        using var handler = new AsyncStubHandler((_, _) => Task.FromResult(
            JsonResponse($"{{\"success\":false,\"error\":{{\"code\":{code}}}}}")));
        using var http = new HttpClient(handler);

        var result = await new DsmApiClient(http).UploadFileAsync(
            Profile,
            Session,
            Capability,
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "failure.bin"));

        Assert.Equal(FileUploadTransportStatus.ConfirmedFailure, result.Status);
        Assert.Equal(category, result.ErrorCategory);
        Assert.DoesNotContain("projects", result.DiagnosticTag ?? string.Empty);
        Assert.DoesNotContain("failure.bin", result.DiagnosticTag ?? string.Empty);
    }

    private static HttpResponseMessage JsonResponse(string json) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json"),
    };

    private sealed class AsyncStubHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> responder)
        : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => responder(request, cancellationToken);
    }

    private sealed class InlineProgress(Action<long> report) : IProgress<long>
    {
        public void Report(long value) => report(value);
    }

    private sealed class TrackingReadStream(byte[] bytes) : Stream
    {
        private int _offset;
        public int LargestRequestedRead { get; private set; }
        public int ReadCount { get; private set; }
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => bytes.Length;
        public override long Position { get => _offset; set => throw new NotSupportedException(); }

        public override int Read(byte[] buffer, int offset, int count)
        {
            LargestRequestedRead = Math.Max(LargestRequestedRead, count);
            ReadCount++;
            var available = Math.Min(count, bytes.Length - _offset);
            bytes.AsSpan(_offset, available).CopyTo(buffer.AsSpan(offset, available));
            _offset += available;
            return available;
        }

        public override ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            LargestRequestedRead = Math.Max(LargestRequestedRead, buffer.Length);
            ReadCount++;
            var available = Math.Min(buffer.Length, bytes.Length - _offset);
            bytes.AsMemory(_offset, available).CopyTo(buffer);
            _offset += available;
            return ValueTask.FromResult(available);
        }

        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
