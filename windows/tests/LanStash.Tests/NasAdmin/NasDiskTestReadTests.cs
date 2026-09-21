using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDiskTestReadTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task FixedReadsBindDeviceAndDoNotConfuseDisplayId(string format)
    {
        using var f = new Fixture(format); var target = Assert.Single(await f.Repository.LoadDiskTestTargetsAsync());
        var state = await f.Repository.LoadDiskTestStateAsync(target); var history = await f.Repository.LoadDiskTestHistoryAsync(target);
        Assert.False(state.IsRunning); Assert.False(state.IsBusyWithOtherTest); Assert.Equal(2, history.Entries.Count); Assert.False(history.IsTruncated);
        Assert.All(f.Calls, call => Assert.Equal("1", call["version"]));
        Assert.All(f.Calls.Where(call => call["api"] == Fixture.DiskApi), call => Assert.Equal(format == "JSON" ? "\"device-a\"" : "device-a", call["device"]));
        var log = f.Calls.Single(call => call["method"] == "disk_test_log_get");
        Assert.Equal("100", log["limit"]); Assert.DoesNotContain("disk_id", log.Keys);
    }
    [Theory]
    [InlineData("{}")] [InlineData("{\"disks\":[null]}")]
    [InlineData("{\"disks\":[{\"id\":\"a\"}]}")]
    [InlineData("{\"disks\":[{\"id\":\"a\",\"device\":\"x\"},{\"id\":\"b\",\"device\":\"x\"}]}")]
    [InlineData("{\"disks\":[{\"id\":\"a\",\"device\":\"x\",\"smart_test_support\":\"true\"}]}")]
    public async Task MalformedTargetsFailInsteadOfInventingDiskIdentity(string json)
    {
        using var f = new Fixture(); f.Disks = JsonNode.Parse(json)!.AsObject();
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadDiskTestTargetsAsync());
    }
    [Fact]
    public async Task MissingPermissionIsUnknownAndReplacedDiskNeverUsesOldDevice()
    {
        using var f = new Fixture(); var target = Assert.Single(await f.Repository.LoadDiskTestTargetsAsync());
        f.Disks["disks"]![0]!["device"] = "replacement";
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadDiskTestStateAsync(target));
        Assert.DoesNotContain(f.Calls, call => call["api"] == Fixture.DiskApi);
        f.Disks["disks"]![0]!.AsObject().Remove("smart_test_support");
        Assert.Null(Assert.Single(await f.Repository.LoadDiskTestTargetsAsync()).SupportsSmartTest);
    }
    [Theory]
    [InlineData("{}")] [InlineData("{\"testInfo\":[]}")]
    [InlineData("{\"testInfo\":[{}]}")]
    [InlineData("{\"testInfo\":[{\"testing\":false,\"is_testing\":true}]}")]
    [InlineData("{\"testInfo\":[{\"testing\":true,\"test_type\":\"other\"}]}")]
    [InlineData("{\"testInfo\":[{\"testing\":false,\"ihm_testing\":\"false\"}]}")]
    [InlineData("{\"testInfo\":[{\"device\":\"wrong\",\"testing\":false}]}")]
    public async Task MalformedStateCannotLookIdle(string json)
    {
        using var f = new Fixture(); f.State = JsonNode.Parse(json)!.AsObject();
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadDiskTestStateAsync(new("disk-a", "device-a", null, true)));
    }
    [Fact]
    public async Task AliasesNormalizeTypesAndAbsentBusyFlagsRemainUnknown()
    {
        using var f = new Fixture(); var target = new NasDiskTestTarget("disk-a", "device-a", null, true);
        f.State = JsonNode.Parse("""{"testInfo":[{"testing":true,"is_testing":true,"test_type":"extend","testType":"extended"}]}""")!.AsObject();
        Assert.Equal(NasDiskTestType.Extended, (await f.Repository.LoadDiskTestStateAsync(target)).RunningType);
        f.State = JsonNode.Parse("""{"testInfo":[{"testing":false}]}""")!.AsObject();
        Assert.Null((await f.Repository.LoadDiskTestStateAsync(target)).IsBusyWithOtherTest);
        f.State["testInfo"]![0]!["perf_testing"] = true;
        Assert.True((await f.Repository.LoadDiskTestStateAsync(target)).IsBusyWithOtherTest);
    }
    [Fact]
    public async Task HistoryFailureIsNotEmptyAndBoundIsExplicit()
    {
        using var f = new Fixture(); var target = new NasDiskTestTarget("disk-a", "device-a", null, true);
        f.History = new(); await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadDiskTestHistoryAsync(target));
        f.History = new JsonObject { ["testLog"] = new JsonArray(), ["total"] = 10 };
        Assert.True((await f.Repository.LoadDiskTestHistoryAsync(target)).IsTruncated);
        f.History["total"] = 0; Assert.Empty((await f.Repository.LoadDiskTestHistoryAsync(target)).Entries);
    }
    [Fact]
    public async Task CancellationUnavailableAndOldWriteSignatureSendNothing()
    {
        using var f = new Fixture(); using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadDiskTestTargetsAsync(cancelled.Token));
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.StartDiskTestAsync("disk-a", NasDiskTestType.Extended)).Status);
        f.Capabilities[Fixture.StorageApi] = new(Fixture.StorageApi, "entry.cgi", 2, 9, "FORM");
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadDiskTestTargetsAsync()); Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task ReadTransportRejectsWriteMethodsAndWrongVersion()
    {
        using var f = new Fixture(); var capability = f.Capabilities[Fixture.DiskApi];
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, capability, 1, "do_smart_test", new Dictionary<string,string> { ["device"] = "device-a", ["type"] = "quick" }));
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, capability, 2, "get_smart_test_log", new Dictionary<string,string> { ["device"] = "device-a" }));
        Assert.Empty(f.Calls);
    }
    internal sealed class Fixture : IDisposable
    {
        public const string StorageApi = "SYNO.Storage.CGI.Storage", DiskApi = "SYNO.Core.Storage.Disk";
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmSession Session { get; }
        public DsmApiClient Api { get; }
        public DsmRepository Repository { get; }
        private readonly HttpClient _http;
        public Dictionary<string,ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string,string>> Calls { get; } = [];
        public bool Administrator { get; set; } = true;
        public bool ApplyCommand { get; set; } = true;
        public bool LoseReply { get; set; }
        public int? RejectionCode { get; set; }
        public int? ReadErrorCode { get; set; }
        public Action? AfterCommand { get; set; }
        public Func<Task>? WaitCommand { get; set; }
        public Queue<Exception> ReadFailures { get; } = new();
        public int Writes => Calls.Count(call => call["method"] == "do_smart_test");
        public int StatusReadsAfterWrite { get; private set; }
        public JsonObject Disks { get; set; } = JsonNode.Parse("""{"disks":[{"id":"disk-a","device":"device-a","longName":"Synthetic disk","smart_test_support":true}]}""")!.AsObject();
        public JsonObject State { get; set; } = JsonNode.Parse("""{"testInfo":[{"device":"device-a","testing":false,"ihm_testing":false,"perf_testing":false}]}""")!.AsObject();
        public JsonObject History { get; set; } = JsonNode.Parse("""{"testLog":[{"test_type":"quick","time":"synthetic-time","result":"completed"},{"test_type":"extend","result":"completed"}]}""")!.AsObject();
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); Api = new(_http); Session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            foreach(var name in new[] { StorageApi, DiskApi }) Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            Capabilities["SYNO.Core.Desktop.Initdata"] = new("SYNO.Core.Desktop.Initdata", "entry.cgi", 1, 1, format);
            Repository = new(Profile, Session, Api, Capabilities);
        }
        public DsmRepository Recreate(string? user = null) => new(Profile with { Username = user ?? Profile.Username }, Session, Api, Capabilities);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2))
                    .ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                if (call["method"] == "get_user_service") return Reply(new JsonObject { ["Session"] = new JsonObject
                    { ["productversion"] = "7.2.1", ["version"] = "69057", ["smallfixnumber"] = "12", ["is_admin"] = owner.Administrator } });
                if (call["method"] == "do_smart_test")
                {
                    if (owner.WaitCommand is not null) await owner.WaitCommand();
                    if (owner.RejectionCode is int rejected) return Error(rejected);
                    var type = owner.Capabilities[DiskApi].RequestFormat == "JSON" ? JsonSerializer.Deserialize<string>(call["type"])! : call["type"];
                    if (owner.ApplyCommand)
                    {
                        owner.State["testInfo"]![0]!["testing"] = type != "stop";
                        owner.State["testInfo"]![0]!["test_type"] = type == "stop" ? null : type;
                    }
                    owner.AfterCommand?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.LoseReply) throw new HttpRequestException("合成提交回执丢失");
                    return Reply(new JsonObject());
                }
                if (call["method"] == "get_smart_test_log" && owner.Writes > 0)
                {
                    owner.StatusReadsAfterWrite++;
                    if (owner.ReadFailures.TryDequeue(out var failure)) throw failure;
                    if (owner.ReadErrorCode is int error) return Error(error);
                }
                var data = call["method"] switch { "load_info" => owner.Disks, "get_smart_test_log" => owner.State, "disk_test_log_get" => owner.History, _ => throw new InvalidOperationException("意外写入") };
                return Reply(data);
            }
            private static HttpResponseMessage Reply(JsonObject data) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
            private static HttpResponseMessage Error(int code) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = false, error = new { code } }), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
