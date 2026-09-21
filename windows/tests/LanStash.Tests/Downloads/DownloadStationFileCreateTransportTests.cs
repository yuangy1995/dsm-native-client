using System.Net;
using System.Text;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Downloads;

public sealed class DownloadStationFileCreateTransportTests
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
        "SYNO.DownloadStation.Task",
        "entry.cgi",
        1,
        1,
        "FORM");

    [Theory]
    [InlineData(null, 1)]
    [InlineData("/downloads", 2)]
    public async Task FileCreateChoosesVersionByDestinationAndKeepsPasswordOnlyInMultipart(string? target, int expectedVersion)
    {
        byte[]? body = null;
        long? declaredLength = null;
        Uri? requestUri = null;
        Guid? contextProfile = null;
        DsmConnectionSource? contextSource = null;
        using var handler = new CaptureHandler(async (request, cancellationToken) =>
        {
            declaredLength = request.Content!.Headers.ContentLength;
            requestUri = request.RequestUri;
            if (WindowsCertificateTrustHandler.TryGetConnectionContext(
                    request,
                    out var profileId,
                    out var source))
            {
                contextProfile = profileId;
                contextSource = source;
            }
            body = await request.Content.ReadAsByteArrayAsync(cancellationToken);
            return JsonResponse("""{"success":true,"data":{"taskid":"file-task"}}""");
        });
        using var http = new HttpClient(handler);
        var client = new DsmApiClient(http);
        var source = new MemoryStream([0x64, 0x38, 0x3A, 0x61]);
        var upload = new DownloadTaskFileCreateRequest(
            Profile.Id,
            source,
            4,
            "sample.torrent",
            target,
            "  synthetic & 密码  ");

        var result = await client.CreateDownloadTaskFromFileAsync(
            Profile,
            Session,
            Capability with { MaxVersion = 9, Path = "webapi/entry.cgi" },
            upload);

        Assert.Equal(DownloadTaskFileCreateTransportStatus.Accepted, result.Status);
        Assert.Equal("file-task", result.TaskId);
        Assert.NotNull(body);
        Assert.Equal(body!.LongLength, declaredLength);
        Assert.NotNull(requestUri);
        Assert.Equal("/webapi/entry.cgi", requestUri!.AbsolutePath);
        Assert.DoesNotContain("synthetic-sid", requestUri!.OriginalString);
        Assert.DoesNotContain("/downloads", requestUri.OriginalString);
        Assert.Equal(Profile.Id, contextProfile);
        Assert.Equal(DsmConnectionSource.DirectAddress, contextSource);

        var text = Encoding.UTF8.GetString(body);
        Assert.Contains("name=\"SynoToken\"\r\n\r\nsynthetic-token\r\n", text);
        Assert.DoesNotContain("synthetic-token", requestUri.OriginalString);
        var api = text.IndexOf("name=\"api\"", StringComparison.Ordinal);
        var version = text.IndexOf("name=\"version\"", StringComparison.Ordinal);
        var method = text.IndexOf("name=\"method\"", StringComparison.Ordinal);
        var sid = text.IndexOf("name=\"_sid\"", StringComparison.Ordinal);
        var destination = text.IndexOf("name=\"destination\"", StringComparison.Ordinal);
        var file = text.IndexOf("name=\"file\"", StringComparison.Ordinal);
        var fileDisposition = text.IndexOf(
            "Content-Disposition: form-data; name=\"file\"",
            StringComparison.Ordinal);
        Assert.True(api >= 0 && api < version);
        Assert.True(version < method && method < sid);
        if (target is not null) Assert.True(sid < destination && destination < file);
        else Assert.Equal(-1, destination);
        var password = text.IndexOf("name=\"unzip_password\"", StringComparison.Ordinal);
        Assert.True(password > sid && password < file);
        Assert.Contains("name=\"unzip_password\"\r\n\r\n  synthetic & 密码  \r\n", text);
        Assert.DoesNotContain("synthetic &", requestUri.OriginalString);
        Assert.True(fileDisposition >= 0);
        Assert.Equal(
            fileDisposition,
            text.LastIndexOf("Content-Disposition: form-data", StringComparison.Ordinal));
        Assert.Contains("name=\"api\"\r\n\r\nSYNO.DownloadStation.Task\r\n", text);
        Assert.Contains($"name=\"version\"\r\n\r\n{expectedVersion}\r\n", text);
        Assert.Contains("name=\"method\"\r\n\r\ncreate\r\n", text);
        if (target is not null) Assert.Contains("name=\"destination\"\r\n\r\n/downloads\r\n", text);
        Assert.Contains("filename=\"sample.torrent\"", text);
        Assert.True(body.AsSpan().IndexOf(new byte[] { 0x64, 0x38, 0x3A, 0x61 }) > 0);
        Assert.Equal(nameof(DownloadTaskFileCreateRequest), upload.ToString());
    }

    [Fact]
    public async Task DestinationWithOnlyV1CapabilityIsRejectedBeforeTransport()
    {
        var calls = 0;
        using var http = new HttpClient(new CaptureHandler((_, _) => { calls++; return Task.FromResult(JsonResponse("{}")); }));
        using var stream = new MemoryStream([1]);
        var result = await new DsmApiClient(http).CreateDownloadTaskFromFileAsync(Profile, Session, Capability,
            new(Profile.Id, stream, 1, "synthetic.torrent", "downloads"));
        Assert.Equal(DownloadTaskFileCreateTransportStatus.Unsupported, result.Status); Assert.Equal(0, calls);
    }

    private static HttpResponseMessage JsonResponse(string json) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(json, Encoding.UTF8, "application/json"),
    };

    private sealed class CaptureHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> responseFactory)
        : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            responseFactory(request, cancellationToken);
    }
}
