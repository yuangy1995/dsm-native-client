using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Chat;

public sealed class ChatAttachmentContentTransportContractTests
{
    private static readonly NasProfile Profile = new(
        Guid.Parse("44444444-4444-4444-4444-444444444444"),
        "synthetic",
        "nas.invalid",
        5001,
        "tester");

    private static readonly DsmSession Session = new(
        Profile.Id,
        "synthetic-sid",
        "synthetic-token",
        null);

    private static readonly ApiCapability FileCapability = new(
        "SYNO.Chat.Post.File",
        "entry.cgi",
        2,
        2,
        "FORM");

    [Fact]
    public void SyntheticFixturesFreezeFixedV2ThumbnailAndSaveContracts()
    {
        AssertReadFixture(
            "contracts/request-fixtures/chat/read-attachment-thumbnail/synthetic-post/request.json",
            "thumbnail",
            ["post_id", "type"],
            ["synthetic-post", "sm"]);
        AssertReadFixture(
            "contracts/request-fixtures/chat/save-attachment/synthetic-post/request.json",
            "get",
            ["post_id"],
            ["synthetic-post"]);
    }

    [Fact]
    public async Task ContentReadStreamsFixedV2GetIntoCallerDestinationWithNumericProgress()
    {
        var payload = new byte[] { 0x00, 0x01, 0xFE };
        Uri? requestUri = null;
        string? cookie = null;
        string? token = null;
        string? acceptedMediaType = null;
        using var handler = new StubHttpMessageHandler((request, _) =>
        {
            requestUri = request.RequestUri;
            cookie = request.Headers.GetValues("Cookie").Single();
            token = request.Headers.GetValues("X-SYNO-TOKEN").Single();
            acceptedMediaType = request.Headers.Accept.Single().MediaType;
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.Null(request.Content);
            return Task.FromResult(BinaryResponse(payload));
        });
        using var http = new HttpClient(handler);
        using var destination = new MemoryStream();
        var reports = new List<long>();

        var result = await new DsmApiClient(http).ReadChatAttachmentContentAsync(
            Profile,
            Session,
            FileCapability,
            new ChatAttachmentContentReadRequest("post-content-1", destination, payload.Length),
            new InlineProgress(reports.Add));

        Assert.Equal(ChatAttachmentContentReadStatus.Completed, result.Status);
        Assert.Equal((long)payload.Length, result.BytesWritten);
        Assert.False(result.DestinationWasCleared);
        Assert.Equal("chat.attachment-save.completed", result.DiagnosticTag);
        Assert.Equal(payload, destination.ToArray());
        Assert.Equal(new long[] { 0, payload.Length }, reports);
        Assert.NotNull(requestUri);
        Assert.Equal("/webapi/entry.cgi", requestUri!.AbsolutePath);
        Assert.Equal(
            "?api=SYNO.Chat.Post.File&version=2&method=get&post_id=post-content-1",
            requestUri.Query);
        Assert.DoesNotContain("synthetic-sid", requestUri.OriginalString);
        Assert.DoesNotContain("synthetic-token", requestUri.OriginalString);
        Assert.Equal("id=synthetic-sid", cookie);
        Assert.Equal("synthetic-token", token);
        Assert.Equal("application/octet-stream", acceptedMediaType);
    }

    [Fact]
    public async Task ContentReadRejectsDeclaredLengthMismatchAndResetsDestination()
    {
        using var handler = new StubHttpMessageHandler((_, _) =>
            Task.FromResult(BinaryResponse([0x01, 0x02])));
        using var http = new HttpClient(handler);
        using var destination = new MemoryStream();

        var result = await new DsmApiClient(http).ReadChatAttachmentContentAsync(
            Profile,
            Session,
            FileCapability,
            new ChatAttachmentContentReadRequest("post-content-2", destination, ExpectedLength: 3));

        Assert.Equal(ChatAttachmentContentReadStatus.Failed, result.Status);
        Assert.Equal(MutationErrorCategory.Server, result.ErrorCategory);
        Assert.True(result.DestinationWasCleared);
        Assert.Equal("chat.attachment-save.length-mismatch", result.DiagnosticTag);
        Assert.Equal(0, destination.Length);
        Assert.Equal(0, destination.Position);
    }

    [Fact]
    public async Task ContentReadRejectsJsonEnvelopeAndResetsDestination()
    {
        using var handler = new StubHttpMessageHandler((_, _) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"success\":false}", Encoding.UTF8, "application/json"),
            }));
        using var http = new HttpClient(handler);
        using var destination = new MemoryStream();

        var result = await new DsmApiClient(http).ReadChatAttachmentContentAsync(
            Profile,
            Session,
            FileCapability,
            new ChatAttachmentContentReadRequest("post-content-3", destination, ExpectedLength: 0));

        Assert.Equal(ChatAttachmentContentReadStatus.Failed, result.Status);
        Assert.Equal(MutationErrorCategory.Server, result.ErrorCategory);
        Assert.True(result.DestinationWasCleared);
        Assert.Equal("chat.attachment-save.response-invalid", result.DiagnosticTag);
        Assert.Equal(0, destination.Length);
    }

    [Fact]
    public async Task ContentReadCancellationDuringCopyResetsPartialDestination()
    {
        var payload = new byte[64 * 1_024 + 1];
        using var cancellation = new CancellationTokenSource();
        using var handler = new StubHttpMessageHandler((_, _) =>
            Task.FromResult(BinaryResponse(payload)));
        using var http = new HttpClient(handler);
        using var destination = new CancellingWriteMemoryStream(cancellation);

        var result = await new DsmApiClient(http).ReadChatAttachmentContentAsync(
            Profile,
            Session,
            FileCapability,
            new ChatAttachmentContentReadRequest("post-content-4", destination, payload.Length),
            cancellationToken: cancellation.Token);

        Assert.Equal(ChatAttachmentContentReadStatus.CancelledDuringRead, result.Status);
        Assert.True(result.BytesWritten > 0);
        Assert.True(result.DestinationWasCleared);
        Assert.Equal("chat.attachment-save.cancelled-during-read", result.DiagnosticTag);
        Assert.Equal(0, destination.Length);
        Assert.Equal(0, destination.Position);
    }

    [Fact]
    public async Task ContentReadRejectsNonemptyCallerDestinationWithoutChangingIt()
    {
        var sends = 0;
        using var handler = new StubHttpMessageHandler((_, _) =>
        {
            sends++;
            return Task.FromResult(BinaryResponse([0x01]));
        });
        using var http = new HttpClient(handler);
        using var destination = new MemoryStream([0xAA]);
        destination.Position = 0;

        var result = await new DsmApiClient(http).ReadChatAttachmentContentAsync(
            Profile,
            Session,
            FileCapability,
            new ChatAttachmentContentReadRequest("post-content-5", destination, ExpectedLength: 1));

        Assert.Equal(ChatAttachmentContentReadStatus.Failed, result.Status);
        Assert.Equal(MutationErrorCategory.Validation, result.ErrorCategory);
        Assert.False(result.DestinationWasCleared);
        Assert.Equal("chat.attachment-save.invalid-input", result.DiagnosticTag);
        Assert.Equal(new byte[] { 0xAA }, destination.ToArray());
        Assert.Equal(0, sends);
    }

    private static void AssertReadFixture(
        string path,
        string expectedMethod,
        IReadOnlyList<string> expectedParameterNames,
        IReadOnlyList<string> expectedValues)
    {
        var fixture = JsonNode.Parse(ReadRepositoryFile(path))!.AsObject();
        var api = fixture["api"]!.AsObject();
        var transport = fixture["transport"]!.AsObject();
        var parameters = fixture["parameters"]!.AsArray()
            .Select(value => value!.AsObject())
            .ToArray();

        Assert.Equal("SYNO.Chat.Post.File", api["name"]!.GetValue<string>());
        Assert.Equal(expectedMethod, api["method"]!.GetValue<string>());
        Assert.Equal(2, api["preferredVersion"]!.GetValue<int>());
        Assert.Equal(2, api["resolvedVersion"]!.GetValue<int>());
        Assert.Equal("GET", transport["httpMethod"]!.GetValue<string>());
        Assert.Equal("form", transport["requestFormat"]!.GetValue<string>());
        Assert.Equal(expectedParameterNames, parameters.Select(value => value["name"]!.GetValue<string>()));
        Assert.Equal(expectedValues, parameters.Select(value => value["encodedValue"]!.GetValue<string>()));
        Assert.Equal(new[] { "cookie" }, fixture["authentication"]!["sessionLocations"]!.AsArray()
            .Select(value => value!.GetValue<string>()));
        Assert.Equal(new[] { "header" }, fixture["authentication"]!["synoTokenLocations"]!.AsArray()
            .Select(value => value!.GetValue<string>()));
        Assert.Equal("readOnlyAutomatic", fixture["policy"]!["retryPolicy"]!.GetValue<string>());
        Assert.Equal("none", fixture["policy"]!["readbackPolicy"]!.GetValue<string>());
    }

    private static HttpResponseMessage BinaryResponse(byte[] payload)
    {
        var content = new ByteArrayContent(payload);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = content,
        };
    }

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

    private sealed class CancellingWriteMemoryStream(CancellationTokenSource cancellation) : MemoryStream
    {
        public override ValueTask WriteAsync(
            ReadOnlyMemory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            var write = base.WriteAsync(buffer, cancellationToken);
            cancellation.Cancel();
            return write;
        }
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
