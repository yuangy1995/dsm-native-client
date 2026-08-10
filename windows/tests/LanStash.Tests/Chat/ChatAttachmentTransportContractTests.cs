using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Chat;

public sealed class ChatAttachmentTransportContractTests
{
    private static readonly NasProfile Profile = new(
        Guid.Parse("33333333-3333-3333-3333-333333333333"),
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
        "SYNO.Chat.Post",
        "entry.cgi",
        1,
        8,
        "FORM");

    [Fact]
    public void SyntheticFixtureFreezesSingleAttachmentV5MultipartContract()
    {
        var fixture = JsonNode.Parse(ReadRepositoryFile(
            "contracts/request-fixtures/chat/send-attachment/synthetic-file/request.json"))!
            .AsObject();
        var api = fixture["api"]!.AsObject();
        var transport = fixture["transport"]!.AsObject();
        var parameters = fixture["parameters"]!.AsArray()
            .Select(value => value!.AsObject());

        Assert.Equal("SYNO.Chat.Post", api["name"]!.GetValue<string>());
        Assert.Equal("create", api["method"]!.GetValue<string>());
        Assert.Equal(5, api["resolvedVersion"]!.GetValue<int>());
        Assert.Equal("POST", transport["httpMethod"]!.GetValue<string>());
        Assert.Equal("multipart", transport["requestFormat"]!.GetValue<string>());
        Assert.Equal(
            new[] { "channel_id", "type", "message", "is_thread", "file" },
            parameters.Select(value => value["name"]!.GetValue<string>()));
        Assert.Equal(
            new[] { "cookie", "multipart" },
            fixture["authentication"]!["sessionLocations"]!.AsArray()
                .Select(value => value!.GetValue<string>())
                .Order());
        Assert.Equal(
            new[] { "header", "multipart" },
            fixture["authentication"]!["synoTokenLocations"]!.AsArray()
                .Select(value => value!.GetValue<string>())
                .Order());
        Assert.Equal("queryStateBeforeDecision",
            fixture["policy"]!["retryPolicy"]!.GetValue<string>());
        Assert.Equal("required", fixture["policy"]!["readbackPolicy"]!.GetValue<string>());
    }

    [Fact]
    public async Task ExactV5MultipartSendsFixtureFieldsOnceAndReportsOnlyByteProgress()
    {
        byte[]? body = null;
        long? declaredLength = null;
        Uri? requestUri = null;
        string? cookie = null;
        string? token = null;
        using var handler = new StubHttpMessageHandler(async (request, cancellationToken) =>
        {
            requestUri = request.RequestUri;
            declaredLength = request.Content!.Headers.ContentLength;
            body = await request.Content.ReadAsByteArrayAsync(cancellationToken);
            cookie = request.Headers.GetValues("Cookie").Single();
            token = request.Headers.GetValues("X-SYNO-TOKEN").Single();
            return JsonResponse("""{"success":true,"data":{"post_id":"post-file-1"}}""");
        });
        using var http = new HttpClient(handler);
        var reports = new List<long>();
        var payload = new byte[] { 0x00, 0x01, 0xFE, 0xFF };
        var source = new MemoryStream(payload, writable: false);

        var result = await new DsmApiClient(http).SendChatAttachmentAsync(
            Profile,
            Session,
            Capability,
            new ChatAttachmentUploadRequest(
                "synthetic-channel",
                string.Empty,
                "synthetic.bin",
                source,
                payload.Length),
            progress: new InlineProgress(reports.Add));

        Assert.Equal(ChatAttachmentUploadTransportStatus.Accepted, result.Status);
        Assert.Equal("post-file-1", result.CandidateMessageId);
        Assert.NotNull(body);
        Assert.Equal(body!.LongLength, declaredLength);
        Assert.NotNull(requestUri);
        Assert.Equal("/webapi/entry.cgi", requestUri!.AbsolutePath);
        Assert.Empty(requestUri.Query);
        Assert.DoesNotContain("synthetic-sid", requestUri.OriginalString);
        Assert.DoesNotContain("synthetic-token", requestUri.OriginalString);
        Assert.Equal("id=synthetic-sid", cookie);
        Assert.Equal("synthetic-token", token);
        Assert.Equal(new long[] { 0, payload.Length }, reports);

        var text = Encoding.UTF8.GetString(body);
        AssertFieldOrder(
            text,
            "name=\"api\"",
            "name=\"version\"",
            "name=\"method\"",
            "name=\"channel_id\"",
            "name=\"type\"",
            "name=\"message\"",
            "name=\"is_thread\"",
            "name=\"_sid\"",
            "name=\"SynoToken\"",
            "name=\"file\"");
        Assert.Contains("name=\"api\"\r\n\r\nSYNO.Chat.Post\r\n", text);
        Assert.Contains("name=\"version\"\r\n\r\n5\r\n", text);
        Assert.Contains("name=\"method\"\r\n\r\ncreate\r\n", text);
        Assert.Contains("name=\"channel_id\"\r\n\r\nsynthetic-channel\r\n", text);
        Assert.Contains("name=\"type\"\r\n\r\nfile\r\n", text);
        Assert.Contains("name=\"message\"\r\n\r\n\r\n", text);
        Assert.Contains("name=\"is_thread\"\r\n\r\nfalse\r\n", text);
        Assert.Contains("name=\"_sid\"\r\n\r\nsynthetic-sid\r\n", text);
        Assert.Contains("name=\"SynoToken\"\r\n\r\nsynthetic-token\r\n", text);
        Assert.Equal(1, CountOccurrences(text, "name=\"SynoToken\""));
        Assert.DoesNotContain("name=\"synotoken\"", text, StringComparison.Ordinal);
        Assert.Contains("filename=\"synthetic.bin\"", text);
        Assert.True(body.AsSpan().IndexOf(payload) > 0);
    }

    [Fact]
    public async Task CancellationBeforeSubmissionDoesNotReachMultipartTransport()
    {
        var sends = 0;
        using var handler = new StubHttpMessageHandler((_, _) =>
        {
            sends++;
            return Task.FromResult(JsonResponse("""{"success":true}"""));
        });
        using var http = new HttpClient(handler);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var result = await new DsmApiClient(http).SendChatAttachmentAsync(
            Profile,
            Session,
            Capability,
            new ChatAttachmentUploadRequest(
                "synthetic-channel",
                string.Empty,
                "synthetic.bin",
                new MemoryStream([0x01]),
                1),
            cancellationToken: cancellation.Token);

        Assert.Equal(ChatAttachmentUploadTransportStatus.CancelledBeforeSubmission, result.Status);
        Assert.Equal(0, sends);
    }

    private static void AssertFieldOrder(string body, params string[] fields)
    {
        var previous = -1;
        foreach (var field in fields)
        {
            var index = body.IndexOf(field, StringComparison.Ordinal);
            Assert.True(index > previous, $"Expected multipart field '{field}' after its predecessor.");
            previous = index;
        }
    }

    private static int CountOccurrences(string value, string pattern) =>
        (value.Length - value.Replace(pattern, string.Empty, StringComparison.Ordinal).Length) /
        pattern.Length;

    private static HttpResponseMessage JsonResponse(string body) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(body, Encoding.UTF8, "application/json"),
    };

    private static string ReadRepositoryFile(string relativePath)
    {
        for (var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
             directory is not null;
             directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(candidate)) return File.ReadAllText(candidate);
        }
        throw new DirectoryNotFoundException(relativePath);
    }

    private sealed class InlineProgress(Action<long> report) : IProgress<long>
    {
        public void Report(long value) => report(value);
    }

    private sealed class StubHttpMessageHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> response) :
        HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => response(request, cancellationToken);
    }
}
