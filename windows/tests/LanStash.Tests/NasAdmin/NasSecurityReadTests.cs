using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasSecurityReadTests
{
    [Theory]
    [InlineData("FORM", false)]
    [InlineData("JSON", false)]
    [InlineData("FORM", true)]
    [InlineData("JSON", true)]
    public async Task ReadsCorrectFieldsVersionsAndPerAdapterProtection(string format, bool array)
    {
        using var fixture = new Fixture(format) { DosArray = array };
        var settings = await fixture.Repository.LoadSecuritySettingsAsync();
        Assert.Equal((NasSecuritySections)15, settings.AvailableSections); Assert.Equal(NasSecuritySections.None, settings.FailedSections);
        Assert.True(settings.AutoBlockEnabled); Assert.Equal(5, settings.AutoBlockFailedAttempts);
        Assert.Equal(10, settings.AutoBlockWithinMinutes); Assert.Equal(7, settings.AutoBlockExpiryDays);
        Assert.True(settings.FirewallEnabled); Assert.Equal("synthetic-profile", settings.FirewallProfileName);
        Assert.True(settings.PortScanEnabled); Assert.Null(settings.DosProtectionEnabled);
        Assert.Equal(new[] { true, false }, settings.DosProtection.Select(item => item.Enabled));
        Assert.Equal(new[] { "Synthetic LAN", "Synthetic bond" }, settings.DosProtection.Select(item => item.Name));
        Assert.Equal(new[] { "1", "1", "1", "2", "2" }, fixture.Calls.Select(call => call["version"]));
        Assert.Equal("[{\"adapter\":\"eth0\"},{\"adapter\":\"bond0\"}]", fixture.Calls.Last()["configs"]);
        Assert.Equal(MutationResultStatus.Unsupported, (await fixture.Repository.SaveSecuritySettingsAsync(settings)).Status);
        Assert.Equal(5, fixture.Calls.Count);
    }

    [Fact]
    public async Task OnlyFirewallCapabilityDoesNotDependOnAutoBlock()
    {
        using var fixture = new Fixture();
        foreach (var key in fixture.Capabilities.Keys.Where(key => key != "SYNO.Core.Security.Firewall").ToArray()) fixture.Capabilities.Remove(key);
        var settings = await fixture.Repository.LoadSecuritySettingsAsync();
        Assert.True(settings.FirewallEnabled); Assert.Null(settings.AutoBlockEnabled);
        Assert.Equal(NasSecuritySections.Firewall, settings.AvailableSections); Assert.Single(fixture.Calls);
    }

    [Fact]
    public async Task WrongAliasesDoNotProduceGuessedValues()
    {
        using var fixture = new Fixture();
        fixture.AutoBlock = Json("""{"enable":true,"failed_attempts":5,"within_minutes":10,"expiry_days":7}""");
        fixture.Firewall = Json("""{"enable":true}"""); fixture.Conf = Json("""{"port_scan":true}""");
        var settings = await fixture.Repository.LoadSecuritySettingsAsync();
        Assert.Null(settings.AutoBlockFailedAttempts); Assert.Null(settings.AutoBlockWithinMinutes);
        Assert.Null(settings.AutoBlockExpiryDays); Assert.Null(settings.FirewallEnabled); Assert.Null(settings.PortScanEnabled);
        Assert.Equal(NasSecuritySections.AutoBlock | NasSecuritySections.Firewall | NasSecuritySections.PortScan, settings.FailedSections);
        Assert.Equal(NasSecuritySections.Dos, settings.AvailableSections);
    }

    [Fact]
    public async Task ZeroExpirationIsKnownButMissingExpirationIsNotZero()
    {
        using var fixture = new Fixture();
        fixture.AutoBlock["expire_day"] = 0;
        Assert.Equal(0, (await fixture.Repository.LoadSecuritySettingsAsync()).AutoBlockExpiryDays);
        fixture.AutoBlock.Remove("expire_day");
        var missing = await fixture.Repository.LoadSecuritySettingsAsync();
        Assert.Null(missing.AutoBlockExpiryDays); Assert.True(missing.FailedSections.HasFlag(NasSecuritySections.AutoBlock));
    }

    [Fact]
    public async Task DuplicateDosResponsesUseLastStateAndMissingAdaptersFailIndependently()
    {
        using var fixture = new Fixture();
        fixture.Configs.Add(Json("""{"adapter":"eth0","dos_protect_enable":false}"""));
        Assert.False((await fixture.Repository.LoadSecuritySettingsAsync()).DosProtectionEnabled);
        fixture.Configs.Clear();
        fixture.Configs.Add(Json("""{"adapter":"eth0","dos_protect_enable":true}"""));
        var settings = await fixture.Repository.LoadSecuritySettingsAsync();
        Assert.True(settings.FailedSections.HasFlag(NasSecuritySections.Dos));
        Assert.Empty(settings.DosProtection); Assert.Null(settings.DosProtectionEnabled);
        Assert.True(settings.AutoBlockEnabled);
    }

    [Fact]
    public async Task EmptyAdaptersDoNotIssueDosGetAndUnsafeIdsNeverLeaveClient()
    {
        using var fixture = new Fixture();
        fixture.Adapters.Clear();
        var empty = await fixture.Repository.LoadSecuritySettingsAsync();
        Assert.True(empty.AvailableSections.HasFlag(NasSecuritySections.Dos)); Assert.Empty(empty.DosProtection);
        Assert.DoesNotContain(fixture.Calls, call => call["api"] == "SYNO.Core.Security.DoS");
        fixture.Calls.Clear(); fixture.Adapters.Add(Json("""{"id":"eth0;reboot"}"""));
        Assert.True((await fixture.Repository.LoadSecuritySettingsAsync()).FailedSections.HasFlag(NasSecuritySections.Dos));
        Assert.DoesNotContain(fixture.Calls, call => call["api"] == "SYNO.Core.Security.DoS");
    }

    [Fact]
    public async Task RejectedSectionDoesNotHideOtherSettingsOrTryLoad()
    {
        using var fixture = new Fixture() { ErrorApi = "SYNO.Core.Security.Firewall", ErrorCode = 105 };
        var settings = await fixture.Repository.LoadSecuritySettingsAsync();
        Assert.Equal(NasSecuritySections.Firewall, settings.FailedSections); Assert.True(settings.PortScanEnabled);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] == "load");
    }

    [Fact]
    public async Task AuthenticationAndPreCancellationDoNotBecomeEmptySettings()
    {
        using var fixture = new Fixture() { ErrorApi = "SYNO.Core.Security.AutoBlock", ErrorCode = 119 };
        Assert.True((await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadSecuritySettingsAsync())).AuthenticationFailure);
        Assert.Single(fixture.Calls);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Repository.LoadSecuritySettingsAsync(cancellation.Token));
        Assert.Single(fixture.Calls);
    }

    [Fact]
    public async Task DosV1IsNotUsedAndOldAggregateDoesNotEnableSecurity()
    {
        using var fixture = new Fixture();
        fixture.Capabilities["SYNO.Core.Security.DoS"] = new("SYNO.Core.Security.DoS", "entry.cgi", 1, 1, "FORM");
        Assert.True((await fixture.Repository.LoadSecuritySettingsAsync()).FailedSections.HasFlag(NasSecuritySections.Dos));
        Assert.DoesNotContain(fixture.Calls, call => call["api"] == "SYNO.Core.Security.DoS");
        fixture.Capabilities.Clear();
        fixture.Capabilities["SYNO.Core.Security"] = new("SYNO.Core.Security", "entry.cgi", 1, 1, "FORM");
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadSecuritySettingsAsync());
    }

    private static JsonObject Json(string text) => JsonNode.Parse(text)!.AsObject();
    internal sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        private readonly DsmApiClient _api;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public bool DosArray { get; init; }
        public string? ErrorApi { get; init; }
        public int ErrorCode { get; init; }
        public string Build { get; set; } = "69057";
        public string? LoseAt { get; set; }
        public bool FailReadback { get; set; }
        public bool TaskPending { get; set; }
        public bool TaskFails { get; set; }
        public bool StatusFails { get; set; }
        public bool CleanupLost { get; set; }
        public bool MissingTaskId { get; set; }
        public Action? AfterWrite { get; set; }
        public Action? AfterStatus { get; set; }
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] is "set" or "start");
        public JsonObject AutoBlock { get; set; } = Json("""{"enable":true,"attempts":5,"within_mins":10,"expire_day":7}""");
        public JsonObject Firewall { get; set; } = Json("""{"enable_firewall":true,"profile_name":"synthetic-profile"}""");
        public JsonObject Conf { get; set; } = Json("""{"enable_port_check":true}""");
        public JsonArray Adapters { get; } = JsonNode.Parse("""[{"ifname":"eth0","display":"Synthetic LAN"},{"id":"bond0","display_name":"Synthetic bond"}]""")!.AsArray();
        public JsonArray Configs { get; } = JsonNode.Parse("""[{"adapter":"eth0","dos_protect_enable":true},{"adapter":"bond0","dos_protect_enable":false}]""")!.AsArray();
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this));
            _api = new DsmApiClient(_http);
            foreach (var name in new[] { "SYNO.Core.Security.AutoBlock", "SYNO.Core.Security.Firewall", "SYNO.Core.Security.Firewall.Conf",
                "SYNO.Core.Security.DoS", "SYNO.Core.Network.Ethernet" }) Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            Capabilities["SYNO.Core.Desktop.Initdata"] = new("SYNO.Core.Desktop.Initdata", "entry.cgi", 1, 1, format);
            Capabilities["SYNO.Core.Security.Firewall.Profile.Apply"] = new("SYNO.Core.Security.Firewall.Profile.Apply", "entry.cgi", 1, 1, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate(string? account = null) => new(Profile with { Username = account ?? Profile.Username },
            new(Profile.Id, "synthetic-sid", "synthetic-token", null), _api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query);
                Assert.Equal(HttpMethod.Post, request.Method);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                if (call["method"] == "get_user_service") return Reply(new JsonObject { ["Session"] = new JsonObject
                    { ["productversion"] = "7.2.1", ["version"] = owner.Build, ["smallfixnumber"] = "12", ["is_admin"] = true } });
                if (call["method"] is "set" or "start")
                {
                    if (call["method"] == "start")
                    {
                        owner.AfterWrite?.Invoke();
                        if (owner.LoseAt == call["api"]) throw new HttpRequestException("合成 start 响应丢失");
                        return Reply(owner.MissingTaskId ? new() : new() { ["task_id"] = "synthetic-task" });
                    }
                    var target = call["api"] == "SYNO.Core.Security.AutoBlock" ? owner.AutoBlock :
                        call["api"] == "SYNO.Core.Security.Firewall.Conf" ? owner.Conf : owner.Firewall;
                    if (call["api"] == "SYNO.Core.Security.DoS")
                    {
                        owner.Configs.Clear();
                        foreach (var row in JsonNode.Parse(call["configs"])!.AsArray()) owner.Configs.Add(row!.DeepClone());
                    }
                    else if (call["api"] == "SYNO.Core.Security.Firewall") owner.Firewall["enable_firewall"] = false;
                    else foreach (var pair in call.Where(pair => target.ContainsKey(pair.Key))) target[pair.Key] = JsonNode.Parse(pair.Value);
                    owner.AfterWrite?.Invoke();
                    if (owner.LoseAt == call["api"]) throw new HttpRequestException("合成 set 响应丢失");
                    token.ThrowIfCancellationRequested();
                    return Reply(new());
                }
                if (call["method"] == "status")
                {
                    Assert.Equal(owner.Capabilities[call["api"]].RequestFormat == "JSON" ? "\"synthetic-task\"" : "synthetic-task", call["task_id"]);
                    owner.AfterStatus?.Invoke();
                    if (owner.StatusFails) throw new DsmException("synthetic", "synthetic", 105);
                    if (owner.TaskPending) return Reply(new());
                    if (!owner.TaskFails) owner.Firewall["enable_firewall"] = true;
                    return Reply(new() { ["success"] = !owner.TaskFails });
                }
                if (call["method"] == "stop")
                {
                    Assert.False(owner.TaskPending);
                    if (owner.CleanupLost) throw new HttpRequestException("合成清理响应丢失");
                    return Reply(new());
                }
                Assert.Contains(call["method"], new[] { "get", "list" });
                if (owner.Writes.Any() && owner.FailReadback) throw new HttpRequestException("合成回读失败");
                JsonNode data = call["api"] switch
                {
                    "SYNO.Core.Security.AutoBlock" => owner.AutoBlock.DeepClone(),
                    "SYNO.Core.Security.Firewall" => owner.Firewall.DeepClone(),
                    "SYNO.Core.Security.Firewall.Conf" => owner.Conf.DeepClone(),
                    "SYNO.Core.Network.Ethernet" => new JsonObject { ["interfaces"] = owner.Adapters.DeepClone() },
                    _ => owner.DosArray ? owner.Configs.DeepClone() : new JsonObject { ["configs"] = owner.Configs.DeepClone() },
                };
                var body = call["api"] == owner.ErrorApi
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
