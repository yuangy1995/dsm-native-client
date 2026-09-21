using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Containers;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Containers;

public sealed class ContainerNetworkDetailsTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task ExistingV1ListProvidesDetailsWithoutAdditionalRequests(string format)
    {
        using var f = new Fixture(format); var snapshot = await f.Repository.LoadSnapshotAsync();
        var details = Assert.Single(snapshot.Networks.Items).Network!;
        Assert.Equal("bridge", details.Driver); Assert.Equal(2, details.ConnectedContainerCount); Assert.Equal(["web", "db"], details.ConnectedContainerNames);
        Assert.Equal("192.0.2.0/24", details.Subnet); Assert.Equal("192.0.2.1", details.Gateway); Assert.Equal("192.0.2.128/25", details.IpRange); Assert.True(details.IsIpv6Enabled);
        var call = Assert.Single(f.Calls, call => call["api"] == Fixture.NetworkApi);
        Assert.Equal("list", call["method"]); Assert.Equal("1", call["version"]); Assert.DoesNotContain("offset", call.Keys); Assert.DoesNotContain("limit", call.Keys);
        Assert.DoesNotContain("private-secret", JsonSerializer.Serialize(snapshot)); Assert.Equal(2, f.Calls.Count);
    }
    [Theory]
    [InlineData("{}")] [InlineData("{\"containers\":null}")] [InlineData("{\"containers\":[{}]}")]
    [InlineData("{\"containers\":[\"\"]}")] [InlineData("{\"container_count\":-1}")] [InlineData("{\"container_count\":1.5}")]
    [InlineData("{\"container_count\":1,\"using\":2}")]
    public async Task InvalidAttachmentsFailOnlyNetworkSection(string fields)
    {
        using var f = new Fixture(); f.Fields(fields); var snapshot = await f.Repository.LoadSnapshotAsync();
        Assert.Equal(ContainerManagerSectionStatus.Failed, snapshot.Networks.Status);
        Assert.Equal(ContainerManagerSectionStatus.Available, snapshot.Containers.Status); Assert.Single(snapshot.Containers.Items);
    }
    [Fact]
    public async Task KnownEmptyAndCountWithoutNamesAreDifferent()
    {
        using var f = new Fixture(); f.Fields("""{"containers":[]}""");
        var empty = Assert.Single((await f.Repository.LoadSnapshotAsync()).Networks.Items);
        Assert.Equal(0, empty.Network!.ConnectedContainerCount); Assert.Empty(empty.Network.ConnectedContainerNames!);
        f.Fields("""{"containers_count":"3"}""");
        var count = Assert.Single((await f.Repository.LoadSnapshotAsync()).Networks.Items);
        Assert.Equal(3, count.Network!.ConnectedContainerCount); Assert.Null(count.Network.ConnectedContainerNames);
        Assert.NotEqual(new ContainerResourceItem(empty).ConnectionsText, new ContainerResourceItem(count).ConnectionsText);
    }
    [Fact]
    public async Task WrongOptionalTypesAndPathShapesRemainUnknown()
    {
        using var f = new Fixture(); f.Fields("""{"containers":[],"enable_ipv6":"false","subnet":"/private/path","gateway":"private-secret","iprange":"192.0.2.0/33","driver":"/private/socket"}""");
        var details = Assert.Single((await f.Repository.LoadSnapshotAsync()).Networks.Items).Network!;
        Assert.Null(details.Driver); Assert.Null(details.Subnet); Assert.Null(details.Gateway); Assert.Null(details.IpRange); Assert.Null(details.IsIpv6Enabled);
    }
    [Fact]
    public void LegacyResourceConstructorRemainsSafeForNetworkTemplate()
    {
        var item = new ContainerResourceItem(new("id", "Synthetic", ContainerResourceKind.Network, ContainerOperationalState.Unknown));
        Assert.NotEmpty(item.NetworkSummary); Assert.NotEmpty(item.SubnetText); Assert.NotEmpty(item.ConnectionsText);
    }
    [Fact]
    public async Task AuthenticationAndCancellationDoNotBecomeEmptyDetails()
    {
        using var f = new Fixture(); f.NetworkError = 119;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadSnapshotAsync());
        using var cts = new CancellationTokenSource(); cts.Cancel(); var count = f.Calls.Count;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadSnapshotAsync(cts.Token)); Assert.Equal(count, f.Calls.Count);
    }
    [Fact]
    public async Task InvalidCapabilityMetadataCannotEnableNetworkRequests()
    {
        foreach (var wrongName in new[] { true, false })
        {
            using var f = new Fixture(); var capability = f.Capabilities[Fixture.NetworkApi];
            f.Capabilities[Fixture.NetworkApi] = wrongName ? capability with { Name = "unexpected" } : capability with { MinVersion = 0 };
            var snapshot = await f.Repository.LoadSnapshotAsync();
            Assert.Equal(ContainerManagerSectionStatus.Unavailable, snapshot.Networks.Status);
            Assert.Single(f.Calls); Assert.Equal("SYNO.Docker.Container", f.Calls[0]["api"]);
        }
    }
    private sealed class Fixture : IDisposable
    {
        public const string NetworkApi = "SYNO.Docker.Network";
        private readonly HttpClient _http;
        public IContainerManagerRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; }
        public List<Dictionary<string,string>> Calls { get; } = [];
        public int? NetworkError { get; set; }
        public JsonObject Network { get; private set; } = JsonNode.Parse("""{"id":"network-a","name":"Synthetic bridge","driver":"bridge","containers":["web","db"],"container_count":99,"subnet":"192.0.2.0/24","gateway":"192.0.2.1","iprange":"192.0.2.128/25","enable_ipv6":true,"environment":"private-secret"}""")!.AsObject();
        public void Fields(string fields)
        { Network = JsonNode.Parse(fields)!.AsObject(); Network["id"] = "network-a"; Network["name"] = "Synthetic"; }
        public Fixture(string format = "FORM")
        {
            var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
            _http = new(new Handler(this));
            Capabilities = new[] { "SYNO.Docker.Container", NetworkApi }.ToDictionary(name => name, name => new ApiCapability(name, "entry.cgi", 1, 9, format));
            Repository = new DsmRepository(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http),
                Capabilities);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                if (call["api"] == NetworkApi && owner.NetworkError is int code) return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = false, error = new { code } }), Encoding.UTF8, "application/json") };
                var data = call["api"] == NetworkApi ? new JsonObject { ["network"] = new JsonArray(owner.Network.DeepClone()) } : JsonNode.Parse("""{"containers":[{"id":"c1","name":"web","status":"running"}]}""")!.AsObject();
                return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
