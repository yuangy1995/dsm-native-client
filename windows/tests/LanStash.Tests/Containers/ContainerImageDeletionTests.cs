using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Containers;

public sealed class ContainerImageDeletionTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task DeletesOnlySelectedTagAndAcceptsRemainingImageId(string format)
    {
        using var fixture = new Fixture(format);
        var request = await fixture.RequestAsync("stable");
        Assert.True(fixture.Repository.CanDeleteImages);
        var result = await fixture.Repository.DeleteImagesAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(new[] { "latest" }, fixture.Images[0]!["tags"]!.AsArray().Select(node => node!.GetValue<string>()));
        var call = Assert.Single(fixture.Calls, call => call["method"] == "delete");
        Assert.Equal("1", call["version"]);
        Assert.Equal("[{\"repository\":\"synthetic/web\",\"tags\":[\"stable\"]}]", call["images"]);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(ImageDeleteFixture()), JsonNode.Parse(call["images"])));
        Assert.DoesNotContain("id", call.Keys);
        Assert.DoesNotContain("force", call.Keys);
        Assert.Equal(result, await fixture.Repository.DeleteImagesAsync(request));
        Assert.Empty(await fixture.Repository.GetImageDeletionRecoveriesAsync());
        Assert.Single(fixture.Calls, call => call["method"] == "delete");
    }

    [Fact]
    public async Task TagsExpandAndBatchGroupsRepositoriesWithoutLosingUnderlyingIds()
    {
        using var fixture = new Fixture("JSON");
        fixture.Images.Add(Image("synthetic-id", "synthetic/alias", "v1"));
        var snapshot = await fixture.Repository.LoadSnapshotAsync();
        Assert.Equal(3, snapshot.Images.Items.Count);
        Assert.Equal(3, snapshot.Images.Items.Select(item => item.Id).Distinct().Count());
        Assert.All(snapshot.Images.Items, item => Assert.Equal("synthetic-id", item.Image!.ImageId));
        var request = new ContainerImageDeleteRequest(fixture.Repository.ProfileId, snapshot.Images.Items, Guid.NewGuid(), true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.DeleteImagesAsync(request)).Status);
        var objects = JsonNode.Parse(Assert.Single(fixture.Calls, call => call["method"] == "delete")["images"])!.AsArray();
        Assert.Equal(2, objects.Count);
        Assert.Equal(2, objects[0]!["tags"]!.AsArray().Count);
    }

    [Fact]
    public async Task BareTagUsesIdentityAndMustNotDeleteOtherValidTags()
    {
        using var fixture = new Fixture("JSON");
        fixture.Images = new JsonArray(Image("<synthetic-container-image>", "synthetic/web", "<none>"));
        var request = await fixture.RequestAsync("<none>");
        fixture.Images.Add(Image("<synthetic-container-image>", "synthetic/alias", "latest"));
        Assert.False((await fixture.Repository.DeleteImagesAsync(request)).Submitted);
        fixture.Images.RemoveAt(1);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.DeleteImagesAsync(request)).Status);
        Assert.True(JsonNode.DeepEquals(JsonNode.Parse(ImageDeleteFixture("delete-image/synthetic-image")),
            JsonNode.Parse(Assert.Single(fixture.Calls, call => call["method"] == "delete")["images"])));
    }

    [Theory]
    [InlineData("synthetic/web:stable", false)]
    [InlineData("docker.io/synthetic/web:stable", false)]
    [InlineData("index.docker.io/synthetic/web:stable", false)]
    [InlineData("synthetic/web:latest", true)]
    [InlineData("synthetic/web", true)]
    public async Task OccupancyIncludesStoppedContainersButDoesNotBlockOtherTags(string image, bool allowed)
    {
        using var fixture = new Fixture("FORM");
        var request = await fixture.RequestAsync("stable");
        fixture.Containers.Add(new JsonObject { ["image"] = image, ["status"] = "stopped" });
        Assert.Equal(allowed, (await fixture.Repository.DeleteImagesAsync(request)).Submitted);
    }

    [Theory]
    [InlineData("sha256:synthetic", true)]
    [InlineData("synthetic/web:stable@sha256:synthetic", false)]
    public async Task DigestOccupancyUsesOriginalImageIdAndOfficialTagSelection(string image, bool allowed)
    {
        using var fixture = new Fixture("JSON");
        var request = await fixture.RequestAsync("stable");
        fixture.Containers.Add(new JsonObject { ["Image"] = image, ["ImageID"] = "synthetic-id" });
        Assert.Equal(allowed, (await fixture.Repository.DeleteImagesAsync(request)).Submitted);
    }

    [Theory]
    [InlineData("changed-id")]
    [InlineData("missing-tags")]
    [InlineData("invalid-tags")]
    [InlineData("numeric-id")]
    [InlineData("numeric-repository")]
    [InlineData("duplicate-tags")]
    [InlineData("ambiguous-address")]
    [InlineData("partial-images")]
    [InlineData("partial-containers")]
    [InlineData("unknown-container")]
    [InlineData("no-confirmation")]
    [InlineData("wrong-profile")]
    public async Task UncertainOrChangedPreflightDoesNotWrite(string scenario)
    {
        using var fixture = new Fixture("JSON");
        var request = await fixture.RequestAsync("stable");
        if (scenario == "changed-id") fixture.Images[0]!["id"] = "replacement-id";
        if (scenario == "missing-tags") fixture.Images[0]!.AsObject().Remove("tags");
        if (scenario == "invalid-tags") fixture.Images[0]!["tags"] = new JsonArray("latest", 1);
        if (scenario == "numeric-id") fixture.Images[0]!["id"] = 123;
        if (scenario == "numeric-repository") fixture.Images[0]!["repository"] = 123;
        if (scenario == "duplicate-tags") fixture.Images[0]!["tags"] = new JsonArray("latest", "latest");
        if (scenario == "ambiguous-address") fixture.Images.Add(Image("replacement-id", "docker.io/synthetic/web", "stable"));
        if (scenario == "partial-images") fixture.PartialImages = true;
        if (scenario == "partial-containers") fixture.PartialContainers = true;
        if (scenario == "unknown-container") fixture.Containers.Add(new JsonObject { ["Image"] = "sha256:synthetic" });
        if (scenario == "no-confirmation") request = request with { RiskConfirmed = false };
        if (scenario == "wrong-profile") request = request with { ProfileId = Guid.NewGuid() };
        Assert.False((await fixture.Repository.DeleteImagesAsync(request)).Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "delete");
    }

    [Fact]
    public async Task UnknownReceiptLocksSameAddressEvenIfIdChangesAndReconnectOnlyReviews()
    {
        using var fixture = new Fixture("FORM") { LoseResponse = true };
        var request = await fixture.RequestAsync("stable");
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.DeleteImagesAsync(request)).Status);
        fixture.Images[0]!["id"] = "replacement-id";
        var replacement = await fixture.RequestAsync("stable");
        Assert.Equal(MutationErrorCategory.Conflict, (await fixture.Reconnect().DeleteImagesAsync(replacement)).ErrorCategory);
        Assert.Single(await fixture.Reconnect().GetImageDeletionRecoveriesAsync());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Reconnect().ReviewImageDeletionAsync(request.RequestId))!.Status);
        fixture.Images[0]!["tags"] = new JsonArray("latest");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Reconnect().ReviewImageDeletionAsync(request.RequestId))!.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "delete");
    }

    [Fact]
    public async Task PartialResultTracksTagsAndNeverReplaysBatch()
    {
        using var fixture = new Fixture("JSON") { RemoveOnlyOneTag = true };
        var request = await fixture.RequestAsync();
        var result = await fixture.Repository.DeleteImagesAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status);
        Assert.Equal(1, result.Counts.Succeeded); Assert.Equal(1, result.Counts.Unknown);
        fixture.Images.Clear();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.DeleteImagesAsync(request)).Status);
        Assert.Single(fixture.Calls, call => call["method"] == "delete");
    }

    [Fact]
    public async Task ExplicitPermissionRejectionIsNotReinterpretedAsSuccess()
    {
        using var fixture = new Fixture("FORM") { Reject = true };
        var request = await fixture.RequestAsync();
        var result = await fixture.Repository.DeleteImagesAsync(request);
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Status);
        fixture.Images.Clear();
        Assert.Equal(result, await fixture.Repository.DeleteImagesAsync(request));
        Assert.Empty(await fixture.Repository.GetImageDeletionRecoveriesAsync());
    }

    [Fact]
    public async Task CancellationAfterSubmissionRemainsReviewable()
    {
        using var cancellation = new CancellationTokenSource();
        using var fixture = new Fixture("JSON") { OnDelete = cancellation.Cancel };
        var request = await fixture.RequestAsync();
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await fixture.Repository.DeleteImagesAsync(request, cancellation.Token)).Status);
        fixture.Images.Clear();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ReviewImageDeletionAsync(request.RequestId))!.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "delete");
    }

    private static JsonObject Image(string id, string repository, params string[] tags) => new()
    { ["id"] = id, ["repository"] = repository, ["tags"] = new JsonArray(tags.Select(tag => (JsonNode?)JsonValue.Create(tag)).ToArray()) };

    private static string ImageDeleteFixture(string operation = "delete-image-tags/synthetic-selection")
    {
        for (var directory = new DirectoryInfo(Directory.GetCurrentDirectory()); directory is not null; directory = directory.Parent)
        {
            var path = Path.Combine(directory.FullName, $"contracts/request-fixtures/container-manager/{operation}/request.json");
            if (File.Exists(path)) return JsonNode.Parse(File.ReadAllText(path))!["parameters"]![0]!["encodedValue"]!.GetValue<string>();
        }
        throw new FileNotFoundException("缺少共享镜像标签删除夹具。");
    }

    private sealed class Fixture : IDisposable
    {
        private readonly NasProfile _profile = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        private readonly HttpClient _http;
        private readonly DsmApiClient _api;
        private readonly string _format;
        public IContainerManagerRepository Repository { get; }
        public JsonArray Images { get; set; } = new(Image("synthetic-id", "synthetic/web", "latest", "stable"));
        public JsonArray Containers { get; } = new();
        public bool PartialImages { get; set; }
        public bool PartialContainers { get; set; }
        public bool LoseResponse { get; init; }
        public bool Reject { get; init; }
        public bool RemoveOnlyOneTag { get; init; }
        public Action? OnDelete { get; init; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public Fixture(string format)
        { _format = format; _http = new(new Handler(this)); _api = new(_http); Repository = Reconnect(); }
        public IContainerManagerRepository Reconnect() => new DsmRepository(_profile,
            new(_profile.Id, "synthetic-sid", "synthetic-token", null), _api,
            new[] { "SYNO.Docker.Container", "SYNO.Docker.Image" }.ToDictionary(name => name, name => new ApiCapability(name, "entry.cgi", 1, 3, _format)));
        public async Task<ContainerImageDeleteRequest> RequestAsync(string? tag = null)
        {
            var snapshot = await Repository.LoadSnapshotAsync();
            Assert.Equal(ContainerManagerSectionStatus.Available, snapshot.Images.Status);
            return new(Repository.ProfileId, snapshot.Images.Items.Where(item => tag is null || item.Image!.Tag == tag).ToArray(), Guid.NewGuid(), true);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var body = await request.Content!.ReadAsStringAsync(token);
                var form = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(form);
                var data = new JsonObject();
                if (form["method"] == "list")
                {
                    var image = form["api"] == "SYNO.Docker.Image";
                    var rows = image ? owner.Images : owner.Containers;
                    data[image ? "images" : "containers"] = rows.DeepClone(); data["offset"] = 0;
                    data["total"] = rows.Count + ((image ? owner.PartialImages : owner.PartialContainers) ? 1 : 0);
                }
                else
                {
                    Assert.Equal("SYNO.Docker.Image", form["api"]); Assert.Equal("delete", form["method"]);
                    owner.OnDelete?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.Reject) return Reply("{\"success\":false,\"error\":{\"code\":105}}");
                    if (owner.LoseResponse) throw new HttpRequestException("synthetic");
                    var removed = 0;
                    foreach (var target in JsonNode.Parse(form["images"])!.AsArray())
                    foreach (var row in owner.Images.ToArray())
                    {
                        if (target!["identity"] is { } identity && row!["id"]!.GetValue<string>() == identity.GetValue<string>()) owner.Images.Remove(row);
                        else if (target["repository"] is { } repository && row!["repository"]!.GetValue<string>() == repository.GetValue<string>())
                        {
                            var tags = row["tags"]!.AsArray();
                            foreach (var tag in tags.ToArray())
                                if (target["tags"]!.AsArray().Any(selected => selected!.GetValue<string>() == tag!.GetValue<string>()) &&
                                    (!owner.RemoveOnlyOneTag || removed == 0)) { tags.Remove(tag); removed++; }
                            if (tags.Count == 0) owner.Images.Remove(row);
                        }
                    }
                }
                return Reply(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString());
            }
            private static HttpResponseMessage Reply(string json) => new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
