using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Downloads;

public sealed class DownloadTaskActionWireTests
{
    [Theory]
    [InlineData("seeding")]
    [InlineData("uploading")]
    [InlineData("checking")]
    public async Task RecordedActiveStatesCanBePaused(string status)
    {
        using var fixture = new Fixture { Status = status };
        var task = Assert.Single((await fixture.Repository.ListTasksAsync(0, 100)).Tasks);
        var result = await fixture.Repository.ControlTaskAsync(new(fixture.Profile.Id, task, DownloadTaskControlAction.Pause));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status); Assert.Equal("paused", result.Task!.RawStatus);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task PerTaskRejectionIsNotOverriddenByAnOuterSuccessOrMatchingReadback()
    {
        using var fixture = new Fixture { TaskError = 405 };
        var task = Assert.Single((await fixture.Repository.ListTasksAsync(0, 100)).Tasks);
        var result = await fixture.Repository.ControlTaskAsync(new(fixture.Profile.Id, task, DownloadTaskControlAction.Pause));
        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory);
    }

    [Fact]
    public async Task UnknownForcedCompletionDoesNotReplayOrAllowChangingMode()
    {
        using var fixture = new Fixture { LoseDeleteResponse = true };
        var task = Assert.Single((await fixture.Repository.ListTasksAsync(0, 100)).Tasks);
        var request = new DownloadTaskDeleteRequest(fixture.Profile.Id, task) { ForceComplete = true };
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.DeleteTaskAsync(request)).Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Repository.DeleteTaskAsync(request with { ForceComplete = false })).Result.ErrorCategory);
        await fixture.Repository.DeleteTaskAsync(request); Assert.Single(fixture.Writes);
        Assert.Equal("true", fixture.Writes[0]["force_complete"]);
        fixture.Exists = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.DeleteTaskAsync(request)).Result.Status);
        Assert.Single(fixture.Writes);
    }

    [Fact]
    public async Task DelimitedSingleTaskIdAndChangedIdentityNeverWrite()
    {
        using var fixture = new Fixture();
        var task = Assert.Single((await fixture.Repository.ListTasksAsync(0, 100)).Tasks);
        var result = await fixture.Repository.DeleteTaskAsync(new(fixture.Profile.Id, task with { Id = "1,2" }));
        Assert.False(result.Result.Submitted);
        result = await fixture.Repository.DeleteTaskAsync(new(fixture.Profile.Id, task with { Title = "Different" }));
        Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory); Assert.Empty(fixture.Writes);
    }

    private sealed class Fixture : IDisposable
    {
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        private readonly HttpClient _http;
        public IDownloadStationRepository Repository { get; }
        public string Status { get; set; } = "downloading";
        public int TaskError { get; init; }
        public bool Exists { get; set; } = true;
        public bool LoseDeleteResponse { get; init; }
        public List<Dictionary<string, string>> Writes { get; } = [];
        public Fixture()
        {
            _http = new(new Handler(this));
            Repository = new DsmRepository(Profile, new(Profile.Id, "synthetic-sid", null, null), new DsmApiClient(_http),
                new Dictionary<string, ApiCapability> { ["SYNO.DownloadStation.Task"] = new("SYNO.DownloadStation.Task", "entry.cgi", 1, 1, "FORM") });
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Empty(request.RequestUri!.Query); Assert.Equal("nas.invalid", request.RequestUri.Host);
                var text = await request.Content!.ReadAsStringAsync(token);
                var call = text.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                Assert.Equal("SYNO.DownloadStation.Task", call["api"]); Assert.Equal("1", call["version"]);
                JsonNode data;
                if (call["method"] == "list") data = new JsonObject { ["offset"] = 0, ["total"] = owner.Exists ? 1 : 0,
                    ["tasks"] = owner.Exists ? new JsonArray(new JsonObject { ["id"] = "1", ["title"] = "Synthetic task", ["status"] = owner.Status }) : new JsonArray() };
                else
                {
                    owner.Writes.Add(call);
                    if (call["method"] == "delete" && owner.LoseDeleteResponse) return new(HttpStatusCode.InternalServerError) { Content = new StringContent("{}") };
                    if (call["method"] == "pause") owner.Status = "paused";
                    if (call["method"] == "delete") owner.Exists = false;
                    data = new JsonArray(new JsonObject { ["id"] = "1", ["error"] = owner.TaskError });
                }
                return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
