using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasEthernetReadTests
{
    [Theory]
    [InlineData("FORM", false)]
    [InlineData("JSON", false)]
    [InlineData("FORM", true)]
    [InlineData("JSON", true)]
    public async Task ListsV2AndReadsEachPhysicalInterfaceWithV1(string format, bool array)
    {
        using var fixture = new Fixture(format) { DirectArray = array };
        var result = await fixture.Repository.LoadEthernetSnapshotAsync();
        Assert.Equal(0, result.FailedInterfaces);
        var item = Assert.Single(result.Interfaces);
        Assert.Equal("eth0", item.Id); Assert.Equal("Synthetic LAN", item.Name);
        Assert.False(item.DhcpEnabled); Assert.Equal("192.0.2.10", item.IpAddress);
        Assert.Equal("255.255.255.0", item.SubnetMask); Assert.Equal("192.0.2.1", item.Gateway);
        Assert.Equal(new[] { "192.0.2.53", "192.0.2.54" }, item.DnsServers);
        Assert.Equal(1500, item.Mtu); Assert.True(item.IsDefaultGateway); Assert.False(item.VlanEnabled);
        Assert.Equal(new[] { "list", "get" }, fixture.Calls.Select(call => call["method"]));
        Assert.Equal(new[] { "2", "1" }, fixture.Calls.Select(call => call["version"]));
        Assert.Equal(format == "JSON" ? "\"eth0\"" : "eth0", fixture.Calls[1]["ifname"]);
        Assert.Equal(MutationResultStatus.Unsupported, (await fixture.Repository.SaveEthernetInterfaceAsync(
            item.Id, true, null, null, null, null, null, null)).Status);
        Assert.Equal(2, fixture.Calls.Count);
    }

    [Fact]
    public async Task MissingOptionalFieldsNeverBecomeDefaultGatewayVlanOrMtuGuesses()
    {
        using var fixture = new Fixture();
        fixture.Detail = Json("""{"use_dhcp":true}""");
        var item = Assert.Single((await fixture.Repository.LoadEthernetSnapshotAsync()).Interfaces);
        Assert.True(item.DhcpEnabled); Assert.Null(item.Mtu); Assert.Null(item.VlanEnabled);
        Assert.Null(item.IsDefaultGateway); Assert.Null(item.VlanId); Assert.Null(item.ReportedDns);
    }

    [Fact]
    public async Task RecordedPrefixAliasesAndListFallbackAreSupported()
    {
        using var fixture = new Fixture();
        fixture.Rows = JsonNode.Parse("""[{"ifname":"eth0","title":"Synthetic fallback"}]""")!.AsArray();
        fixture.Detail = Json("""{"ethernet_use_dhcp":false,"ethernet_mtu_config":9000,"ethernet_enable_vlan":true,"ethernet_vlan_id":10,"ethernet_dns":"192.0.2.53"}""");
        var item = Assert.Single((await fixture.Repository.LoadEthernetSnapshotAsync()).Interfaces);
        Assert.Equal("Synthetic fallback", item.Name); Assert.False(item.DhcpEnabled);
        Assert.Equal(9000, item.Mtu); Assert.True(item.VlanEnabled); Assert.Equal(10, item.VlanId);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("""{"dhcp":true}""")]
    [InlineData("""{"ifname":"eth1","use_dhcp":true}""")]
    public async Task IncompleteOrWrongTargetDetailCannotInventAnInterface(string detail)
    {
        using var fixture = new Fixture(); fixture.Detail = Json(detail);
        var result = await fixture.Repository.LoadEthernetSnapshotAsync();
        Assert.Empty(result.Interfaces); Assert.Equal(1, result.FailedInterfaces);
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadEthernetInterfacesAsync());
    }

    [Fact]
    public async Task NonPhysicalAndUnsafeIdentifiersAreNeverSent()
    {
        using var fixture = new Fixture();
        fixture.Rows = JsonNode.Parse("""[{"ifname":"lo"},{"ifname":"bond0"},{"ifname":"eth0;reboot"},{"name":"no-id"},{"ifname":"eth0"}]""")!.AsArray();
        var result = await fixture.Repository.LoadEthernetSnapshotAsync();
        Assert.Single(result.Interfaces); Assert.Equal(2, result.FailedInterfaces);
        Assert.Equal(2, fixture.Calls.Count); Assert.Equal("eth0", fixture.Calls[1]["ifname"]);
    }

    [Fact]
    public async Task DuplicateIdsAndMalformedListsAreNotPresentedAsComplete()
    {
        using var fixture = new Fixture();
        fixture.Rows = JsonNode.Parse("""[{"ifname":"eth0"},{"ifname":"eth0"}]""")!.AsArray();
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadEthernetSnapshotAsync());
        Assert.Single(fixture.Calls);
        fixture.MalformedList = true;
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadEthernetSnapshotAsync());
    }

    [Fact]
    public async Task FailureOnOneInterfaceKeepsOtherReadableRowsAndFlagsPartialResult()
    {
        using var fixture = new Fixture();
        fixture.Rows = JsonNode.Parse("""[{"ifname":"eth0"},{"ifname":"eth1"}]""")!.AsArray();
        fixture.RejectId = "eth1";
        var result = await fixture.Repository.LoadEthernetSnapshotAsync();
        Assert.Single(result.Interfaces); Assert.Equal(1, result.FailedInterfaces);
        Assert.Equal(3, fixture.Calls.Count);
    }

    [Fact]
    public async Task AuthenticationFailureAndCancellationPropagate()
    {
        using var fixture = new Fixture() { RejectId = "eth0", ErrorCode = 119 };
        Assert.True((await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadEthernetSnapshotAsync())).AuthenticationFailure);
        using var cancelled = new Fixture(); using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => cancelled.Repository.LoadEthernetSnapshotAsync(cancellation.Token));
        Assert.Empty(cancelled.Calls);
    }

    [Theory]
    [InlineData(1, 1)]
    [InlineData(2, 3)]
    public async Task MissingListOrDetailVersionMakesZeroRequests(int minimum, int maximum)
    {
        using var fixture = new Fixture(minimum: minimum, maximum: maximum);
        Assert.Equal(102, (await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadEthernetSnapshotAsync())).Code);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task ArrayExceptionIsLimitedToRecordedEthernetList()
    {
        using var fixture = new Fixture() { DirectArray = true };
        await Assert.ThrowsAsync<DsmException>(() => fixture.Api.CallReadJsonObjectAsync(fixture.Profile, fixture.Session,
            new("SYNO.Core.System", "entry.cgi", 1, 2, "FORM"), 2, "list"));
    }

    private static JsonObject Json(string value) => JsonNode.Parse(value)!.AsObject();
    internal sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmSession Session { get; }
        public DsmApiClient Api { get; }
        public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<string> Hosts { get; } = [];
        public string Build { get; set; } = "69057";
        public bool LoseResponse { get; set; }
        public bool FailReadback { get; set; }
        public bool RejectWrite { get; set; }
        public Action? AfterWrite { get; set; }
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] == "set");
        public bool DirectArray { get; init; }
        public bool MalformedList { get; set; }
        public string? RejectId { get; set; }
        public int ErrorCode { get; init; } = 105;
        public JsonArray Rows { get; set; } = JsonNode.Parse("""[{"ifname":"eth0"},{"ifname":"lo"}]""")!.AsArray();
        public JsonObject Detail { get; set; } = Json("""{"ifname":"eth0","title":"Synthetic LAN","use_dhcp":false,"ip":"192.0.2.10","mask":"255.255.255.0","gateway":"192.0.2.1","dns":"192.0.2.53,192.0.2.54","mtu":1500,"is_default_gateway":true,"enable_vlan":false}""");
        public List<Dictionary<string, string>> Calls { get; } = [];
        public Fixture(string format = "FORM", int minimum = 1, int maximum = 9)
        {
            _http = new(new Handler(this)); Api = new(_http); Session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            Capabilities["SYNO.Core.Network.Ethernet"] = new("SYNO.Core.Network.Ethernet", "entry.cgi", minimum, maximum, format);
            Capabilities["SYNO.Core.Desktop.Initdata"] = new("SYNO.Core.Desktop.Initdata", "entry.cgi", 1, 1, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate(string? address = null, string? sid = null, string? account = null) =>
            new(Profile with { Host = address ?? Profile.Host, Username = account ?? Profile.Username },
                Session with { Sid = sid ?? Session.Sid }, Api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Contains(request.RequestUri!.Host, new[] { "nas.invalid", "reconnected.invalid" });
                owner.Hosts.Add(request.RequestUri.Host);
                Assert.Empty(request.RequestUri.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                if (call["method"] == "get_user_service")
                    return Reply(new JsonObject { ["Session"] = new JsonObject { ["productversion"] = "7.2.1", ["version"] = owner.Build, ["smallfixnumber"] = "12", ["is_admin"] = true } });
                if (call["method"] == "set")
                {
                    if (owner.RejectWrite) return new(HttpStatusCode.OK) { Content = new StringContent("""{"success":false,"error":{"code":105}}""", Encoding.UTF8, "application/json") };
                    var config = JsonNode.Parse(call["configs"])!.AsArray().Single()!.AsObject();
                    foreach (var pair in config) owner.Detail[pair.Key] = pair.Value?.DeepClone();
                    owner.AfterWrite?.Invoke();
                    if (owner.LoseResponse) throw new HttpRequestException("合成提交响应丢失");
                    token.ThrowIfCancellationRequested();
                    return Reply(new());
                }
                Assert.Contains(call["method"], new[] { "list", "get" });
                if (owner.Writes.Any() && owner.FailReadback) throw new HttpRequestException("合成回读失败");
                var id = call.GetValueOrDefault("ifname");
                if (id?.StartsWith('"') == true) id = JsonSerializer.Deserialize<string>(id);
                JsonNode data = call["method"] == "list" ? owner.MalformedList ? new JsonObject() :
                    owner.DirectArray ? owner.Rows.DeepClone() : new JsonObject { ["interfaces"] = owner.Rows.DeepClone() } : owner.Detail.DeepClone();
                var body = id is not null && id == owner.RejectId
                    ? new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = owner.ErrorCode } }
                    : new JsonObject { ["success"] = true, ["data"] = data };
                return new(HttpStatusCode.OK) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
            }
            private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK)
            { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
