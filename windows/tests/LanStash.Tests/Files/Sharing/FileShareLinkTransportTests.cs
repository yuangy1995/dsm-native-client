using System.Net;
using System.Text;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Sharing;

public sealed class FileShareLinkTransportTests
{
    private static readonly Guid ProfileId = Guid.Parse("11111111-1111-1111-1111-111111111111");

    [Fact]
    public async Task CreatePostsFixedV3FormExactlyOnceAndReturnsData()
    {
        var handler = new RecordingHandler(_ => Json(
            """{"success":true,"data":{"id":"new"}}"""));
        var result = await Client(handler).CreateFileShareLinkAsync(
            Profile(),
            Session(),
            Capability(),
            new Dictionary<string, string>
            {
                ["path"] = "[\"/share/a.txt\"]",
                ["password"] = " secret ",
            });

        Assert.Equal(FileShareLinkTransportStatus.ResponseReceived, result.Status);
        Assert.Equal("new", (result.Data as System.Text.Json.Nodes.JsonObject)?["id"]?.GetValue<string>());
        Assert.Equal(1, handler.Count);
        Assert.Equal("3", handler.Form!["version"]);
        Assert.Equal("create", handler.Form["method"]);
        Assert.Equal("[\"/share/a.txt\"]", handler.Form["path"]);
        Assert.Equal(" secret ", handler.Form["password"]);
    }

    [Fact]
    public async Task DeletePostsOneStableIdWithFixedV3FormExactlyOnce()
    {
        var handler = new RecordingHandler(_ => Json("""{"success":true,"data":{}}"""));

        var result = await Client(handler).DeleteFileShareLinkAsync(
            Profile(), Session(), Capability(), "link-1");

        Assert.Equal(FileShareLinkTransportStatus.ResponseReceived, result.Status);
        Assert.Equal(1, handler.Count);
        Assert.Equal("3", handler.Form!["version"]);
        Assert.Equal("delete", handler.Form["method"]);
        Assert.Equal("[\"link-1\"]", handler.Form["id"]);
        Assert.Equal(ProfileId, handler.ProfileId);
        Assert.Equal(DsmConnectionSource.DirectAddress, handler.ConnectionSource);
    }

    [Fact]
    public async Task InvalidOrPreCancelledDeleteMakesZeroRequests()
    {
        var handler = new RecordingHandler(_ => Json("""{"success":true,"data":{}}"""));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var invalid = await Client(handler).DeleteFileShareLinkAsync(
            Profile(), Session(), Capability(), " link-1 ");
        var cancelled = await Client(handler).DeleteFileShareLinkAsync(
            Profile(), Session(), Capability(), "link-1", cancellation.Token);

        Assert.Equal(FileShareLinkTransportStatus.Unsupported, invalid.Status);
        Assert.Equal(FileShareLinkTransportStatus.CancelledBeforeSubmission, cancelled.Status);
        Assert.Equal(0, handler.Count);
    }

    [Fact]
    public async Task DeleteNetworkFailureIsUnverifiedAndNeverReplayed()
    {
        var handler = new RecordingHandler(_ => throw new HttpRequestException("synthetic"));

        var result = await Client(handler).DeleteFileShareLinkAsync(
            Profile(), Session(), Capability(), "link-1");

        Assert.Equal(FileShareLinkTransportStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task PreCancelledAndInvalidCapabilitiesMakeZeroRequests()
    {
        var handler = new RecordingHandler(_ => Json("""{"success":true,"data":{}}"""));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var cancelled = await Client(handler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), Parameters(), cancellation.Token);
        var invalid = await Client(handler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability() with { MinVersion = 2 }, Parameters());

        Assert.Equal(FileShareLinkTransportStatus.CancelledBeforeSubmission, cancelled.Status);
        Assert.Equal(FileShareLinkTransportStatus.Unsupported, invalid.Status);
        Assert.Equal(0, handler.Count);
    }

    [Theory]
    [InlineData("date_available", "2026-01-01")]
    [InlineData("password", "12345678901234567")]
    [InlineData("path", "[\"https://evil.invalid/a\"]")]
    [InlineData("path", "[\"/share/../a\"]")]
    [InlineData("path", "not-json")]
    public async Task InvalidOrUnapprovedParametersMakeZeroRequests(string name, string value)
    {
        var handler = new RecordingHandler(_ => Json("""{"success":true,"data":{}}"""));
        var parameters = Parameters().ToDictionary(
            pair => pair.Key,
            pair => pair.Value,
            StringComparer.Ordinal);
        parameters[name] = value;

        var result = await Client(handler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), parameters);

        Assert.Equal(FileShareLinkTransportStatus.Unsupported, result.Status);
        Assert.Equal(0, handler.Count);
    }

    [Fact]
    public async Task NetworkFailureAfterSendIsUnverifiedAndNeverReplayed()
    {
        var handler = new RecordingHandler(_ => throw new HttpRequestException("synthetic"));

        var result = await Client(handler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), Parameters());

        Assert.Equal(FileShareLinkTransportStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task CancellationObservedInsideSendIsAfterSubmissionAndNeverReplayed()
    {
        var entered = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var handler = new RecordingHandler(async (_, token) =>
        {
            entered.SetResult(true);
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return Json("""{"success":true,"data":{}}""");
        });
        using var cancellation = new CancellationTokenSource();
        var operation = Client(handler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), Parameters(), cancellation.Token);
        await entered.Task;
        cancellation.Cancel();

        var result = await operation;

        Assert.Equal(FileShareLinkTransportStatus.CancellationRequestedAfterSubmission, result.Status);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task NonCooperativeSendCompletingAfterCancellationIsStillAfterSubmission()
    {
        var entered = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var handler = new RecordingHandler(async (_, _) =>
        {
            entered.SetResult(true);
            await release.Task;
            return Json("""{"success":true,"data":{"id":"new"}}""");
        });
        using var cancellation = new CancellationTokenSource();
        var operation = Client(handler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), Parameters(), cancellation.Token);
        await entered.Task;
        cancellation.Cancel();
        release.SetResult(true);

        var result = await operation;

        Assert.Equal(FileShareLinkTransportStatus.CancellationRequestedAfterSubmission, result.Status);
        Assert.Equal(1, handler.Count);
    }

    [Fact]
    public async Task PasswordLimitCountsTextElementsWithoutTrimming()
    {
        var acceptedHandler = new RecordingHandler(_ => Json(
            """{"success":true,"data":{"id":"new"}}"""));
        var rejectedHandler = new RecordingHandler(_ => Json(
            """{"success":true,"data":{"id":"new"}}"""));
        var accepted = string.Concat(Enumerable.Repeat("e\u0301", 16));
        var rejected = accepted + "x";
        var acceptedParameters = new Dictionary<string, string>(Parameters().ToDictionary(
            pair => pair.Key,
            pair => pair.Value,
            StringComparer.Ordinal)) { ["password"] = accepted };
        var rejectedParameters = new Dictionary<string, string>(Parameters().ToDictionary(
            pair => pair.Key,
            pair => pair.Value,
            StringComparer.Ordinal)) { ["password"] = rejected };

        var acceptedResult = await Client(acceptedHandler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), acceptedParameters);
        var rejectedResult = await Client(rejectedHandler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), rejectedParameters);

        Assert.Equal(FileShareLinkTransportStatus.ResponseReceived, acceptedResult.Status);
        Assert.Equal(accepted, acceptedHandler.Form!["password"]);
        Assert.Equal(FileShareLinkTransportStatus.Unsupported, rejectedResult.Status);
        Assert.Equal(0, rejectedHandler.Count);
    }

    [Theory]
    [InlineData(105, MutationErrorCategory.Permission)]
    [InlineData(115, MutationErrorCategory.Server)]
    [InlineData(106, MutationErrorCategory.Server)]
    [InlineData(999, MutationErrorCategory.Server)]
    public async Task ExplicitDsmFailureIsConfirmed(int code, MutationErrorCategory category)
    {
        var handler = new RecordingHandler(_ => Json(
            $"{{\"success\":false,\"error\":{{\"code\":{code}}}}}"));

        var result = await Client(handler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), Parameters());

        Assert.Equal(FileShareLinkTransportStatus.ConfirmedFailure, result.Status);
        Assert.Equal(category, result.ErrorCategory);
        Assert.Equal(1, handler.Count);
        Assert.DoesNotContain("/share", result.DiagnosticTag ?? string.Empty, StringComparison.Ordinal);
    }

    [Fact]
    public async Task InvalidJsonAndHttpFailureRemainUnverified()
    {
        var invalidHandler = new RecordingHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("not-json", Encoding.UTF8, "application/json"),
        });
        var httpHandler = new RecordingHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.BadGateway));

        var invalid = await Client(invalidHandler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), Parameters());
        var http = await Client(httpHandler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), Parameters());

        Assert.Equal(FileShareLinkTransportStatus.SubmittedButUnverified, invalid.Status);
        Assert.Equal(FileShareLinkTransportStatus.SubmittedButUnverified, http.Status);
        Assert.Equal(1, invalidHandler.Count);
        Assert.Equal(1, httpHandler.Count);
    }

    [Theory]
    [InlineData("{\"success\":\"true\",\"data\":{\"id\":\"new\"}}")]
    [InlineData("{\"success\":1,\"data\":{\"id\":\"new\"}}")]
    [InlineData("{\"success\":0,\"error\":{\"code\":105}}")]
    [InlineData("{\"success\":false,\"error\":{\"code\":\"105\"}}")]
    public async Task NonNativeEnvelopeFieldsRemainUnverified(string body)
    {
        var handler = new RecordingHandler(_ => Json(body));

        var result = await Client(handler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), Parameters());

        Assert.Equal(FileShareLinkTransportStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(1, handler.Count);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("\"not-an-object\"")]
    public async Task SuccessfulEnvelopePreservesNonObjectDataForStrictRepositoryRejection(string data)
    {
        var handler = new RecordingHandler(_ => Json($"{{\"success\":true,\"data\":{data}}}"));

        var result = await Client(handler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability(), Parameters());

        Assert.Equal(FileShareLinkTransportStatus.ResponseReceived, result.Status);
        Assert.False(result.Data is System.Text.Json.Nodes.JsonObject);
        Assert.Equal(1, handler.Count);
    }

    [Theory]
    [InlineData("//host/entry.cgi")]
    [InlineData("entry\\evil.cgi")]
    [InlineData("entry.cgi?x=1")]
    [InlineData("entry.cgi#fragment")]
    public async Task UnsafeCapabilityPathMakesZeroRequests(string path)
    {
        var handler = new RecordingHandler(_ => Json("""{"success":true,"data":{}}"""));

        var result = await Client(handler).CreateFileShareLinkAsync(
            Profile(), Session(), Capability() with { Path = path }, Parameters());

        Assert.Equal(FileShareLinkTransportStatus.Unsupported, result.Status);
        Assert.Equal(0, handler.Count);
    }

    private static DsmApiClient Client(HttpMessageHandler handler) => new(new HttpClient(handler));
    private static NasProfile Profile() =>
        new(ProfileId, "Synthetic", "https://nas.invalid", null, "tester");
    private static DsmSession Session() => new(ProfileId, "synthetic-sid", null, null);
    private static ApiCapability Capability() =>
        new("SYNO.FileStation.Sharing", "entry.cgi", 3, 3, "FORM");
    private static IReadOnlyDictionary<string, string> Parameters() =>
        new Dictionary<string, string> { ["path"] = "[\"/share/a.txt\"]" };
    private static HttpResponseMessage Json(string content) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(content, Encoding.UTF8, "application/json"),
    };

    private sealed class RecordingHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> _response;

        public RecordingHandler(Func<HttpRequestMessage, HttpResponseMessage> response)
            : this((request, _) => Task.FromResult(response(request)))
        {
        }

        public RecordingHandler(
            Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> response) =>
            _response = response;

        public int Count { get; private set; }
        public Dictionary<string, string>? Form { get; private set; }
        public Guid? ProfileId { get; private set; }
        public DsmConnectionSource? ConnectionSource { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Count++;
            if (WindowsCertificateTrustHandler.TryGetConnectionContext(
                    request, out var profileId, out var source))
            {
                ProfileId = profileId;
                ConnectionSource = source;
            }
            var content = await request.Content!.ReadAsStringAsync(cancellationToken);
            Form = content.Split('&', StringSplitOptions.RemoveEmptyEntries)
                .Select(value => value.Split('=', 2))
                .ToDictionary(
                    value => Uri.UnescapeDataString(value[0].Replace('+', ' ')),
                    value => Uri.UnescapeDataString(value[1].Replace('+', ' ')),
                    StringComparer.Ordinal);
            return await _response(request, cancellationToken);
        }
    }
}
