using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Containers;

public sealed class ContainerImageListContractTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task OfficialImageListUsesAllItemsAndNativeBoolean(string format)
    {
        using var f = new Fixture(format);
        f.ImageData = new() { ["images"] = new JsonArray(Enumerable.Range(0, 201).Select(index => (JsonNode)new JsonObject
            { ["id"] = $"synthetic-{index}", ["repository"] = $"synthetic/image-{index}", ["tags"] = new JsonArray("stable") }).ToArray()), ["total"] = 201, ["offset"] = 0, ["limit"] = -1 };
        var result = await f.Repository.LoadSnapshotAsync(); Assert.Equal(201, result.Images.Items.Count);
        var image = Assert.Single(f.Calls, call => call["api"] == "SYNO.Docker.Image");
        Assert.Equal("1", image["version"]); Assert.Equal("list", image["method"]);
        Assert.Equal("0", image["offset"]); Assert.Equal("-1", image["limit"]); Assert.Equal("false", image["show_dsm"]);
        Assert.DoesNotContain("show_dsm", Assert.Single(f.Calls, call => call["api"] == "SYNO.Docker.Container").Keys);
        Assert.All(f.Calls, call => Assert.Equal("list", call["method"]));
    }
    [Theory]
    [InlineData("{\"images\":[],\"total\":1}")]
    [InlineData("{\"images\":[],\"total\":true}")]
    [InlineData("{\"images\":[],\"total\":\"0\"}")]
    [InlineData("{\"images\":[],\"total\":0.5}")]
    [InlineData("{\"images\":[],\"offset\":1}")]
    [InlineData("{\"images\":[],\"offset\":null}")]
    public async Task PartialOrMalformedPaginationFailsOnlyImageSection(string response)
    {
        using var f = new Fixture(); f.ImageData = JsonNode.Parse(response)!.AsObject();
        var result = await f.Repository.LoadSnapshotAsync();
        Assert.Equal(ContainerManagerSectionStatus.Failed, result.Images.Status); Assert.Empty(result.Images.Items);
        Assert.Equal(ContainerManagerSectionStatus.Available, result.Containers.Status);
    }
    [Fact]
    public async Task ExplicitCompleteEmptyListRemainsEmptyNotFailed()
    {
        using var f = new Fixture(); f.ImageData = new() { ["images"] = new JsonArray(), ["total"] = 0, ["offset"] = 0, ["limit"] = -1 };
        var result = await f.Repository.LoadSnapshotAsync(); Assert.Equal(ContainerManagerSectionStatus.Available, result.Images.Status); Assert.Empty(result.Images.Items);
    }
    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        public IContainerManagerRepository Repository { get; }
        public JsonObject ImageData { get; set; } = new() { ["images"] = new JsonArray() };
        public List<Dictionary<string, string>> Calls { get; } = [];
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
            var capabilities = new[] { "SYNO.Docker.Container", "SYNO.Docker.Image" }.ToDictionary(name => name, name => new ApiCapability(name, "entry.cgi", 1, 9, format));
            Repository = new DsmRepository(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http), capabilities);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                var data = call["api"] == "SYNO.Docker.Image" ? owner.ImageData : new JsonObject { ["containers"] = new JsonArray() };
                return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
