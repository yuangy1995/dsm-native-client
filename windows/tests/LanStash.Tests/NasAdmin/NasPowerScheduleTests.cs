using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasPowerScheduleTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task ReadOnlyFixedVersionPreservesUnknownsAndWhitelistsFields(string format)
    {
        using var f = new Fixture(format);
        var value = await f.Repository.LoadPowerScheduleAsync();
        Assert.Equal(3, value.Entries.Count); Assert.Equal("Asia/Shanghai", value.TimeZoneIdentifier);
        Assert.Equal(NasPowerScheduleAction.Startup, value.Entries[0].Action);
        Assert.Equal(NasPowerScheduleRecurrence.Weekly, value.Entries[0].Recurrence);
        Assert.Equal([DayOfWeek.Monday, DayOfWeek.Friday], value.Entries[0].Weekdays);
        Assert.Equal(new DateOnly(2026, 12, 31), value.Entries[1].Date);
        Assert.Null(value.Entries[2].IsEnabled); Assert.Equal(NasPowerScheduleRecurrence.Unknown, value.Entries[2].Recurrence);
        var serialized = JsonSerializer.Serialize(value); Assert.DoesNotContain("private-secret", serialized); Assert.DoesNotContain("/private/path", serialized);
        var call = Assert.Single(f.Calls); Assert.Equal("load", call["method"]); Assert.Equal("1", call["version"]);
        Assert.Equal(Fixture.ApiName, call["api"]); Assert.DoesNotContain("save", call.Values);
    }
    [Theory]
    [InlineData("{}")] [InlineData("{\"schedules\":{}}")] [InlineData("{\"schedules\":[],\"items\":[{}]}")]
    public async Task InvalidOrConflictingRootsNeverBecomeEmpty(string json)
    {
        using var f = new Fixture { Data = JsonNode.Parse(json)!.AsObject() };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadPowerScheduleAsync());
    }
    [Fact]
    public async Task InvalidTimesAndDuplicateRowsAreReportedAsNotDisplayed()
    {
        using var f = new Fixture { Data = JsonNode.Parse("""{"items":[{"id":"same","hour":8.5,"minute":0},{"id":"same","hour":8,"minute":0,"enabled":"false"},{"id":"same","hour":9,"minute":0},{"hour":24,"minute":0}]}""")!.AsObject() };
        var result = await f.Repository.LoadPowerScheduleAsync();
        Assert.Single(result.Entries); Assert.Null(result.Entries[0].IsEnabled); Assert.Equal(3, result.IgnoredEntries); Assert.Equal(4, result.Total);
    }
    [Fact]
    public async Task CapAndTotalAreExplicitAndNoAdditionalRequestIsSent()
    {
        using var f = new Fixture(); var rows = new JsonArray();
        for (var i = 0; i < 130; i++) rows.Add(new JsonObject { ["id"] = $"row-{i}", ["hour"] = 8, ["minute"] = 0 });
        f.Data = new JsonObject { ["schedules"] = rows, ["total"] = 200 };
        var result = await f.Repository.LoadPowerScheduleAsync();
        Assert.Equal(128, result.Entries.Count); Assert.Equal(200, result.Total); Assert.True(result.IsTruncated); Assert.Single(f.Calls);
    }
    [Fact]
    public async Task EmptyAndAmbiguousRecurrenceHaveDistinctMeaning()
    {
        using var f = new Fixture { Data = JsonNode.Parse("""{"schedules":[]}""")!.AsObject() };
        var empty = await f.Repository.LoadPowerScheduleAsync(); Assert.Empty(empty.Entries); Assert.Equal(0, empty.Total);
        f.Data = JsonNode.Parse("""{"time_zone":"https://private-secret.invalid","schedules":[{"id":"/private/path","hour":"08","minute":0,"weekdays":"mon,tue,wed,thu,fri,sat,sun"},{"hour":8,"minute":1,"weekdays":["mon","mon"]}]}""")!.AsObject();
        var result = await f.Repository.LoadPowerScheduleAsync();
        Assert.Null(result.TimeZoneIdentifier); Assert.Equal(NasPowerScheduleRecurrence.Daily, result.Entries[0].Recurrence);
        Assert.Equal(NasPowerScheduleRecurrence.Unknown, result.Entries[1].Recurrence); Assert.StartsWith("snapshot-", result.Entries[0].Id);
    }
    [Fact]
    public async Task VersionMissingCancellationAndWriteReadMisuseSendNothing()
    {
        using var f = new Fixture(); using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadPowerScheduleAsync(cancellation.Token));
        var capability = f.Capabilities[Fixture.ApiName];
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, capability, 1, "save"));
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, capability, 2, "load"));
        f.Capabilities[Fixture.ApiName] = capability with { MinVersion = 2 };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadPowerScheduleAsync()); Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task FiltersUseKnownBooleansAndDoNotIssueMoreReads()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        using var model = new NasPowerScheduleViewModel(); await model.ActivateAsync(repository);
        Assert.Equal(3, model.VisibleEntries.Count); model.SetFilter(NasPowerScheduleFilter.Enabled); Assert.Single(model.VisibleEntries);
        model.SetFilter(NasPowerScheduleFilter.Disabled); Assert.Single(model.VisibleEntries); Assert.False(model.VisibleEntries[0].IsEnabled);
        Assert.Equal(1, fake.Reads);
    }
    [Fact]
    public async Task ProfileSwitchCancelsOldReadAndIgnoresLateSnapshot()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        var release = new TaskCompletionSource<NasPowerScheduleSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously); fake.Response = release.Task;
        using var model = new NasPowerScheduleViewModel(); var loading = model.ActivateAsync(repository); await model.ReloadAsync(); Assert.Equal(1, fake.Reads);
        await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>()); Assert.True(fake.Token.IsCancellationRequested);
        release.SetResult(new([], null, 0, false, 0)); await loading; Assert.Equal(3, model.VisibleEntries.Count);
    }
    [Fact]
    public async Task ReadFailureDoesNotBecomeAnEmptySnapshot()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        fake.Response = Task.FromException<NasPowerScheduleSnapshot>(new IOException("合成失败"));
        using var model = new NasPowerScheduleViewModel(); await model.ActivateAsync(repository);
        Assert.NotNull(model.ErrorMessage); Assert.Null(model.Snapshot); Assert.False(model.IsLoading);
        fake.Response = Task.FromException<NasPowerScheduleSnapshot>(new DsmException("synthetic", "synthetic", 102));
        await model.ReloadAsync(); Assert.True(model.IsUnsupported); Assert.Null(model.Snapshot);
    }
    public class Fake : DispatchProxy
    {
        public int Reads { get; private set; } public CancellationToken Token { get; private set; }
        public Task<NasPowerScheduleSnapshot>? Response { get; set; }
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            if (method!.Name != "LoadPowerScheduleAsync") throw new NotSupportedException("只允许读取计划");
            Reads++; Token = (CancellationToken)args![0]!;
            return Response ?? Task.FromResult(new NasPowerScheduleSnapshot(
                new bool?[] { true, false, null }.Select((enabled, i) => new NasPowerScheduleEntry($"r{i}", NasPowerScheduleAction.Startup, enabled, 8, 0, NasPowerScheduleRecurrence.Unknown, null, [])).ToArray(),
                null, 3, false, 0));
        }
    }
    private sealed class Fixture : IDisposable
    {
        public const string ApiName = "SYNO.Core.Hardware.PowerSchedule";
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmSession Session { get; }
        public DsmApiClient Api { get; }
        public DsmRepository Repository { get; }
        private readonly HttpClient _http;
        public Dictionary<string,ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string,string>> Calls { get; } = [];
        public JsonObject Data { get; set; } = JsonNode.Parse("""{"timezone":"Asia/Shanghai","schedules":[{"id":"a","action":"power_on","enabled":true,"hour":8,"minute":30,"weekdays":["mon","fri"],"script":"private-secret","path":"/private/path"},{"id":"b","action":"shutdown","enabled":false,"hour":23,"minute":15,"date":"2026-12-31"},{"id":"c","action":"private-secret","hour":9,"minute":0,"days":[1,2]}]}""")!.AsObject();
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); Api = new(_http); Session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            Capabilities[ApiName] = new(ApiName, "entry.cgi", 1, 9, format); Repository = new(Profile, Session, Api, Capabilities);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=',2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data = owner.Data }), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
