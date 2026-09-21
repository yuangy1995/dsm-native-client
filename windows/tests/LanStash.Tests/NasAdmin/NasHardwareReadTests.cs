using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasHardwareReadTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task ReadsSixRecordedGroupsAndDeviceLedRange(string format)
    {
        using var fixture = new Fixture(format);
        var value = await fixture.Repository.LoadHardwareSettingsAsync();
        Assert.Equal((NasHardwareSections)63, value.AvailableSections); Assert.Equal(NasHardwareSections.None, value.FailedSections);
        Assert.True(value.PowerFailRestart); Assert.Equal(5, value.LedBrightness); Assert.Equal(0, value.LedMinimum); Assert.Equal(10, value.LedMaximum);
        Assert.Equal("coolfan", value.FanMode); Assert.Null(value.BeepControl); Assert.Null(value.HddSleepMinutes);
        Assert.Equal("volume_or_cache_crash", value.Beep!.VolumeFieldName); Assert.True(value.Beep.VolumeFailure);
        Assert.False(value.Beep.PowerOff); Assert.True(value.Hibernation!.ExternalDriveDeepSleep);
        Assert.True(value.Ups!.Enabled); Assert.Equal("SLAVE", value.Ups.Mode); Assert.Equal(120, value.Ups.DelaySeconds);
        Assert.Equal("192.0.2.50", value.Ups.NetworkServer);
        Assert.Equal(7, fixture.Calls.Count); Assert.All(fixture.Calls, call => Assert.Equal("1", call["version"]));
        Assert.Single(fixture.Calls, call => call["method"] == "get_static_data");
        Assert.Equal(MutationResultStatus.Unsupported, (await fixture.Repository.SaveHardwareSettingsAsync(value)).Status);
        Assert.Equal(7, fixture.Calls.Count);
    }

    [Fact]
    public async Task PowerOnlyDoesNotDependOnAggregateHardwareApi()
    {
        using var fixture = new Fixture();
        foreach (var key in fixture.Capabilities.Keys.Where(key => key != "SYNO.Core.Hardware.PowerRecovery").ToArray()) fixture.Capabilities.Remove(key);
        var value = await fixture.Repository.LoadHardwareSettingsAsync();
        Assert.True(value.PowerFailRestart); Assert.Equal(NasHardwareSections.PowerRecovery, value.AvailableSections);
        Assert.Single(fixture.Calls);
        fixture.Capabilities.Clear(); fixture.Capabilities["SYNO.Core.Hardware"] = new("SYNO.Core.Hardware", "entry.cgi", 1, 1, "FORM");
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadHardwareSettingsAsync());
        Assert.Single(fixture.Calls);
    }

    [Fact]
    public async Task UpsEmptyAddressAndMissingAddressStayDifferent()
    {
        using var fixture = new Fixture();
        fixture.Data["SYNO.Core.ExternalDevice.UPS"]["net_server_ip"] = "";
        Assert.Equal("", (await fixture.Repository.LoadHardwareSettingsAsync()).Ups!.NetworkServer);
        fixture.Data["SYNO.Core.ExternalDevice.UPS"].Remove("net_server_ip");
        Assert.Null((await fixture.Repository.LoadHardwareSettingsAsync()).Ups!.NetworkServer);
    }

    [Theory]
    [InlineData("unknown")]
    [InlineData("")]
    public async Task UnknownUpsModeIsNotGuessedAsUsb(string mode)
    {
        using var fixture = new Fixture();
        fixture.Data["SYNO.Core.ExternalDevice.UPS"]["mode"] = mode;
        var value = await fixture.Repository.LoadHardwareSettingsAsync();
        Assert.Null(value.Ups); Assert.Null(value.UpsEnabled);
        Assert.True(value.FailedSections.HasFlag(NasHardwareSections.Ups)); Assert.True(value.PowerFailRestart);
    }

    [Fact]
    public async Task BeepVolumeFieldBindingFollowsActualReturnedName()
    {
        using var fixture = new Fixture();
        fixture.Data["SYNO.Core.Hardware.BeepControl"] = Json("""{"volume_crash":true,"poweron_beep":false}""");
        var legacy = await fixture.Repository.LoadHardwareSettingsAsync();
        Assert.Equal("volume_crash", legacy.Beep!.VolumeFieldName);
        Assert.True(legacy.Beep.VolumeFailure); Assert.Null(legacy.Beep.FanFailure);
        fixture.Data["SYNO.Core.Hardware.BeepControl"]["volume_or_cache_crash"] = false;
        var current = await fixture.Repository.LoadHardwareSettingsAsync();
        Assert.Equal("volume_or_cache_crash", current.Beep!.VolumeFieldName);
        Assert.False(current.Beep.VolumeFailure);
    }

    [Fact]
    public async Task UnrecognizedAggregateFieldsDoNotCreateFakeSwitches()
    {
        using var fixture = new Fixture();
        fixture.Data["SYNO.Core.Hardware.PowerRecovery"] = Json("""{"power_fail_restart":true}""");
        fixture.Data["SYNO.Core.Hardware.BeepControl"] = Json("""{"enable":true}""");
        fixture.Data["SYNO.Core.Hardware.Hibernation"] = Json("""{"sleep_minutes":30}""");
        var value = await fixture.Repository.LoadHardwareSettingsAsync();
        Assert.Null(value.PowerFailRestart); Assert.Null(value.BeepControl); Assert.Null(value.HddSleepMinutes);
        Assert.True(value.FailedSections.HasFlag(NasHardwareSections.PowerRecovery | NasHardwareSections.Beep | NasHardwareSections.Hibernation));
    }

    [Fact]
    public async Task InvalidOrUnavailableLedRangeDoesNotBlockOtherGroups()
    {
        using var fixture = new Fixture(); fixture.Range = Json("""{"min":10,"max":0}""");
        var value = await fixture.Repository.LoadHardwareSettingsAsync();
        Assert.Null(value.LedMinimum); Assert.Null(value.LedMaximum);
        Assert.True(value.FailedSections.HasFlag(NasHardwareSections.Led)); Assert.NotNull(value.Ups);
    }

    [Fact]
    public async Task PermissionFailureStaysLocalButAuthenticationFailurePropagates()
    {
        using var fixture = new Fixture() { ErrorApi = "SYNO.Core.Hardware.FanSpeed", ErrorCode = 105 };
        var value = await fixture.Repository.LoadHardwareSettingsAsync();
        Assert.Equal(NasHardwareSections.Fan, value.FailedSections); Assert.True(value.PowerFailRestart);
        using var expired = new Fixture() { ErrorApi = "SYNO.Core.Hardware.PowerRecovery", ErrorCode = 119 };
        Assert.True((await Assert.ThrowsAsync<DsmException>(() => expired.Repository.LoadHardwareSettingsAsync())).AuthenticationFailure);
        Assert.Single(expired.Calls);
    }

    [Fact]
    public async Task CancellationMakesZeroRequests()
    {
        using var fixture = new Fixture(); using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Repository.LoadHardwareSettingsAsync(cancellation.Token));
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task StaticLedReadExceptionDoesNotAuthorizeOtherMethodsOrApis()
    {
        using var fixture = new Fixture();
        var profile = fixture.Profile;
        var client = fixture.Api;
        var session = new DsmSession(profile.Id, "synthetic-sid", null, null);
        await Assert.ThrowsAsync<ArgumentException>(() => client.CallReadJsonObjectAsync(profile, session,
            new("SYNO.Core.Hardware.Led.Brightness", "entry.cgi", 1, 1, "FORM"), 1, "update"));
        await Assert.ThrowsAsync<ArgumentException>(() => client.CallReadJsonObjectAsync(profile, session,
            new("SYNO.Core.Hardware", "entry.cgi", 1, 1, "FORM"), 1, "get_static_data"));
        await Assert.ThrowsAsync<ArgumentException>(() => client.CallReadJsonObjectAsync(profile, session,
            new("SYNO.Core.Hardware.Led.Brightness", "entry.cgi", 1, 1, "FORM"), 1, "get_static_data",
            new Dictionary<string, string> { ["led_brightness"] = "5" }));
    }

    private static JsonObject Json(string value) => JsonNode.Parse(value)!.AsObject();
    internal sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        private readonly DsmApiClient _api;
        public DsmApiClient Api => _api;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmRepository Repository { get; }
        public string? ErrorApi { get; init; }
        public int ErrorCode { get; init; }
        public string Build { get; set; } = "69057";
        public string? LoseAt { get; set; }
        public bool LoseUpdate { get; set; }
        public bool FailReadback { get; set; }
        public Action? AfterWrite { get; set; }
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] is "set" or "set_current_brightness" or "update");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public JsonObject Range { get; set; } = Json("""{"min":0,"max":10}""");
        public Dictionary<string, JsonObject> Data { get; } = new()
        {
            ["SYNO.Core.Hardware.PowerRecovery"] = Json("""{"rc_power_config":true}"""),
            ["SYNO.Core.Hardware.Led.Brightness"] = Json("""{"led_brightness":5}"""),
            ["SYNO.Core.Hardware.FanSpeed"] = Json("""{"dual_fan_speed":"coolfan"}"""),
            ["SYNO.Core.Hardware.BeepControl"] = Json("""{"fan_fail":true,"volume_or_cache_crash":true,"poweron_beep":true,"poweroff_beep":false,"reset_beep":true}"""),
            ["SYNO.Core.Hardware.Hibernation"] = Json("""{"eunit_deep_sleep":true,"enable_log":false,"sata_deep_sleep":true,"ignore_netbios_broadcast":true,"auto_poweroff_enable":false}"""),
            ["SYNO.Core.ExternalDevice.UPS"] = Json("""{"enable":true,"mode":"SLAVE","delay_time":120,"ups_set_safemode_until_lowbatt":false,"shutdown_device":true,"net_server_ip":"192.0.2.50","snmp_server_ip":""}"""),
        };
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this));
            _api = new DsmApiClient(_http);
            foreach (var name in Data.Keys) Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            Capabilities["SYNO.Core.Desktop.Initdata"] = new("SYNO.Core.Desktop.Initdata", "entry.cgi", 1, 1, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate(string? account = null) => new(Profile with { Username = account ?? Profile.Username },
            new(Profile.Id, "synthetic-sid", "synthetic-token", null), _api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                if (call["method"] == "get_user_service") return Reply(new JsonObject { ["Session"] = new JsonObject
                    { ["productversion"] = "7.2.1", ["version"] = owner.Build, ["smallfixnumber"] = "12", ["is_admin"] = true } });
                if (call["method"] is "set" or "set_current_brightness" or "update")
                {
                    var target = owner.Data[call["api"]];
                    foreach (var pair in call.Where(pair => target.ContainsKey(pair.Key)))
                        target[pair.Key] = pair.Key is "dual_fan_speed" or "mode" or "net_server_ip" or "snmp_server_ip" &&
                            owner.Capabilities[call["api"]].RequestFormat == "FORM" ? JsonValue.Create(pair.Value) : JsonNode.Parse(pair.Value);
                    owner.AfterWrite?.Invoke();
                    if (owner.LoseAt == call["api"] || owner.LoseUpdate && call["method"] == "update") throw new HttpRequestException("合成硬件响应丢失");
                    token.ThrowIfCancellationRequested();
                    return Reply(new());
                }
                Assert.Contains(call["method"], new[] { "get", "get_static_data" });
                if (owner.Writes.Any() && owner.FailReadback) throw new HttpRequestException("合成硬件回读失败");
                var data = call["method"] == "get_static_data" ? owner.Range : owner.Data[call["api"]];
                var body = call["api"] == owner.ErrorApi
                    ? new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = owner.ErrorCode } }
                    : new JsonObject { ["success"] = true, ["data"] = data.DeepClone() };
                return new(HttpStatusCode.OK) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
            }
            private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK)
            { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
