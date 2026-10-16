using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class NasLogsTests
{
    private const string ApiName = "SYNO.Core.SyslogClient.Log";
    private const string Sample = """{"items":[{"time":"2026-10-16T01:02:03Z","logtype":"Synthetic service","level":"warning","who":"synthetic-account","descr":"Synthetic full body <b>plain text</b>"}],"total":120,"infoCount":110,"warnCount":10,"errorCount":0}""";
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task FixedVersionAndPagingUseOriginalSessionWithoutAdminProbe(string format)
    {
        using var f = new Fixture(format); var page = await f.Repository.LoadLogPageAsync(50, 50);
        Assert.Equal(f.Profile.Id, page.ProfileId); Assert.Equal(50, page.Offset); Assert.Equal(50, page.Limit);
        var entry = Assert.Single(page.Entries); Assert.Equal("synthetic-account", entry.Account);
        Assert.Equal("Synthetic full body <b>plain text</b>", entry.Message); Assert.Equal("Synthetic service", entry.Source);
        Assert.Equal(new DateTimeOffset(2026, 10, 16, 1, 2, 3, TimeSpan.Zero), entry.Time);
        Assert.Equal(120, page.Total); Assert.Equal(110, page.InfoCount); Assert.Equal(10, page.WarningCount); Assert.Equal(0, page.ErrorCount); Assert.True(page.HasNext);
        var call = Assert.Single(f.Calls); Assert.Equal(ApiName, call["api"]); Assert.Equal("1", call["version"]); Assert.Equal("list", call["method"]);
        Assert.Equal("50", call["offset"]); Assert.Equal("50", call["limit"]); Assert.False(call.ContainsKey("start")); Assert.False(call.ContainsKey("search"));
        Assert.DoesNotContain("synthetic-account", page.ToString()); Assert.DoesNotContain("Synthetic full body", entry.ToString());
    }
    [Theory]
    [InlineData("{}")] [InlineData("{\"items\":{}}")] [InlineData("{\"items\":[null]}")]
    [InlineData("{\"items\":[{\"descr\":{}}]}")] [InlineData("{\"items\":[{\"level\":\"info\"}]}")]
    [InlineData("{\"items\":[],\"total\":-1}")] [InlineData("{\"items\":[],\"total\":1.5}")]
    [InlineData("{\"items\":[],\"total\":\"20\"}")] [InlineData("{\"items\":[],\"total\":true}")]
    public async Task InvalidResponsesAreErrorsInsteadOfEmptyPages(string data)
    { using var f = new Fixture { Data = data }; await Assert.ThrowsAsync<InvalidDataException>(() => f.Repository.LoadLogPageAsync(0, 50)); }
    [Fact]
    public async Task MissingTotalAndInvalidOptionalCountsRemainUnknown()
    {
        using var f = new Fixture { Data = """{"items":[{"msg":"Synthetic body","orginalLogType":"Synthetic fallback","time":"invalid"}],"total":null,"warnCount":-1,"errorCount":"bad"}""" };
        var page = await f.Repository.LoadLogPageAsync(0, 1); Assert.Null(page.Total); Assert.Null(page.InfoCount); Assert.Null(page.WarningCount); Assert.Null(page.ErrorCount);
        Assert.True(page.HasNext); Assert.Null(page.Entries[0].Time); Assert.Equal("Synthetic fallback", page.Entries[0].Source);
        f.Data = """{"items":[]}"""; page = await f.Repository.LoadLogPageAsync(1, 1); Assert.False(page.HasNext); Assert.Null(page.Total);
        f.Data = """{"items":[{"message":"one"},{"message":"two"}]}""";
        await Assert.ThrowsAsync<InvalidDataException>(() => f.Repository.LoadLogPageAsync(0, 1));
    }
    [Fact]
    public async Task PreconditionsAndCancellationProduceNoRequests()
    {
        using var f = new Fixture(); using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadLogPageAsync(0, 50, cancelled.Token));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => f.Repository.LoadLogPageAsync(-1, 50));
        await Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => f.Repository.LoadLogPageAsync(0, 501));
        foreach (var capability in new[] { new ApiCapability(ApiName, "entry.cgi", 2, 3, "FORM"), new(ApiName, "entry.cgi", 1, 1, "XML"), new(ApiName, "https://other.invalid", 1, 1, "FORM") })
        { f.Capabilities[ApiName] = capability; Assert.False(f.Repository.CanReadLogs); await Assert.ThrowsAsync<NotSupportedException>(() => f.Repository.LoadLogPageAsync(0, 50)); }
        Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task SummaryPrefersSystemLogAndNeverStoresBodyOrAccount()
    {
        using var f = new Fixture(); f.Capabilities["SYNO.LogCenter.History"] = new("SYNO.LogCenter.History", "entry.cgi", 1, 1, "FORM");
        var snapshot = await f.Repository.LoadDetailsAsync(); var entry = Assert.Single(snapshot.Logs.Items);
        Assert.Equal("Synthetic service", entry.Source); Assert.Equal("warning", entry.Level);
        Assert.DoesNotContain("Synthetic full body", System.Text.Json.JsonSerializer.Serialize(snapshot));
        Assert.DoesNotContain("synthetic-account", System.Text.Json.JsonSerializer.Serialize(snapshot));
        Assert.Equal(ApiName, Assert.Single(f.Calls)["api"]);
    }
    [Fact]
    public async Task FailedNextPageKeepsOriginalAndRetryTargetsFailedPage()
    {
        var fake = new Fake(); using var model = new NasLogsViewModel(fake); await model.RefreshAsync();
        fake.Fail = true; await model.NextAsync(); Assert.Equal(0, model.Page!.Offset); Assert.NotNull(model.Error);
        fake.Fail = false; await model.RefreshAsync(); Assert.Equal(50, model.Page.Offset); Assert.Null(model.Error);
        Assert.Equal(new[] { (0, 50), (50, 50), (50, 50) }, fake.Calls);
        await model.PreviousAsync(); Assert.Equal(0, model.Page.Offset);
    }
    [Fact]
    public async Task PageSizeFailureRetainsOriginalAndRetryUsesNewSize()
    {
        var fake = new Fake(); using var model = new NasLogsViewModel(fake); await model.RefreshAsync(); await model.NextAsync();
        fake.Fail = true; await model.ChangePageSizeAsync(200); Assert.Equal(50, model.PageSize); Assert.Equal(50, model.Page!.Offset);
        fake.Fail = false; await model.RefreshAsync(); Assert.Equal(200, model.PageSize); Assert.Equal(0, model.Page.Offset);
    }
    [Fact]
    public async Task UnknownTotalsCanContinueUntilShortOrEmptyPageAndReturn()
    {
        var fake = new Fake(); using var model = new NasLogsViewModel(fake); await model.RefreshAsync(); Assert.True(model.CanNext);
        fake.Count = 0; await model.NextAsync(); Assert.False(model.CanNext); Assert.True(model.CanPrevious); Assert.Equal(50, model.Page!.Offset);
        fake.Count = 12; await model.PreviousAsync(); Assert.False(model.CanNext); Assert.False(model.CanPrevious);
    }
    [Fact]
    public async Task FilteringUsesCurrentPageBodySourceAndAccountWithoutNetwork()
    {
        var fake = new Fake(); using var model = new NasLogsViewModel(fake); await model.RefreshAsync();
        model.SetFilter(NasLogLevelFilter.Error, "synthetic"); Assert.Single(model.VisibleEntries);
        model.SetFilter(NasLogLevelFilter.Warning, "service"); Assert.Single(model.VisibleEntries);
        model.SetFilter(NasLogLevelFilter.All, "unique-account"); Assert.Single(model.VisibleEntries);
        model.SetFilter(NasLogLevelFilter.Information, "absent"); Assert.Empty(model.VisibleEntries); Assert.Single(fake.Calls);
    }
    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task ClosingClearsBodyAndIgnoresLatePageOrError(bool fail)
    {
        var fake = new Fake(); var model = new NasLogsViewModel(fake); await model.RefreshAsync(); model.SetFilter(NasLogLevelFilter.All, "synthetic");
        fake.Pending = new(); var pending = model.NextAsync(); await model.NextAsync(); Assert.Equal(2, fake.Calls.Count);
        model.Dispose(); Assert.Null(model.Page); Assert.Empty(model.Search); Assert.True(fake.Token.IsCancellationRequested);
        if (fail) fake.Pending.SetException(new IOException()); else fake.Pending.SetResult(fake.Sample(50, 50));
        await pending; Assert.Null(model.Page); Assert.Null(model.Error); Assert.Empty(model.VisibleEntries); Assert.False(model.IsLoading);
    }
    [Fact]
    public async Task OtherProfileResponseCannotReplaceCurrentPage()
    {
        var fake = new Fake(); using var model = new NasLogsViewModel(fake); await model.RefreshAsync(); fake.WrongOwner = true;
        await model.NextAsync(); Assert.Equal(0, model.Page!.Offset); Assert.NotNull(model.Error);
    }
    private sealed class Fixture : IDisposable
    {
        public string Data = Sample;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        private readonly HttpClient _http;
        public DsmRepository Repository { get; }
        public Fixture(string format = "FORM")
        { Capabilities[ApiName] = new(ApiName, "entry.cgi", 1, 9, format); _http = new(new Handler(this)); Repository = new(Profile, new(Profile.Id, "synthetic-sid", null, null), new DsmApiClient(_http), Capabilities); }
        public void Dispose() => _http.Dispose();
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(item => item.Split('=', 2))
                    .ToDictionary(item => WebUtility.UrlDecode(item[0]), item => WebUtility.UrlDecode(item[1]));
                owner.Calls.Add(call);
                return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = JsonNode.Parse(owner.Data) }.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
    }
    private sealed class Fake : INasDetailsRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid(); public bool CanReadLogs => true;
        public NasDetailsAvailability Availability => new(NasDetailsAvailabilityStatus.Available, new HashSet<NasDetailsReadFeature>());
        public List<(int, int)> Calls { get; } = []; public int? Count; public bool Fail, WrongOwner;
        public TaskCompletionSource<NasLogPage>? Pending; public CancellationToken Token;
        public NasLogPage Sample(int offset, int limit) => new(WrongOwner ? Guid.NewGuid() : ProfileId, offset, limit,
            Enumerable.Range(0, Count ?? limit).Select(index => new NasLogEntry(null, "Synthetic service", index == 0 ? "critical" : index == 1 ? "warning" : "info",
                index == 0 ? "unique-account" : "synthetic-account", "Synthetic body")).ToArray(), null);
        public Task<NasLogPage> LoadLogPageAsync(int offset, int limit, CancellationToken cancellationToken = default)
        { Calls.Add((offset, limit)); Token = cancellationToken; return Pending?.Task ?? (Fail ? Task.FromException<NasLogPage>(new IOException()) : Task.FromResult(Sample(offset, limit))); }
        public Task<NasDetailsSnapshot> LoadDetailsAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadStorageAnalysisAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadDeepStorageAnalysisAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
