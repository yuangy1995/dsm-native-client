using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasRegionSettingsReadTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task RecordedApiVersionsFieldsAndNasClockAreUsed(string format)
    {
        using var fixture = new Fixture(format);
        var value = await fixture.Repository.LoadRegionSettingsAsync();
        Assert.Equal("Y-m-d", value.DateFormat); Assert.Equal("H:i", value.TimeFormat);
        Assert.Equal("UTC", value.Timezone); Assert.Equal(NasRegionTimeMode.Network, value.Mode);
        Assert.Equal(new[] { "time.example.invalid", "pool.example.invalid" }, value.NtpServers);
        Assert.Equal(new DateTime(2026, 7, 26, 18, 30, 10, DateTimeKind.Unspecified), value.NasLocalTime);
        Assert.Equal(DateTimeKind.Unspecified, value.NasLocalTime!.Value.Kind);
        Assert.Equal("Synthetic UTC", Assert.Single(value.TimeZones).DisplayName);
        Assert.Equal(new[] { "get", "listzone" }, fixture.Calls.Select(call => call["method"]));
        Assert.Equal(new[] { "3", "1" }, fixture.Calls.Select(call => call["version"]));
        Assert.Equal(MutationResultStatus.Unsupported, (await fixture.Repository.SaveRegionSettingsAsync(value)).Status);
        Assert.Equal(2, fixture.Calls.Count);
    }

    [Theory]
    [InlineData("unexpected")]
    [InlineData("")]
    public async Task UnknownModeNeverBecomesManual(string mode)
    {
        using var fixture = new Fixture();
        fixture.Data["enable_ntp"] = mode;
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadRegionSettingsAsync());
        Assert.Single(fixture.Calls);
    }

    [Theory]
    [InlineData("date_format")]
    [InlineData("time_format")]
    [InlineData("timezone")]
    [InlineData("enable_ntp")]
    public async Task RequiredFieldsCannotBeGuessed(string field)
    {
        using var fixture = new Fixture();
        fixture.Data.Remove(field);
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadRegionSettingsAsync());
    }

    [Theory]
    [InlineData("hour", "null")]
    [InlineData("hour", "18.5")]
    [InlineData("hour", "1e100")]
    [InlineData("hour", "24")]
    [InlineData("minute", "60")]
    [InlineData("second", "-1")]
    public async Task InvalidClockDoesNotBecomeLocalTimeOrMidnight(string field, string value)
    {
        using var fixture = new Fixture();
        fixture.Data[field] = JsonNode.Parse(value);
        Assert.Null((await fixture.Repository.LoadRegionSettingsAsync()).NasLocalTime);
    }

    [Fact]
    public async Task InvalidDateAndMissingClockPartsRemainUnknown()
    {
        using var fixture = new Fixture();
        fixture.Data["date"] = "2026/2/30";
        Assert.Null((await fixture.Repository.LoadRegionSettingsAsync()).NasLocalTime);
        fixture.Data["date"] = "2026/7/26"; fixture.Data.Remove("hour");
        Assert.Null((await fixture.Repository.LoadRegionSettingsAsync()).NasLocalTime);
    }

    [Theory]
    [InlineData("""{"zonedata":[]}""")]
    [InlineData("""{"zonedata":[{"value":"Asia/Shanghai"}]}""")]
    [InlineData("""{"zonedata":[{"value":"UTC"},{"value":"UTC"}]}""")]
    [InlineData("""{}""")]
    public async Task CurrentZoneMustBeUnambiguousAndReturnedByNas(string zones)
    {
        using var fixture = new Fixture();
        fixture.Zones = JsonNode.Parse(zones)!.AsObject();
        await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadRegionSettingsAsync());
        Assert.Equal(2, fixture.Calls.Count);
    }

    [Theory]
    [InlineData(1, 2, "FORM")]
    [InlineData(2, 3, "FORM")]
    [InlineData(1, 3, "XML")]
    public async Task IncompleteContractsAreRejectedBeforeRequest(int minimum, int maximum, string format)
    {
        using var fixture = new Fixture(format, minimum, maximum);
        Assert.Equal(102, (await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadRegionSettingsAsync())).Code);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task ListZoneExceptionDoesNotAllowSyncOtherApisOrBusinessParameters()
    {
        using var fixture = new Fixture();
        var capability = new ApiCapability("SYNO.Core.Region.NTP", "entry.cgi", 1, 3, "FORM");
        await Assert.ThrowsAsync<ArgumentException>(() => fixture.Api.CallReadJsonObjectAsync(fixture.Profile, fixture.Session,
            capability, 2, "sync"));
        await Assert.ThrowsAsync<ArgumentException>(() => fixture.Api.CallReadJsonObjectAsync(fixture.Profile, fixture.Session,
            capability with { Name = "SYNO.Core.Region" }, 1, "listzone"));
        await Assert.ThrowsAsync<ArgumentException>(() => fixture.Api.CallReadJsonObjectAsync(fixture.Profile, fixture.Session,
            capability, 1, "listzone", new Dictionary<string, string> { ["timezone"] = "UTC" }));
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task ReadRejectionIsNotSwallowedOrRetriedAsLoad()
    {
        using var fixture = new Fixture() { ErrorCode = 105 };
        Assert.Equal(105, (await Assert.ThrowsAsync<DsmException>(() => fixture.Repository.LoadRegionSettingsAsync())).Code);
        Assert.Single(fixture.Calls);
    }

    [Fact]
    public async Task CancelledReadMakesNoRequest()
    {
        using var fixture = new Fixture(); using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => fixture.Repository.LoadRegionSettingsAsync(cancellation.Token));
        Assert.Empty(fixture.Calls);
    }

    internal sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmSession Session { get; }
        public DsmApiClient Api { get; }
        public DsmRepository Repository { get; }
        public int? ErrorCode { get; init; }
        public string Build { get; set; } = "69057";
        public bool LoseSet { get; set; }
        public bool LoseSync { get; set; }
        public bool RejectSet { get; set; }
        public bool RejectSync { get; set; }
        public bool FailReadback { get; set; }
        public bool FailAfterSync { get; set; }
        public Action? AfterSet { get; set; }
        public Action? AfterSync { get; set; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["method"] is "set" or "sync");
        public JsonObject Data { get; } = JsonNode.Parse("""{"date_format":"Y-m-d","time_format":"H:i","timezone":"UTC","enable_ntp":"ntp","server":" time.example.invalid, pool.example.invalid ","date":"2026/7/26","hour":18,"minute":30,"second":10}""")!.AsObject();
        public JsonObject Zones { get; set; } = JsonNode.Parse("""{"zonedata":[{"value":"UTC","display":"Synthetic UTC"}]}""")!.AsObject();
        public List<Dictionary<string, string>> Calls { get; } = [];
        public Fixture(string format = "FORM", int minimum = 1, int maximum = 9)
        {
            _http = new(new Handler(this)); Api = new(_http);
            Session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            Capabilities["SYNO.Core.Region.NTP"] = new("SYNO.Core.Region.NTP", "entry.cgi", minimum, maximum, format);
            Capabilities["SYNO.Core.Desktop.Initdata"] = new("SYNO.Core.Desktop.Initdata", "entry.cgi", 1, 1, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate(string? account = null) => new(Profile with { Username = account ?? Profile.Username }, Session, Api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Equal("nas.invalid", request.RequestUri!.Host);
                Assert.Empty(request.RequestUri.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                if (call["method"] == "get_user_service") return Reply(new JsonObject { ["Session"] = new JsonObject
                    { ["productversion"] = "7.2.1", ["version"] = owner.Build, ["smallfixnumber"] = "12", ["is_admin"] = true } });
                Assert.Equal("SYNO.Core.Region.NTP", call["api"]);
                if (call["method"] is "set" or "sync")
                {
                    if (call["method"] == "set" ? owner.RejectSet : owner.RejectSync)
                        return new(HttpStatusCode.OK) { Content = new StringContent("""{"success":false,"error":{"code":105}}""", Encoding.UTF8, "application/json") };
                    if (call["method"] == "set")
                    {
                        foreach (var pair in call.Where(pair => owner.Data.ContainsKey(pair.Key)))
                            owner.Data[pair.Key] = pair.Key is "hour" or "minute" or "second" ||
                                owner.Capabilities["SYNO.Core.Region.NTP"].RequestFormat == "JSON" ? JsonNode.Parse(pair.Value) : JsonValue.Create(pair.Value);
                        owner.AfterSet?.Invoke();
                        if (owner.LoseSet) throw new HttpRequestException("合成配置响应丢失");
                    }
                    else
                    {
                        owner.AfterSync?.Invoke();
                        if (owner.LoseSync) throw new HttpRequestException("合成校时响应丢失");
                    }
                    token.ThrowIfCancellationRequested();
                    return Reply(new());
                }
                Assert.Contains(call["method"], new[] { "get", "listzone" });
                if (owner.Writes.Any() && owner.FailReadback || owner.FailAfterSync && owner.Calls.Any(item => item["method"] == "sync"))
                    throw new HttpRequestException("合成回读失败");
                var data = call["method"] == "get" ? owner.Data : owner.Zones;
                var body = owner.ErrorCode is int code
                    ? new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = code } }
                    : new JsonObject { ["success"] = true, ["data"] = data.DeepClone() };
                return new(HttpStatusCode.OK) { Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json") };
            }
            private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK)
            { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString(), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
