using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDdnsReadContractTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task UsesProviderIdentityAndFixedVersionWithoutReadingSecrets(string format)
    {
        using var fixture = new Fixture(format);
        var provider = Assert.Single(await fixture.Repository.LoadDDNSProvidersAsync());
        Assert.Equal("Example", provider.Id); Assert.Equal("Synthetic provider", provider.Name); Assert.Null(provider.ServiceUrl);
        var record = Assert.Single(await fixture.Repository.LoadDDNSRecordsAsync());
        Assert.Equal("Example", record.Id); Assert.Equal(record.Id, record.ProviderId);
        Assert.True(record.IsEnabled); Assert.False(record.Heartbeat);
        Assert.Equal("2001:db8::1", record.Ipv6); Assert.Equal("eth0", record.InterfaceV4); Assert.Equal("BOTH", record.NetworkType);
        Assert.All(fixture.Calls, call => { Assert.Equal("1", call["version"]); Assert.Equal("list", call["method"]); });
        Assert.DoesNotContain("synthetic-secret", record.ToString());
        Assert.DoesNotContain(fixture.Calls, call => call.Keys.Contains("passwd"));
    }

    [Fact]
    public async Task ProviderProtocolDuplicatesKeepStableIdentityAndBetterName()
    {
        using var fixture = new Fixture();
        fixture.Providers = Json("""{"providers":[{"id":"Example"},{"provider":"Example","display":"Synthetic provider"},{"id":"Other","name":"Synthetic other"}]}""");
        var providers = await fixture.Repository.LoadDDNSProvidersAsync();
        Assert.Equal(2, providers.Count); Assert.Equal("Synthetic provider", providers[0].Name);
        Assert.Equal("Example", providers[0].Id);
    }

    [Fact]
    public async Task MinimalFiveFieldsAndOptionalMissingValuesAreValid()
    {
        using var fixture = new Fixture();
        fixture.Records = Json("""{"records":[{"provider":"Example","hostname":"nas.example.invalid","username":"","enable":false,"heartbeat":true}]}""");
        var record = Assert.Single(await fixture.Repository.LoadDDNSRecordsAsync());
        Assert.False(record.IsEnabled); Assert.True(record.Heartbeat); Assert.Null(record.ExternalIp); Assert.Null(record.Ipv6);
    }

    [Theory]
    [InlineData("provider")]
    [InlineData("hostname")]
    [InlineData("username")]
    [InlineData("enable")]
    [InlineData("heartbeat")]
    public async Task MissingRequiredFieldsNeverBecomeDefaults(string field)
    {
        using var fixture = new Fixture(); fixture.Records["records"]![0]!.AsObject().Remove(field);
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadDDNSRecordsAsync());
    }

    [Fact]
    public async Task DuplicateRecordAndMalformedContainersFailRatherThanAppearEmpty()
    {
        using var fixture = new Fixture();
        fixture.Records["records"]!.AsArray().Add(fixture.Records["records"]![0]!.DeepClone());
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadDDNSRecordsAsync());
        fixture.Providers = Json("""{"providers":[{"name":"not-an-identity"}]}""");
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadDDNSProvidersAsync());
        fixture.Records = Json("{}");
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadDDNSRecordsAsync());
    }

    [Theory]
    [InlineData("ip")]
    [InlineData("ipv6")]
    [InlineData("net")]
    [InlineData("interface_v4")]
    [InlineData("interface_v6")]
    public async Task PresentOptionalNetworkFieldsHaveStrictTypes(string field)
    {
        using var fixture = new Fixture(); fixture.Records["records"]![0]![field] = 123;
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadDDNSRecordsAsync());
    }

    [Fact]
    public async Task BothVersionOneCapabilitiesAreRequiredBeforeAnyRequest()
    {
        using var fixture = new Fixture();
        fixture.Capabilities.Remove("SYNO.Core.DDNS.Provider");
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadDDNSRecordsAsync());
        Assert.Empty(fixture.Calls);
        fixture.Capabilities["SYNO.Core.DDNS.Provider"] = new("SYNO.Core.DDNS.Provider", "entry.cgi", 2, 3, "FORM");
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadDDNSProvidersAsync());
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task RejectionAndCancellationDoNotLookLikeEmptyDirectories()
    {
        using var fixture = new Fixture() { ErrorCode = 105 };
        Assert.Equal(105, (await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadDDNSRecordsAsync())).Code);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Repository.LoadDDNSProvidersAsync(cancellation.Token));
        Assert.Single(fixture.Calls);
    }

    private static JsonObject Json(string source) => JsonNode.Parse(source)!.AsObject();
    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public int? ErrorCode { get; init; }
        public JsonObject Providers { get; set; } = Json("""{"providers":[{"id":"Example","display":"Synthetic provider","name":"old-name","passwd":"synthetic-secret"}]}""");
        public JsonObject Records { get; set; } = Json("""{"records":[{"id":"wrong-id","provider":"Example","hostname":"nas.example.invalid","username":"synthetic-user","enable":true,"heartbeat":false,"ip":"192.0.2.1","ipv6":"2001:db8::1","net":"BOTH","interface_v4":"eth0","interface_v6":"eth0","passwd":"synthetic-secret"}]}""");
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this));
            foreach (var name in new[] { "SYNO.Core.DDNS.Provider", "SYNO.Core.DDNS.Record" }) Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
            Repository = new(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http), Capabilities);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                var data = call["api"].EndsWith("Provider", StringComparison.Ordinal) ? owner.Providers : owner.Records;
                var response = owner.ErrorCode is int code ? new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = code } } :
                    new JsonObject { ["success"] = true, ["data"] = data.DeepClone() };
                return new(HttpStatusCode.OK) { Content = new StringContent(response.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
