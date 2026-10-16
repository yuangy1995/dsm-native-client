using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Downloads;

public sealed class DownloadCreationAcceptanceTests
{
    [Theory]
    [InlineData("{\"success\":true}")]
    [InlineData("{\"success\":true,\"data\":null}")]
    [InlineData("{\"success\":true,\"data\":{}}")]
    public async Task EmptySuccessEnvelopeAcceptsV3WithoutFabricatingATask(string envelope)
    {
        using var fixture = new Fixture(envelope);
        var outcome = await fixture.Repository.CreateTaskAsync(fixture.Request("chosen"));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Null(outcome.TaskId);
        Assert.Null(outcome.Task);
        Assert.True(outcome.Result.RequiresRefresh);
        var write = Assert.Single(fixture.Writes);
        Assert.Equal("3", write["version"]);
        Assert.Equal("chosen", write["destination"]);
        Assert.Equal("https://example.invalid/synthetic.iso", write["uri"]);
    }

    [Fact]
    public async Task HttpPermissionResponseAfterSubmissionDoesNotProveAnApiRejection()
    {
        using var fixture = new Fixture("{}", HttpStatusCode.Forbidden);
        var first = await fixture.Repository.CreateTaskAsync(fixture.Request("one"));
        var second = await fixture.Repository.CreateTaskAsync(fixture.Request("two"));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.Single(fixture.Writes);
    }

    [Theory]
    [InlineData(105, MutationResultStatus.PermissionDenied)]
    [InlineData(400, MutationResultStatus.ConfirmedFailure)]
    public async Task ExplicitApiFailureIsNotReportedAsAccepted(int code, MutationResultStatus expected)
    {
        using var fixture = new Fixture($"{{\"success\":false,\"error\":{{\"code\":{code}}}}}");
        var outcome = await fixture.Repository.CreateTaskAsync(fixture.Request(null));
        Assert.Equal(expected, outcome.Result.Status);
        Assert.Null(outcome.Task);
        Assert.Single(fixture.Writes);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly NasProfile _profile = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        private readonly HttpClient _http;
        private readonly string _envelope;
        private readonly HttpStatusCode _status;
        public DsmRepository Repository { get; }
        public List<Dictionary<string, string>> Writes { get; } = [];

        public Fixture(string envelope, HttpStatusCode status = HttpStatusCode.OK)
        {
            _envelope = envelope; _status = status;
            _http = new(new Handler(this));
            const string api = "SYNO.DownloadStation.Task";
            Repository = new(_profile, new(_profile.Id, "synthetic", null, null), new DsmApiClient(_http),
                new Dictionary<string, ApiCapability> { [api] = new(api, "entry.cgi", 1, 3, "FORM") });
        }

        public DownloadTaskCreateRequest Request(string? destination) =>
            new(_profile.Id, "https://example.invalid/synthetic.iso", destination);

        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method);
                Assert.Empty(request.RequestUri!.Query);
                var values = (await request.Content!.ReadAsStringAsync(token)).Split('&')
                    .Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                if (values["method"] == "create")
                {
                    owner.Writes.Add(values);
                    return Reply(owner._status, owner._envelope);
                }
                Assert.Equal("list", values["method"]);
                return Reply(HttpStatusCode.OK, "{\"success\":true,\"data\":{\"offset\":0,\"total\":0,\"tasks\":[]}}");
            }

            private static HttpResponseMessage Reply(HttpStatusCode status, string body) =>
                new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }

        public void Dispose() => _http.Dispose();
    }
}
