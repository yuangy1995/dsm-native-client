using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasServiceSettingsReadTests
{
    [Theory]
    [InlineData("FORM", 1, 1)]
    [InlineData("JSON", 2, 2)]
    [InlineData("FORM", 9, 3)]
    public async Task TerminalUsesKnownVersionAndExactGetContract(string format, int maximum, int expected)
    {
        using var fixture = new Fixture("SYNO.Core.Terminal", """{"enable_ssh":true,"enable_telnet":false,"ssh_port":2222,"telnet_port":23}""", maximum, format);
        var settings = await fixture.Repository.LoadTerminalSettingsAsync();
        Assert.Equal(new NasTerminalSettings(true, 2222, false, null), settings);
        Assert.Equal(expected.ToString(), Assert.Single(fixture.Calls)["version"]);
        var result = await fixture.Repository.SaveTerminalSettingsAsync(settings);
        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.False(result.Submitted);
        Assert.Single(fixture.Calls);
    }

    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task ProxyUsesHttpFieldsAndVersionOneEvenWhenServerOffersMore(string format)
    {
        using var fixture = new Fixture("SYNO.Core.Network.Proxy", """{"enable":true,"http_host":"proxy.example.invalid","http_port":3128,"server":"wrong.example.invalid","port":80}""", 5, format);
        var settings = await fixture.Repository.LoadProxySettingsAsync();
        Assert.Equal(new NasProxySettings(true, "proxy.example.invalid", 3128), settings);
        Assert.Equal("1", Assert.Single(fixture.Calls)["version"]);
        var result = await fixture.Repository.SaveProxySettingsAsync(settings);
        Assert.Equal(MutationResultStatus.Unsupported, result.Status);
        Assert.Single(fixture.Calls);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("""{"enable_ssh":true}""")]
    [InlineData("""{"ssh_enable":true,"telnet_enable":false}""")]
    [InlineData("""{"enable_ssh":[],"enable_telnet":false}""")]
    public async Task TerminalDoesNotFabricateMissingRequiredSwitches(string data)
    {
        using var fixture = new Fixture("SYNO.Core.Terminal", data);
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadTerminalSettingsAsync());
        Assert.Single(fixture.Calls);
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("""{"enabled":true,"server":"proxy.example.invalid","port":80}""")]
    [InlineData("""{"enable":"invalid"}""")]
    public async Task ProxyDoesNotFabricateMissingRequiredSwitch(string data)
    {
        using var fixture = new Fixture("SYNO.Core.Network.Proxy", data);
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadProxySettingsAsync());
    }

    [Theory]
    [InlineData("null")]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("65536")]
    [InlineData("22.5")]
    [InlineData("\"invalid\"")]
    public async Task InvalidOptionalPortsAreNotGuessed(string port)
    {
        using var terminal = new Fixture("SYNO.Core.Terminal", $$"""{"enable_ssh":false,"enable_telnet":false,"ssh_port":{{port}}}""");
        Assert.Null((await terminal.Repository.LoadTerminalSettingsAsync()).SshPort);
        using var proxy = new Fixture("SYNO.Core.Network.Proxy", $$"""{"enable":false,"http_port":{{port}}}""");
        Assert.Null((await proxy.Repository.LoadProxySettingsAsync()).Port);
    }

    [Theory]
    [InlineData("SYNO.Core.Terminal", 4, 5, "FORM")]
    [InlineData("SYNO.Core.Network.Proxy", 2, 5, "FORM")]
    [InlineData("SYNO.Core.Terminal", 1, 3, "XML")]
    [InlineData("SYNO.Core.Network.Proxy", 1, 1, "XML")]
    [InlineData("SYNO.Core.Terminal", 2, 1, "FORM")]
    public async Task UnknownContractsMakeZeroRequests(string name, int minimum, int maximum, string format)
    {
        using var fixture = new Fixture(name, "{}", maximum, format, minimum);
        var error = await Assert.ThrowsAsync<DsmException>(fixture.ReadAsync);
        Assert.Equal(102, error.Code);
        Assert.Empty(fixture.Calls);
    }

    [Theory]
    [InlineData(103)]
    [InlineData(105)]
    [InlineData(119)]
    public async Task RejectionPropagatesWithoutTryingGuessedLoadMethod(int code)
    {
        using var fixture = new Fixture("SYNO.Core.Terminal", "{}") { ErrorCode = code };
        var error = await Assert.ThrowsAsync<DsmException>(fixture.ReadAsync);
        Assert.Equal(code, error.Code);
        Assert.Single(fixture.Calls);
    }

    [Fact]
    public async Task JsonReadExceptionDoesNotAllowBusinessParametersOrUnknownVersions()
    {
        using var fixture = new Fixture("SYNO.Core.Terminal", "{}", 5, "JSON");
        var capability = new ApiCapability("SYNO.Core.Terminal", "entry.cgi", 1, 5, "JSON");
        await Assert.ThrowsAsync<NotSupportedException>(() => fixture.Client.CallReadJsonObjectAsync(
            fixture.Profile, fixture.Session, capability, 3, "get", new Dictionary<string, string> { ["enable_ssh"] = "true" }));
        await Assert.ThrowsAsync<NotSupportedException>(() => fixture.Client.CallReadJsonObjectAsync(
            fixture.Profile, fixture.Session, capability, 4, "get"));
        await Assert.ThrowsAsync<NotSupportedException>(() => fixture.Client.CallReadJsonObjectAsync(
            fixture.Profile, fixture.Session, capability with { Name = "SYNO.Core.Network.Proxy" }, 2, "get"));
        await Assert.ThrowsAsync<ArgumentException>(() => fixture.Client.CallReadJsonObjectAsync(
            fixture.Profile, fixture.Session with { ProfileId = Guid.NewGuid() }, capability, 3, "get"));
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task PreCancelledReadMakesNoRequest()
    {
        using var fixture = new Fixture("SYNO.Core.Terminal", "{}");
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            fixture.Repository.LoadTerminalSettingsAsync(cancellation.Token));
        Assert.Empty(fixture.Calls);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        private readonly string _name;
        public List<Dictionary<string, string>> Calls { get; } = [];
        public int? ErrorCode { get; init; }
        public DsmRepository Repository { get; }
        public NasProfile Profile { get; }
        public DsmSession Session { get; }
        public DsmApiClient Client { get; }
        public Fixture(string name, string data, int maximum = 3, string format = "FORM", int minimum = 1)
        {
            _name = name;
            _http = new(new Handler(this, data));
            Profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
            Session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            Client = new DsmApiClient(_http);
            Repository = new(Profile, Session, Client, new Dictionary<string, ApiCapability>
                { [name] = new(name, "entry.cgi", minimum, maximum, format) });
        }
        public async Task ReadAsync()
        {
            if (_name == "SYNO.Core.Terminal") await Repository.LoadTerminalSettingsAsync();
            else await Repository.LoadProxySettingsAsync();
        }
        private sealed class Handler(Fixture owner, string data) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method);
                Assert.Equal("nas.invalid", request.RequestUri!.Host);
                Assert.Empty(request.RequestUri.Query);
                var body = await request.Content!.ReadAsStringAsync(token);
                var call = body.Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                Assert.Equal("get", call["method"]);
                Assert.Equal(owner._name, call["api"]);
                var response = owner.ErrorCode is int code
                    ? new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = code } }
                    : new JsonObject { ["success"] = true, ["data"] = JsonNode.Parse(data) };
                return new(HttpStatusCode.OK) { Content = new StringContent(response.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
