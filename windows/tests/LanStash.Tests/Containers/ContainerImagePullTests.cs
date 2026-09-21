using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Containers;

public sealed class ContainerImagePullTests
{
    [Theory]
    [InlineData("FORM", false)]
    [InlineData("FORM", true)]
    [InlineData("JSON", false)]
    [InlineData("JSON", true)]
    public async Task StartAndStatusUseFixedVersionAndPreserveOpaqueTaskIdType(string format, bool numeric)
    {
        using var fixture = new Fixture(format) { NumericTaskId = numeric };
        var request = fixture.Request();
        Assert.True(fixture.Repository.CanPullImages);
        var first = await fixture.Repository.PullImageAsync(request);
        Assert.Equal(ContainerImagePullStage.Downloading, first.Stage); Assert.Equal(25, first.Percentage);
        var start = Assert.Single(fixture.Calls, call => call["method"] == "pull_start");
        Assert.Equal(format == "JSON" ? "\"synthetic/web\"" : "synthetic/web", start["repository"]);
        Assert.Equal(format == "JSON" ? "\"stable\"" : "stable", start["tag"]);
        Assert.Equal("1", start["version"]);
        AssertFixture(start, "pull-start", format);
        var status = Assert.Single(fixture.Calls, call => call["method"] == "pull_status");
        Assert.Equal(numeric ? "42" : format == "JSON" ? "\"synthetic-task\"" : "synthetic-task", status["task_id"]);
        if (!numeric) AssertFixture(status, "pull-status", format);
        Assert.DoesNotContain("password", start.Keys); Assert.DoesNotContain("registry", start.Keys);
        fixture.Finished = true;
        var ready = await fixture.Repository.ReviewImagePullAsync(request.RequestId);
        Assert.Equal(ContainerImagePullStage.Ready, ready!.Stage);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, ready.Outcome.Status);
        Assert.Empty(await fixture.Repository.GetImagePullRecoveriesAsync());
        Assert.Equal(ready, await fixture.Repository.PullImageAsync(request));
        Assert.Single(fixture.Calls, call => call["method"] == "pull_start");
    }

    [Fact]
    public async Task ExistingTagAndFullProgressCannotCompleteAnUnfinishedTask()
    {
        using var fixture = new Fixture("JSON") { Current = 100 };
        var result = await fixture.Repository.PullImageAsync(fixture.Request());
        Assert.Equal(ContainerImagePullStage.Downloading, result.Stage); Assert.Equal(100, result.Percentage);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Outcome.Status);
        Assert.Single(await fixture.Repository.GetImagePullRecoveriesAsync());
    }

    [Theory]
    [InlineData("missing-image")]
    [InlineData("wrong-repository")]
    [InlineData("wrong-tag")]
    [InlineData("missing-finished")]
    [InlineData("string-finished")]
    [InlineData("partial-list")]
    [InlineData("status-rejected")]
    public async Task FinishedMustBeTypedBoundAndFollowedByCompleteImageReadback(string scenario)
    {
        using var fixture = new Fixture("JSON") { Finished = true, Scenario = scenario };
        var request = fixture.Request();
        var result = await fixture.Repository.PullImageAsync(request);
        Assert.Equal(ContainerImagePullStage.NeedsReview, result.Stage);
        Assert.NotEqual(MutationResultStatus.ConfirmedSuccess, result.Outcome.Status);
        fixture.Scenario = "";
        var final = await fixture.Reconnect().ReviewImagePullAsync(request.RequestId);
        Assert.Equal(ContainerImagePullStage.Ready, final!.Stage);
        Assert.Single(fixture.Calls, call => call["method"] == "pull_start");
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MissingReceiptNeverGuessesTaskOrReplaysByTarget(bool networkLoss)
    {
        using var fixture = new Fixture("FORM") { MissingReceipt = !networkLoss, LoseReceipt = networkLoss };
        var request = fixture.Request();
        Assert.Equal(ContainerImagePullStage.AwaitingReceipt, (await fixture.Repository.PullImageAsync(request)).Stage);
        Assert.Equal(ContainerImagePullStage.AwaitingReceipt, (await fixture.Reconnect().PullImageAsync(request)).Stage);
        var conflict = await fixture.Repository.PullImageAsync(request with { RequestId = Guid.NewGuid() });
        Assert.Equal(MutationErrorCategory.Conflict, conflict.Outcome.ErrorCategory);
        Assert.False(conflict.Outcome.Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "pull_status");
        Assert.Single(fixture.Calls, call => call["method"] == "pull_start");
    }

    [Fact]
    public async Task ExplicitRejectionIsTerminalAndSameRequestCannotReplay()
    {
        using var fixture = new Fixture("JSON") { Reject = true };
        var request = fixture.Request(); var result = await fixture.Repository.PullImageAsync(request);
        Assert.Equal(ContainerImagePullStage.Rejected, result.Stage);
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Outcome.Status);
        Assert.Equal(result, await fixture.Repository.PullImageAsync(request));
        Assert.Empty(await fixture.Repository.GetImagePullRecoveriesAsync());
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "pull_status");
    }

    [Theory]
    [InlineData("confirmation")]
    [InlineData("profile")]
    [InlineData("tag")]
    [InlineData("invalid-target")]
    public async Task InvalidPreflightDoesNotStart(string scenario)
    {
        using var fixture = new Fixture("JSON"); var request = fixture.Request();
        if (scenario == "confirmation") request = request with { RiskConfirmed = false };
        if (scenario == "profile") request = request with { ProfileId = Guid.NewGuid() };
        if (scenario == "tag") request = request with { Tag = "missing" };
        if (scenario == "invalid-target") request = request with { Repository = "user@registry.invalid" };
        Assert.False((await fixture.Repository.PullImageAsync(request)).Outcome.Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "pull_start");
    }

    [Fact]
    public async Task CancellationAfterStartRetainsReceiptAndOnlyReviews()
    {
        using var cancellation = new CancellationTokenSource();
        using var fixture = new Fixture("JSON") { OnStart = cancellation.Cancel };
        var request = fixture.Request();
        var result = await fixture.Repository.PullImageAsync(request, cancellation.Token);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, result.Outcome.Status);
        Assert.Single(await fixture.Repository.GetImagePullRecoveriesAsync());
        await fixture.Repository.ReviewImagePullAsync(request.RequestId);
        Assert.Single(fixture.Calls, call => call["method"] == "pull_start");
    }

    [Fact]
    public async Task PullAndDeleteOfSameTagAreMutuallyExclusive()
    {
        using var fixture = new Fixture("JSON");
        var request = fixture.Request();
        await fixture.Repository.PullImageAsync(request);
        var images = (await fixture.Repository.LoadSnapshotAsync()).Images.Items;
        var deletion = new ContainerImageDeleteRequest(fixture.Repository.ProfileId, images, Guid.NewGuid(), true);
        Assert.False((await fixture.Repository.DeleteImagesAsync(deletion)).Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "delete");
    }

    [Fact]
    public async Task UnknownDeletionBlocksStartingPullOfSameTag()
    {
        using var fixture = new Fixture("FORM");
        var snapshot = await fixture.Repository.LoadSnapshotAsync();
        var deletion = await fixture.Repository.DeleteImagesAsync(new(fixture.Repository.ProfileId, snapshot.Images.Items, Guid.NewGuid(), true));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, deletion.Status);
        var pull = await fixture.Repository.PullImageAsync(fixture.Request());
        Assert.False(pull.Outcome.Submitted); Assert.Equal(MutationErrorCategory.Conflict, pull.Outcome.ErrorCategory);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "pull_start");
    }

    [Fact]
    public async Task KnownTaskRemainsReviewableWithoutRegistryCapability()
    {
        using var fixture = new Fixture("JSON"); var request = fixture.Request();
        await fixture.Repository.PullImageAsync(request); fixture.Finished = true;
        var repository = fixture.Reconnect(includeRegistry: false);
        Assert.False(repository.CanPullImages);
        Assert.Equal(ContainerImagePullStage.Ready, (await repository.ReviewImagePullAsync(request.RequestId))!.Stage);
        Assert.Single(fixture.Calls, call => call["method"] == "pull_start");
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(101)]
    public async Task InvalidProgressIsNotPresentedAsAValidPercentage(int current)
    {
        using var fixture = new Fixture("JSON") { Current = current };
        var result = await fixture.Repository.PullImageAsync(fixture.Request());
        Assert.Equal(ContainerImagePullStage.Downloading, result.Stage); Assert.Null(result.Percentage);
    }

    private static void AssertFixture(Dictionary<string, string> call, string operation, string format)
    {
        for (var directory = new DirectoryInfo(Directory.GetCurrentDirectory()); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, $"contracts/request-fixtures/container-manager/{operation}/synthetic-task/request.json");
            if (!File.Exists(path)) continue;
            var fixture = JsonNode.Parse(File.ReadAllText(path))!;
            Assert.Equal(fixture["api"]!["name"]!.GetValue<string>(), call["api"]);
            Assert.Equal(fixture["api"]!["method"]!.GetValue<string>(), call["method"]);
            foreach (var parameter in fixture["parameters"]!.AsArray())
            {
                var expected = parameter!["encodedValue"]!.GetValue<string>();
                Assert.Equal(format == "JSON" ? JsonSerializer.Serialize(expected) : expected, call[parameter["name"]!.GetValue<string>()]);
            }
            return;
        }
        throw new FileNotFoundException("缺少共享镜像下载夹具。");
    }

    private sealed class Fixture : IDisposable
    {
        private readonly NasProfile _profile = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        private readonly HttpClient _http; private readonly DsmApiClient _api; private readonly string _format;
        public IContainerManagerRepository Repository { get; }
        public bool NumericTaskId { get; init; }
        public bool MissingReceipt { get; init; }
        public bool LoseReceipt { get; init; }
        public bool Reject { get; init; }
        public bool Finished { get; set; }
        public int Current { get; init; } = 25;
        public string Scenario { get; set; } = "";
        public Action? OnStart { get; init; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public Fixture(string format) { _format = format; _http = new(new Handler(this)); _api = new(_http); Repository = Reconnect(); }
        public IContainerManagerRepository Reconnect(bool includeRegistry = true) => new DsmRepository(_profile, new(_profile.Id, "synthetic-sid", "synthetic-token", null), _api,
            new[] { "SYNO.Docker.Image", "SYNO.Docker.Registry", "SYNO.Docker.Container" }.Where(name => includeRegistry || name != "SYNO.Docker.Registry")
                .ToDictionary(name => name, name => new ApiCapability(name, "entry.cgi", 1, 2, _format)));
        public ContainerImagePullRequest Request() => new(_profile.Id, "synthetic/web", "stable", Guid.NewGuid(), true);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var body = await request.Content!.ReadAsStringAsync(token);
                var form = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(form); var data = new JsonObject();
                if (form["api"] == "SYNO.Docker.Registry") data["tags"] = new JsonArray("stable", "latest");
                else if (form["api"] == "SYNO.Docker.Container") data["containers"] = new JsonArray();
                else if (form["method"] == "pull_start")
                {
                    owner.OnStart?.Invoke();
                    if (owner.Reject) return Reply("{\"success\":false,\"error\":{\"code\":105}}");
                    if (owner.LoseReceipt) throw new HttpRequestException("synthetic");
                    if (!owner.MissingReceipt) data["task_id"] = owner.NumericTaskId ? JsonValue.Create(42) : JsonValue.Create("synthetic-task");
                }
                else if (form["method"] == "pull_status")
                {
                    if (owner.Scenario == "status-rejected") return Reply("{\"success\":false,\"error\":{\"code\":400}}");
                    data["repository"] = owner.Scenario == "wrong-repository" ? "synthetic/other" : "docker.io/synthetic/web";
                    data["tag"] = owner.Scenario == "wrong-tag" ? "latest" : "stable";
                    if (owner.Scenario != "missing-finished") data["finished"] = owner.Scenario == "string-finished" ? JsonValue.Create("true") : JsonValue.Create(owner.Finished);
                    data["current"] = owner.Current; data["total"] = 100;
                }
                else if (form["method"] == "list")
                {
                    var afterStart = owner.Calls.Any(call => call["method"] == "pull_start");
                    var images = new JsonArray(new JsonObject { ["id"] = "synthetic-id", ["repository"] = "synthetic/web", ["tags"] = new JsonArray("stable") });
                    if (afterStart && owner.Scenario == "missing-image") images.Clear();
                    data["images"] = images; data["total"] = images.Count + (afterStart && owner.Scenario == "partial-list" ? 1 : 0); data["offset"] = 0;
                }
                else if (form["method"] == "delete") throw new HttpRequestException("合成删除回执丢失");
                else throw new InvalidOperationException("合成测试不允许其他写操作。");
                return Reply(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString());
            }
            private static HttpResponseMessage Reply(string json) => new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
