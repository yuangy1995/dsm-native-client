using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.Containers;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Containers;

public sealed class ContainerActivityTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task InventoryDoesNotReadLogsAndOpenedActivityUsesRecordedPagination(string format)
    {
        using var f = new Fixture(format);
        await f.Repository.LoadInventoryAsync(); Assert.DoesNotContain(f.Calls, call => call["api"] == "SYNO.Docker.Log");
        f.Pages.Enqueue(Page(0, 2, Row("a"))); f.Pages.Enqueue(Page(1, 2, Row("b")));
        var section = await f.Repository.LoadActivityAsync();
        Assert.Equal(ContainerManagerSectionStatus.Available, section.Status); Assert.Equal(2, section.Items.Count);
        var calls = f.Calls.Where(call => call["api"] == "SYNO.Docker.Log").ToArray(); Assert.Equal(2, calls.Length);
        Assert.Equal(new[] { "0", "1" }, calls.Select(call => call["offset"]));
        Assert.All(calls, call =>
        {
            Assert.Equal("1", call["version"]); Assert.Equal("list", call["method"]); Assert.Equal("1000", call["limit"]);
            Assert.Equal(format == "JSON" ? "\"load\"" : "load", call["action"]);
            Assert.Equal(format == "JSON" ? "\"DESC\"" : "DESC", call["sort_dir"]);
            Assert.Equal("0", call["datefrom"]); Assert.Equal("0", call["dateto"]);
        });
        var item = section.Items[0]; Assert.Equal("Synthetic <b>plain</b>\nsecond line", item.Message);
        Assert.Equal("synthetic-account", item.Account); Assert.Null(item.Summary.OccurredAt);
        Assert.Equal(new DateTime(2026, 10, 16, 12, 30, 45, DateTimeKind.Unspecified), item.LocalTime);
        Assert.DoesNotContain(item.Message, item.ToString()); Assert.DoesNotContain(item.Account!, new ContainerEventItem(item.Summary) { Activity = item }.ToString());
    }

    [Theory]
    [InlineData("missing-body")] [InlineData("wrong-body")] [InlineData("wrong-offset")] [InlineData("empty-before-total")]
    [InlineData("duplicate")] [InlineData("wrong-root")]
    public async Task MalformedOrIncompleteActivityCannotMasqueradeAsComplete(string defect)
    {
        using var f = new Fixture(); var row = Row("a");
        if (defect == "missing-body") row.Remove("message");
        if (defect == "wrong-body") row["message"] = 1;
        f.Pages.Enqueue(defect == "wrong-root" ? new() : Page(defect == "wrong-offset" ? 1 : 0,
            defect is "duplicate" or "empty-before-total" ? 2 : 1, row));
        if (defect == "duplicate") f.Pages.Enqueue(Page(1, 2, Row("a")));
        if (defect == "empty-before-total") f.Pages.Enqueue(Page(1, 2));
        var result = await f.Repository.LoadActivityAsync(); Assert.Equal(ContainerManagerSectionStatus.Failed, result.Status); Assert.Empty(result.Items);
    }

    [Fact]
    public async Task ZonedTimestampKeepsInstantAndLegacySummaryNeverIncludesBody()
    {
        using var f = new Fixture(); var row = Row("z"); row["time"] = "2026-10-16T12:30:45+02:00";
        f.Pages.Enqueue(Page(0, 1, row)); var item = Assert.Single((await f.Repository.LoadActivityAsync()).Items);
        Assert.Null(item.LocalTime); Assert.Equal(new DateTimeOffset(2026, 10, 16, 10, 30, 45, TimeSpan.Zero), item.Summary.OccurredAt);
        f.Pages.Enqueue(Page(0, 1, Row("x")));
        var summary = await f.Repository.LoadSnapshotAsync();
        Assert.Single(summary.Events.Items); Assert.DoesNotContain("synthetic-account", JsonSerializer.Serialize(summary));
        Assert.DoesNotContain("second line", JsonSerializer.Serialize(summary));
    }

    [Fact]
    public async Task PageFailureDoesNotBlockIndependentInventoryAndCancellationStopsRead()
    {
        using var f = new Fixture(); f.LogError = true;
        Assert.Equal(ContainerManagerSectionStatus.Failed, (await f.Repository.LoadActivityAsync()).Status);
        Assert.Equal(ContainerManagerSectionStatus.Available, (await f.Repository.LoadInventoryAsync()).Containers.Status);
        using var cancel = new CancellationTokenSource(); cancel.Cancel(); var calls = f.Calls.Count;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadActivityAsync(cancel.Token)); Assert.Equal(calls, f.Calls.Count);
    }

    [Fact]
    public async Task ActivityLoadsOnlyWhenVisibleFiltersBodyAccountAndLevelAndClearsOnExit()
    {
        var f = new Fake(); using var model = new ContainerManagerViewModel(); await model.ActivateAsync(f);
        Assert.Equal(1, f.Inventories); Assert.Equal(0, f.Reads);
        await model.SetActivityVisibleAsync(true); Assert.Equal(2, model.Events.Count);
        model.SetActivityFilter("SECOND LINE", ServiceEventLevel.Warning); Assert.Single(model.Events);
        model.SetActivityFilter("other-account", null); Assert.Equal("b", Assert.Single(model.Events).Id);
        model.SetActivityFilter("missing", null); Assert.Equal(ContainerManagerContentState.FilteredEmpty, model.EventsState);
        model.SetActivityFilter("", null); Assert.Equal(2, model.Events.Count); Assert.Equal(1, f.Reads);
        await model.SetActivityVisibleAsync(false); Assert.Empty(model.Events); Assert.Equal("", model.ActivitySearch);
        await model.SetActivityVisibleAsync(true); Assert.Equal(2, f.Reads); model.Dispose(); Assert.Empty(model.Events);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task LeavingOrRebindingIgnoresLateActivityEvenWhenProfileIdIsUnchanged(bool rebind)
    {
        var f = new Fake(); using var model = new ContainerManagerViewModel(); await model.ActivateAsync(f);
        var gate = new TaskCompletionSource<ContainerManagerSection<ServiceActivityEntry>>(TaskCreationOptions.RunContinuationsAsynchronously);
        f.Next = _ => gate.Task; var loading = model.SetActivityVisibleAsync(true); var token = f.LastToken;
        if (rebind) await model.ActivateAsync(new Fake { ProfileId = f.ProfileId, Name = "replacement" });
        else await model.SetActivityVisibleAsync(false);
        Assert.True(token.IsCancellationRequested); gate.SetResult(Fake.Activity()); await loading;
        Assert.Empty(model.Events); Assert.False(model.IsActivityLoading);
        if (rebind) Assert.Equal("replacement", Assert.Single(model.Containers).Name);
    }

    [Fact]
    public async Task RefreshFailurePreservesVisibleDataAndSuccessfulRetryClearsError()
    {
        var f = new Fake(); using var model = new ContainerManagerViewModel(); await model.ActivateAsync(f); await model.SetActivityVisibleAsync(true);
        f.Next = _ => Task.FromException<ContainerManagerSection<ServiceActivityEntry>>(new IOException("合成读取失败"));
        await model.RefreshAsync(); Assert.True(model.ActivityReadFailed); Assert.Equal(2, model.Events.Count);
        f.Next = null; await model.RefreshAsync(); Assert.False(model.ActivityReadFailed); Assert.Equal(3, f.Reads); Assert.Equal(1, f.Inventories);
    }

    [Fact]
    public async Task NativeEpochActivityTimeKeepsItsInstant()
    {
        using var f = new Fixture(); var row = Row("epoch"); row["time"] = 1700000000L;
        f.Pages.Enqueue(Page(0, 1, row));
        var item = Assert.Single((await f.Repository.LoadActivityAsync()).Items);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1700000000), item.Summary.OccurredAt); Assert.Null(item.LocalTime);
    }

    private static JsonObject Row(string id) => new()
    { ["id"] = id, ["time"] = "2026-10-16 12:30:45", ["level"] = "warning", ["message"] = "Synthetic <b>plain</b>\nsecond line", ["user"] = "synthetic-account" };
    private static JsonObject Page(int offset, int total, params JsonObject[] rows) => new()
    { ["offset"] = offset, ["total"] = total, ["logs"] = new JsonArray(rows.Select(row => (JsonNode)row).ToArray()) };

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http;
        public IContainerManagerRepository Repository { get; }
        public Queue<JsonObject> Pages { get; } = new();
        public List<Dictionary<string, string>> Calls { get; } = [];
        public bool LogError;
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
            Repository = new DsmRepository(profile, new(profile.Id, "synthetic-sid", "synthetic-token", null), new DsmApiClient(_http),
                new[] { "SYNO.Docker.Container", "SYNO.Docker.Log" }.ToDictionary(name => name, name => new ApiCapability(name, "entry.cgi", 1, 9, format)));
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                var log = call["api"] == "SYNO.Docker.Log";
                if (log && owner.LogError) throw new HttpRequestException("合成读取失败");
                var data = log ? owner.Pages.Dequeue() : new JsonObject { ["containers"] = new JsonArray() };
                return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }

    private sealed class Fake : IContainerManagerRepository
    {
        public Guid ProfileId { get; init; } = Guid.NewGuid();
        public string Name { get; init; } = "original";
        public ContainerManagerAvailability Availability { get; } = new(ContainerManagerAvailabilityStatus.InternalObserved, new HashSet<ContainerManagerReadFeature> { ContainerManagerReadFeature.Containers, ContainerManagerReadFeature.Events });
        public int Inventories, Reads;
        public CancellationToken LastToken;
        public Func<CancellationToken, Task<ContainerManagerSection<ServiceActivityEntry>>>? Next;
        public Task<ContainerManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default)
        {
            Inventories++; return Task.FromResult(new ContainerManagerSnapshot(ProfileId,
                ContainerManagerSection<ContainerSummary>.Available([new("c", Name, ContainerOperationalState.Stopped, null)]),
                ContainerManagerSection<ContainerResourceSummary>.Unavailable, ContainerManagerSection<ContainerResourceSummary>.Unavailable,
                ContainerManagerSection<ContainerResourceSummary>.Unavailable, ContainerManagerSection<ServiceEventSummary>.Available([])));
        }
        public Task<ContainerManagerSection<ServiceActivityEntry>> LoadActivityAsync(CancellationToken token = default)
        { Reads++; LastToken = token; return Next?.Invoke(token) ?? Task.FromResult(Activity()); }
        public static ContainerManagerSection<ServiceActivityEntry> Activity() => ContainerManagerSection<ServiceActivityEntry>.Available([
            new(new("a", null, ServiceEventLevel.Warning), "Synthetic <b>plain</b>\nsecond line", "synthetic-account", new DateTime(2026, 10, 16, 12, 30, 45)),
            new(new("b", null, ServiceEventLevel.Information), "another message", "other-account")]);
    }
}
