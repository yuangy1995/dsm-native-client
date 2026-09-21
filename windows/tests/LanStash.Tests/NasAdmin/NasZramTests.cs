using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasZramTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task FixedReadKeepsOnlyTypedSummary(string format)
    {
        using var f = new Fixture(format); var snapshot = await f.Repository.LoadZramAsync();
        Assert.True(snapshot.IsEnabled); Assert.Equal(1_073_741_824, snapshot.ConfiguredBytes); Assert.Equal(NasZramAlgorithm.Lz4, snapshot.Algorithm);
        Assert.DoesNotContain("private-secret", JsonSerializer.Serialize(snapshot)); Assert.DoesNotContain("/private", JsonSerializer.Serialize(snapshot));
        var call = Assert.Single(f.Calls); Assert.Equal("get", call["method"]); Assert.Equal("1", call["version"]);
        Assert.DoesNotContain("set", call.Values);
    }
    [Theory]
    [InlineData("{}")]
    [InlineData("{\"enable\":\"false\",\"size\":1024,\"algorithm\":\"private-secret\"}")]
    [InlineData("{\"enable\":true,\"enabled\":false,\"configured_bytes\":100.5}")]
    [InlineData("{\"configured_bytes\":100,\"size_bytes\":200,\"algorithm\":\"lz4\",\"compressor\":\"zstd\"}")]
    public async Task MissingWrongTypeAndConflictingFieldsRemainUnknown(string json)
    {
        using var f = new Fixture { Data = JsonNode.Parse(json)! }; var snapshot = await f.Repository.LoadZramAsync();
        Assert.Null(snapshot.IsEnabled); Assert.Null(snapshot.ConfiguredBytes); Assert.Equal(NasZramAlgorithm.Unknown, snapshot.Algorithm); Assert.False(snapshot.HasInformation);
    }
    [Theory]
    [InlineData("lzo-rle", NasZramAlgorithm.Lzo)] [InlineData("zstd", NasZramAlgorithm.Zstd)]
    public async Task KnownDisabledAndZeroAreNotMissing(string algorithm, NasZramAlgorithm expected)
    {
        using var f = new Fixture { Data = new JsonObject { ["zram_enable"] = false, ["capacity_bytes"] = 0, ["compression_algorithm"] = algorithm } };
        var snapshot = await f.Repository.LoadZramAsync();
        Assert.False(snapshot.IsEnabled); Assert.Equal(0, snapshot.ConfiguredBytes); Assert.Equal(expected, snapshot.Algorithm); Assert.True(snapshot.HasInformation);
    }
    [Fact]
    public async Task ScalarEnvelopeAndPermissionFailureNeverLookLikeNoInformation()
    {
        using var f = new Fixture { Data = new JsonArray() };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadZramAsync());
        f.Error = 105; Assert.Equal(105, (await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadZramAsync())).Code);
    }
    [Fact]
    public async Task UnsupportedVersionsWriteMisuseAndCancellationSendNothing()
    {
        using var f = new Fixture(); using var cts = new CancellationTokenSource(); cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadZramAsync(cts.Token));
        var capability = f.Capabilities[Fixture.ApiName];
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, capability, 1, "set"));
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, capability, 2, "get"));
        f.Capabilities.Clear(); await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadZramAsync()); Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task LateProfileResponseCannotReplaceNewSnapshot()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        var release = new TaskCompletionSource<NasZramSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously); fake.Response = release.Task;
        using var model = new NasZramViewModel(); var first = model.ActivateAsync(repository); await model.ReloadAsync(); Assert.Equal(1, fake.Reads);
        await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>()); Assert.True(fake.Token.IsCancellationRequested);
        release.SetResult(new(null, null, NasZramAlgorithm.Unknown)); await first;
        Assert.True(model.Snapshot!.HasInformation); Assert.False(model.IsLoading);
    }
    [Fact]
    public async Task EmptyUnsupportedAndErrorHaveDistinctStates()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        fake.Response = Task.FromResult(new NasZramSnapshot(null, null, NasZramAlgorithm.Unknown));
        using var model = new NasZramViewModel(); await model.ActivateAsync(repository);
        Assert.False(model.Snapshot!.HasInformation); Assert.Null(model.ErrorMessage);
        fake.Response = Task.FromException<NasZramSnapshot>(new DsmException("synthetic", "synthetic", 102));
        await model.ReloadAsync(); Assert.True(model.IsUnsupported); Assert.Null(model.Snapshot);
        fake.Response = Task.FromException<NasZramSnapshot>(new IOException("合成读取失败"));
        await model.ReloadAsync(); Assert.NotNull(model.ErrorMessage); Assert.False(model.IsUnsupported); Assert.Null(model.Snapshot);
    }
    public class Fake : DispatchProxy
    {
        public int Reads { get; private set; } public CancellationToken Token { get; private set; }
        public Task<NasZramSnapshot>? Response { get; set; }
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            if (method!.Name != "LoadZramAsync") throw new NotSupportedException("只允许读取内存压缩");
            Reads++; Token = (CancellationToken)args![0]!;
            return Response ?? Task.FromResult(new NasZramSnapshot(true, 1024, NasZramAlgorithm.Lz4));
        }
    }
    private sealed class Fixture : IDisposable
    {
        public const string ApiName = "SYNO.Core.Hardware.ZRAM";
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmSession Session { get; }
        public DsmApiClient Api { get; }
        public DsmRepository Repository { get; }
        private readonly HttpClient _http;
        public Dictionary<string,ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string,string>> Calls { get; } = [];
        public int? Error { get; set; }
        public JsonNode Data { get; set; } = JsonNode.Parse("""{"enable":true,"configured_bytes":1073741824,"algorithm":"lz4hc","device":"/private/zram","kernel_parameter":"private-secret"}""")!;
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
                owner.Calls.Add((await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=',2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])));
                var json = owner.Error is { } error ? JsonSerializer.Serialize(new { success = false, error = new { code = error } }) : JsonSerializer.Serialize(new { success = true, data = owner.Data });
                return new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
