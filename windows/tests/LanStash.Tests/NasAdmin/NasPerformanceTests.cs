using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasPerformanceTests
{
    private const string ApiName = "SYNO.Core.System.Utilization";
    private const string Sample = """{"time":1800000000.5,"cpu":{"user_load":10.5,"system_load":20,"other_load":2},"memory":{"real_usage":43,"swap_usage":0},"network":[{"device":"one","rx":9999},{"device":"total","rx":"2048","tx":512}],"disk":{"total":{"read_byte":100,"write_byte":200,"utilization":30}},"space":{"total":{"read_byte":300,"write_byte":400}},"nfs":[{"read_OPS":1,"write_OPS":2},{"read_OPS":3,"write_OPS":4}]}""";
    [Fact]
    public async Task ReadsFixedContractWithoutAdministratorProbeAndKeepsUnits()
    {
        using var f = new Fixture(); var result = await f.Repository.LoadPerformanceAsync();
        Assert.True(f.Repository.CanReadPerformance); Assert.Equal(f.Profile.Id, result.ProfileId);
        Assert.Equal(32.5, result[NasPerformanceMetric.Cpu]); Assert.Equal(43, result[NasPerformanceMetric.Memory]);
        Assert.Equal(0, result[NasPerformanceMetric.Swap]); Assert.Equal(2048, result[NasPerformanceMetric.NetworkReceived]);
        Assert.Equal(512, result[NasPerformanceMetric.NetworkSent]); Assert.Equal(100, result[NasPerformanceMetric.DiskRead]);
        Assert.Equal(200, result[NasPerformanceMetric.DiskWrite]); Assert.Equal(300, result[NasPerformanceMetric.VolumeRead]);
        Assert.Equal(400, result[NasPerformanceMetric.VolumeWrite]); Assert.Equal(30, result[NasPerformanceMetric.DiskUtilization]);
        Assert.Equal(4, result[NasPerformanceMetric.NfsRead]); Assert.Equal(6, result[NasPerformanceMetric.NfsWrite]);
        Assert.Equal(DateTimeOffset.UnixEpoch.AddSeconds(1800000000.5), result.RecordedAt);
        var call = Assert.Single(f.Calls); Assert.Equal(ApiName, call["api"]); Assert.Equal("1", call["version"]);
        Assert.Equal("get", call["method"]); Assert.Equal("all", call["resource"]); Assert.Equal("current", call["type"]);
    }
    [Theory]
    [InlineData("{}")]
    [InlineData("{\"cpu\":{},\"memory\":{},\"network\":[],\"nfs\":[]}")]
    public async Task MissingFieldsStayUnknown(string body)
    { using var f = new Fixture { Data = body }; var result = await f.Repository.LoadPerformanceAsync(); Assert.False(result.HasValues); Assert.All(result.Values.Values, Assert.Null); }
    [Fact]
    public async Task PartialCpuAndNfsAreNotInventedTotals()
    {
        using var f = new Fixture { Data = """{"cpu":{"user_load":20},"memory":{"real_usage":140},"nfs":[{"read_OPS":1},{"write_OPS":2}]}""" };
        var result = await f.Repository.LoadPerformanceAsync(); Assert.Null(result[NasPerformanceMetric.Cpu]);
        Assert.Equal(20, result[NasPerformanceMetric.CpuUser]); Assert.Equal(100, result[NasPerformanceMetric.Memory]); Assert.Null(result[NasPerformanceMetric.NfsRead]);
    }
    [Theory]
    [InlineData("{\"cpu\":{\"user_load\":-1}}")]
    [InlineData("{\"memory\":{\"real_usage\":true}}")]
    [InlineData("{\"network\":[null]}")]
    [InlineData("{\"disk\":[]}")]
    [InlineData("{\"network\":[{\"device\":\"total\"},{\"device\":\"TOTAL\"}]}")]
    [InlineData("{\"time\":999999999999999}")]
    public async Task InvalidMetricsDoNotBecomeZero(string body)
    { using var f = new Fixture { Data = body }; await Assert.ThrowsAsync<InvalidDataException>(() => f.Repository.LoadPerformanceAsync()); }
    [Fact]
    public async Task UnsupportedCapabilityAndCancellationMakeZeroRequests()
    {
        using var f = new Fixture(); using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadPerformanceAsync(cancelled.Token));
        foreach (var capability in new[] { new ApiCapability(ApiName, "entry.cgi", 2, 3, "FORM"), new(ApiName, "entry.cgi", 1, 1, "JSON"), new(ApiName, "https://other.invalid", 1, 1, "FORM") })
        { f.Capabilities[ApiName] = capability; Assert.False(f.Repository.CanReadPerformance); await Assert.ThrowsAsync<NotSupportedException>(() => f.Repository.LoadPerformanceAsync()); }
        Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task HistoryIsBoundedDeduplicatedAndResetsOnClockChange()
    {
        var fake = new Fake(); using var model = new NasPerformanceViewModel(fake);
        for (var index = 0; index < 122; index++) { fake.Time = index; await model.RefreshAsync(); }
        Assert.Equal(120, model.History.Count); Assert.Equal(DateTimeOffset.UnixEpoch.AddSeconds(2), model.History[0].RecordedAt);
        await model.RefreshAsync(); Assert.Equal(120, model.History.Count);
        fake.Time = 0; await model.RefreshAsync(); Assert.Single(model.History);
    }
    [Fact]
    public async Task PauseIgnoresLateResponseAndManualRefreshDoesNotResume()
    {
        var fake = new Fake { Pending = new() }; using var model = new NasPerformanceViewModel(fake);
        var read = model.RefreshAsync(); model.TogglePause(); fake.Pending.SetResult(fake.Sample()); await read;
        Assert.Empty(model.History); Assert.False(model.IsLoading); await model.RefreshAsync(); Assert.Equal(1, fake.Calls);
        fake.Pending = null; await model.RefreshAsync(true); Assert.Single(model.History); Assert.True(model.IsPaused);
        model.TogglePause(); fake.Time++; await model.RefreshAsync(); Assert.Equal(2, model.History.Count);
    }
    [Fact]
    public async Task ConcurrentReadDoesNotDuplicateAndCloseIgnoresLateError()
    {
        var fake = new Fake { Pending = new() }; var model = new NasPerformanceViewModel(fake);
        var pending = model.RefreshAsync(); await model.RefreshAsync(true); Assert.Equal(1, fake.Calls);
        model.Dispose(); fake.Pending.SetException(new IOException()); await pending; Assert.Null(model.Error); Assert.Empty(model.History);
    }
    [Fact]
    public async Task FailedRefreshPreservesHistoryAndWrongProfileCannotReplaceIt()
    {
        var fake = new Fake(); using var model = new NasPerformanceViewModel(fake); await model.RefreshAsync();
        fake.Fail = true; await model.RefreshAsync(); Assert.NotNull(model.Error); Assert.Single(model.History);
        fake.Fail = false; fake.WrongProfile = true; fake.Time++; await model.RefreshAsync(); Assert.NotNull(model.Error); Assert.Single(model.History);
        fake.WrongProfile = false; await model.RefreshAsync(); Assert.Null(model.Error); Assert.Equal(2, model.History.Count);
        model.SelectMetric(NasPerformanceMetric.DiskRead); Assert.Equal(NasPerformanceMetric.DiskRead, model.SelectedMetric);
    }
    private sealed class Fixture : IDisposable
    {
        public string Data = Sample;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Dictionary<string, ApiCapability> Capabilities { get; } = new() { [ApiName] = new(ApiName, "entry.cgi", 1, 9, "FORM") };
        public List<Dictionary<string, string>> Calls { get; } = [];
        private readonly HttpClient _http;
        public DsmRepository Repository { get; }
        public Fixture()
        { _http = new(new Handler(this)); Repository = new(Profile, new(Profile.Id, "synthetic-sid", null, null), new DsmApiClient(_http), Capabilities); }
        public void Dispose() => _http.Dispose();
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal("nas.invalid", request.RequestUri!.Host); Assert.Empty(request.RequestUri.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(item => item.Split('=', 2))
                    .ToDictionary(item => WebUtility.UrlDecode(item[0]), item => WebUtility.UrlDecode(item[1]));
                owner.Calls.Add(call);
                return new(HttpStatusCode.OK) { Content = new StringContent(new JsonObject { ["success"] = true, ["data"] = JsonNode.Parse(owner.Data) }.ToJsonString(), Encoding.UTF8, "application/json") };
            }
        }
    }
    private sealed class Fake : INasDetailsRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid(); public bool CanReadPerformance => true;
        public NasDetailsAvailability Availability => new(NasDetailsAvailabilityStatus.Available, new HashSet<NasDetailsReadFeature>());
        public int Calls, Time; public bool Fail, WrongProfile; public TaskCompletionSource<NasPerformanceSnapshot>? Pending;
        public NasPerformanceSnapshot Sample() => new(WrongProfile ? Guid.NewGuid() : ProfileId, DateTimeOffset.UnixEpoch.AddSeconds(Time), new Dictionary<NasPerformanceMetric, double?> { [NasPerformanceMetric.Cpu] = 30 });
        public Task<NasPerformanceSnapshot> LoadPerformanceAsync(CancellationToken cancellationToken = default)
        { Calls++; return Pending?.Task ?? (Fail ? Task.FromException<NasPerformanceSnapshot>(new IOException()) : Task.FromResult(Sample())); }
        public Task<NasDetailsSnapshot> LoadDetailsAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadStorageAnalysisAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<NasDetailsSection<NasStorageAnalysisSummary>> LoadDeepStorageAnalysisAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
