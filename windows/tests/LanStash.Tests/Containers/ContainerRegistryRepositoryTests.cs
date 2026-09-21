using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Containers;

public sealed class ContainerRegistryRepositoryTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task SearchAndTagsUseFixedV1DiscoveredPathAndCorrectWireTypes(string format)
    {
        using var f = new Fixture(format); f.Response = new() { ["data"] = new JsonArray(new JsonObject { ["name"] = "synthetic/image", ["star_count"] = 42, ["is_official"] = true }) };
        var images = await f.Repository.SearchRegistryAsync("  synthetic & image  ");
        var image = Assert.Single(images); Assert.Equal("synthetic/image", image.Name); Assert.Equal("docker.io", image.Registry); Assert.Equal(42, image.StarCount); Assert.True(image.IsOfficial);
        var search = Assert.Single(f.Calls); Assert.Equal("1", search["version"]); Assert.Equal("0", search["offset"]);
        Assert.Equal("50", search["limit"]); Assert.Equal("50", search["page_size"]);
        Assert.Equal(format == "JSON" ? JsonSerializer.Serialize("synthetic & image") : "synthetic & image", search["q"]);
        f.Response = new() { ["tags"] = new JsonArray("stable", new JsonObject { ["tag"] = "latest" }, new JsonObject { ["name"] = "stable" }) };
        Assert.Equal(new[] { "stable", "latest" }, await f.Repository.LoadRegistryTagsAsync(" synthetic/image "));
        var tags = f.Calls.Last(); Assert.Equal("tags", tags["method"]); Assert.Equal("1", tags["version"]);
        Assert.Equal(format == "JSON" ? "\"synthetic/image\"" : "synthetic/image", tags["repo"]);
        Assert.DoesNotContain("offset", tags.Keys); Assert.DoesNotContain("page_size", tags.Keys);
        Assert.All(f.Calls, call => Assert.Contains(call["method"], new[] { "search", "tags" }));
    }
    [Theory]
    [InlineData("data")] [InlineData("items")] [InlineData("results")]
    public async Task SearchReadsRecordedRootsAndDeduplicatesByRegistryAndName(string root)
    {
        using var f = new Fixture(); var item = new JsonObject { ["repository"] = "synthetic/image", ["registry"] = "registry.invalid", ["description"] = "Synthetic description" };
        f.Response = new() { [root] = new JsonArray(item, item.DeepClone(), new JsonObject { ["repo"] = "synthetic/image" }) };
        var images = await f.Repository.SearchRegistryAsync("synthetic"); Assert.Equal(2, images.Count);
        Assert.Equal("Synthetic description", images[0].Description); Assert.Null(images[0].StarCount); Assert.Null(images[0].IsOfficial);
    }
    [Theory]
    [InlineData("data")] [InlineData("items")] [InlineData("tags")]
    public async Task TagsPreserveOrderAndCaseWithRecordedObjectAndStringForms(string root)
    {
        using var f = new Fixture(); f.Response = new() { [root] = new JsonArray("v1", new JsonObject { ["name"] = "V1" }, new JsonObject { ["tag"] = "v1" }) };
        Assert.Equal(new[] { "v1", "V1" }, await f.Repository.LoadRegistryTagsAsync("synthetic/image"));
    }
    [Fact]
    public async Task RootArrayTransportShapeWorksForSearchAndStringTags()
    {
        using var f = new Fixture { ArrayResponse = new JsonArray(new JsonObject { ["name"] = "synthetic/image" }) };
        Assert.Equal("synthetic/image", Assert.Single(await f.Repository.SearchRegistryAsync("synthetic")).Name);
        f.ArrayResponse = new JsonArray("latest", new JsonObject { ["tag"] = "stable" }, "latest");
        Assert.Equal(new[] { "latest", "stable" }, await f.Repository.LoadRegistryTagsAsync("synthetic/image"));
    }
    [Fact]
    public async Task OptionalInvalidOrConflictingFlagsNeverBecomeTrustBadgesOrZeroStars()
    {
        using var f = new Fixture(); f.Response = new() { ["items"] = new JsonArray(new JsonObject
        { ["name"] = "synthetic/image", ["is_official"] = "true", ["is_trusted"] = true, ["trusted"] = false, ["is_automated"] = new JsonObject(), ["star_count"] = -1 }) };
        var image = Assert.Single(await f.Repository.SearchRegistryAsync("synthetic"));
        Assert.Null(image.IsOfficial); Assert.Null(image.IsTrusted); Assert.Null(image.IsAutomated); Assert.Null(image.StarCount);
    }
    [Fact]
    public async Task MalformedSearchResponsesNeverMasqueradeAsEmptyOrPartialSuccess()
    {
        using var f = new Fixture();
        JsonObject[] malformed = [new(), new() { ["data"] = new JsonObject() }, new() { ["items"] = new JsonArray("invalid") },
            new() { ["items"] = new JsonArray(new JsonObject { ["name"] = 123 }) },
            new() { ["items"] = new JsonArray(new JsonObject { ["name"] = "one", ["repository"] = "other" }) },
            new() { ["items"] = new JsonArray(new JsonObject { ["name"] = "one", ["registry"] = true }) },
            new() { ["data"] = new JsonArray(), ["items"] = new JsonArray(new JsonObject { ["name"] = "one" }) }];
        foreach (var response in malformed) { f.Response = response; await Assert.ThrowsAsync<DsmException>(() => f.Repository.SearchRegistryAsync("synthetic")); }
        f.Response = new() { ["data"] = new JsonArray(Enumerable.Range(0, 51).Select(index => (JsonNode)new JsonObject { ["name"] = $"synthetic-{index}" }).ToArray()) };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.SearchRegistryAsync("synthetic"));
        f.Response = new() { ["data"] = new JsonArray() }; Assert.Empty(await f.Repository.SearchRegistryAsync("synthetic"));
    }
    [Fact]
    public async Task MalformedTagsFailWithoutReturningPartialSelection()
    {
        using var f = new Fixture();
        foreach (var bad in new JsonNode?[] { null, JsonValue.Create(1), JsonValue.Create(" "), new JsonObject(), new JsonObject { ["tag"] = "one", ["name"] = "two" } })
        {
            f.Response = new() { ["tags"] = new JsonArray("valid", bad) };
            await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadRegistryTagsAsync("synthetic/image"));
        }
        f.Response = new() { ["tags"] = new JsonArray() }; Assert.Empty(await f.Repository.LoadRegistryTagsAsync("synthetic/image"));
    }
    [Fact]
    public async Task MissingIncompatibleAndMisnamedCapabilityNeverSendRequests()
    {
        using var f = new Fixture();
        foreach (var capability in new ApiCapability?[] { null, new("SYNO.Docker.Registry", "registry-synthetic.cgi", 2, 9, "FORM"),
            new("SYNO.Docker.Registry", "registry-synthetic.cgi", 0, 9, "FORM"), new("different", "registry-synthetic.cgi", 1, 9, "FORM"),
            new("SYNO.Docker.Registry", "registry-synthetic.cgi", 1, 9, "UNKNOWN") })
        {
            f.Capabilities.Clear(); if (capability is not null) f.Capabilities["SYNO.Docker.Registry"] = capability;
            Assert.False(f.Repository.CanBrowseRegistry);
            await Assert.ThrowsAsync<DsmException>(() => f.Repository.SearchRegistryAsync("synthetic"));
            await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadRegistryTagsAsync("synthetic/image"));
        }
        Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task InvalidInputWrongProfileAndCancellationNeverSendRequests()
    {
        using var f = new Fixture();
        foreach (var query in new[] { " ", "bad\nquery", new string('q', 201) }) await Assert.ThrowsAsync<ArgumentException>(() => f.Repository.SearchRegistryAsync(query));
        foreach (var repo in new[] { " ", "bad\rrepo", new string('r', 501) }) await Assert.ThrowsAsync<ArgumentException>(() => f.Repository.LoadRegistryTagsAsync(repo));
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.SearchRegistryAsync("synthetic", cancelled.Token));
        var wrong = new DsmRepository(f.Profile, new(Guid.NewGuid(), "synthetic-sid", null, null), f.Api, f.Capabilities);
        await Assert.ThrowsAsync<InvalidOperationException>(() => wrong.LoadRegistryTagsAsync("synthetic/image")); Assert.Empty(f.Calls);
    }
    [Theory]
    [InlineData(105)] [InlineData(106)]
    public async Task PermissionAndExpiredSessionArePropagatedNotEmptyResults(int code)
    {
        using var f = new Fixture { Reject = code };
        var error = await Assert.ThrowsAsync<DsmException>(() => f.Repository.SearchRegistryAsync("synthetic")); Assert.Equal(code, error.Code);
        Assert.Single(f.Calls);
    }
    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        public DsmApiClient Api { get; }
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public DsmRepository Repository { get; }
        public JsonObject Response { get; set; } = new() { ["data"] = new JsonArray() };
        public JsonArray? ArrayResponse { get; set; }
        public int? Reject { get; set; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); Api = new(_http);
            Capabilities.Add("SYNO.Docker.Registry", new("SYNO.Docker.Registry", "registry-synthetic.cgi", 1, 9, format));
            Repository = new(Profile, new(Profile.Id, "synthetic-sid", "synthetic-token", null), Api, Capabilities);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query); Assert.EndsWith("/webapi/registry-synthetic.cgi", request.RequestUri.AbsolutePath);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                Assert.Equal("SYNO.Docker.Registry", call["api"]); Assert.Contains(call["method"], new[] { "search", "tags" }); owner.Calls.Add(call);
                var payload = owner.Reject is int code ? JsonSerializer.Serialize(new { success = false, error = new { code } }) : JsonSerializer.Serialize(new { success = true, data = (JsonNode?)owner.ArrayResponse ?? owner.Response });
                return new(HttpStatusCode.OK) { Content = new StringContent(payload, Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
