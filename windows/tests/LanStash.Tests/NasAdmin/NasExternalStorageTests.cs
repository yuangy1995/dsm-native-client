using System.Net;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.NasAdmin;

public sealed class NasExternalStorageTests
{
    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task FixedReadWhitelistsFieldsAndTrustsApiConnection(string format)
    {
        using var f = new Fixture(format); var result = await f.Repository.LoadExternalStorageAsync();
        Assert.Equal(2, result.Devices.Count); Assert.Equal(NasExternalStorageSources.Usb | NasExternalStorageSources.Esata, result.AvailableSources);
        var usb = result.Devices[0]; Assert.Equal(NasExternalStorageConnection.Usb, usb.Connection); Assert.Equal(1024, usb.CapacityBytes);
        Assert.Equal(512, usb.UsedBytes); Assert.Equal(NasExternalStorageStatus.Ready, usb.Status);
        Assert.Null(result.Devices[1].UsedBytes);
        var json = JsonSerializer.Serialize(result); Assert.DoesNotContain("private-secret", json); Assert.DoesNotContain("/private", json);
        Assert.Equal(2, f.Calls.Count); Assert.All(f.Calls, call => { Assert.Equal("list", call["method"]); Assert.Equal("1", call["version"]); });
    }
    [Theory]
    [InlineData("{}")] [InlineData("{\"devices\":{}}")] [InlineData("{\"devices\":[],\"items\":[{}]}")]
    public async Task BadRootOnlyMakesThatConnectionUnavailable(string json)
    {
        using var f = new Fixture(); f.Usb = JsonNode.Parse(json)!.AsObject();
        var result = await f.Repository.LoadExternalStorageAsync(); Assert.Single(result.Devices);
        Assert.Equal(NasExternalStorageSources.Usb, result.UnavailableSources); Assert.Equal(NasExternalStorageConnection.Esata, result.Devices[0].Connection);
        f.Esata = new(); await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadExternalStorageAsync());
    }
    [Fact]
    public async Task BothFailuresAreNotAnEmptyDirectoryButSuccessfulEmptyIsAllowed()
    {
        using var f = new Fixture(); f.Errors[Fixture.UsbApi] = f.Errors[Fixture.EsataApi] = 105;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadExternalStorageAsync());
        f.Errors.Remove(Fixture.UsbApi); f.Usb = JsonNode.Parse("""{"devices":[]}""")!.AsObject();
        var result = await f.Repository.LoadExternalStorageAsync(); Assert.Empty(result.Devices);
        Assert.Equal(NasExternalStorageSources.Usb, result.AvailableSources); Assert.Equal(NasExternalStorageSources.Esata, result.UnavailableSources);
    }
    [Fact]
    public async Task UnknownUnitsAndFractionalOrConflictingCountsNeverBecomeCapacity()
    {
        using var f = new Fixture(); f.Usb = JsonNode.Parse("""{"devices":[{"name":"/private/device","size":1024,"capacity":2048,"used_bytes":-1},{"capacity_bytes":100.5},{"capacity_bytes":100,"total_bytes":200},{"capacity_bytes":"9223372036854775807"}]}""")!.AsObject();
        var result = await f.Repository.LoadExternalStorageAsync();
        Assert.Null(result.Devices[0].DisplayName); Assert.Null(result.Devices[0].CapacityBytes); Assert.Null(result.Devices[0].UsedBytes);
        Assert.Null(result.Devices[1].CapacityBytes); Assert.Null(result.Devices[2].CapacityBytes); Assert.Equal(long.MaxValue, result.Devices[3].CapacityBytes);
    }
    [Fact]
    public async Task EachConnectionIsBoundedAndInvalidRowsAreReported()
    {
        using var f = new Fixture(); var rows = new JsonArray();
        for(var i = 0; i < 65; i++) rows.Add(new JsonObject { ["id"] = $"row-{i}" });
        rows[0] = null; f.Usb = new JsonObject { ["devices"] = rows, ["total"] = 200 };
        var result = await f.Repository.LoadExternalStorageAsync();
        Assert.Equal(64, result.Devices.Count); Assert.Equal(1, result.IgnoredEntries); Assert.True(result.IsTruncated); Assert.Equal(201, result.Total);
        Assert.Equal(2, f.Calls.Count);
    }
    [Fact]
    public async Task MissingVersionsAndWriteMisuseNeverSendRequests()
    {
        using var f = new Fixture(); var usb = f.Capabilities[Fixture.UsbApi];
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, usb, 1, "eject"));
        await Assert.ThrowsAsync<ArgumentException>(() => f.Api.CallReadJsonObjectAsync(f.Profile, f.Session, usb, 2, "list"));
        f.Capabilities.Clear(); await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadExternalStorageAsync()); Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task AuthenticationAndPreCancellationAreNotPartialResults()
    {
        using var f = new Fixture(); using var cts = new CancellationTokenSource(); cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadExternalStorageAsync(cts.Token)); Assert.Empty(f.Calls);
        f.Errors[Fixture.UsbApi] = 119;
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadExternalStorageAsync()); Assert.Single(f.Calls);
    }
    [Fact]
    public async Task FilterDoesNotReadAgainAndUnavailableSourceIsNotCalledEmpty()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>();
        using var model = new NasExternalStorageViewModel(); await model.ActivateAsync(repository);
        Assert.Single(model.VisibleDevices); model.SetFilter(NasExternalStorageFilter.Esata); Assert.Empty(model.VisibleDevices); Assert.True(model.SelectedSourceUnavailable);
        model.SetFilter(NasExternalStorageFilter.Usb); Assert.Single(model.VisibleDevices); Assert.False(model.SelectedSourceUnavailable);
        Assert.Equal(1, ((Fake)repository).Reads);
    }
    [Fact]
    public async Task ReplacedProfileIgnoresLateReadAndCancelsItsToken()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        var release = new TaskCompletionSource<NasExternalStorageDirectory>(TaskCreationOptions.RunContinuationsAsynchronously); fake.Response = release.Task;
        using var model = new NasExternalStorageViewModel(); var old = model.ActivateAsync(repository); await model.ReloadAsync(); Assert.Equal(1, fake.Reads);
        await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>()); Assert.True(fake.Token.IsCancellationRequested);
        release.SetResult(new([], 0, false, 0, NasExternalStorageSources.Usb, NasExternalStorageSources.Esata)); await old;
        Assert.Single(model.VisibleDevices);
    }
    public class Fake : DispatchProxy
    {
        public int Reads { get; private set; } public CancellationToken Token { get; private set; }
        public Task<NasExternalStorageDirectory>? Response { get; set; }
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            if (method!.Name != "LoadExternalStorageAsync") throw new NotSupportedException("只允许读取外接存储");
            Reads++; Token = (CancellationToken)args![0]!;
            return Response ?? Task.FromResult(new NasExternalStorageDirectory([new("local", "Synthetic device", NasExternalStorageConnection.Usb, NasExternalStorageStatus.Ready, 1024, 0)],
                1, false, 0, NasExternalStorageSources.Usb, NasExternalStorageSources.Esata));
        }
    }
    private sealed class Fixture : IDisposable
    {
        public const string UsbApi = "SYNO.Core.ExternalDevice.Storage.USB", EsataApi = "SYNO.Core.ExternalDevice.Storage.eSATA";
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmSession Session { get; }
        public DsmApiClient Api { get; }
        public DsmRepository Repository { get; }
        private readonly HttpClient _http;
        public Dictionary<string,ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string,string>> Calls { get; } = [];
        public Dictionary<string,int> Errors { get; } = [];
        public JsonObject Usb { get; set; } = JsonNode.Parse("""{"devices":[{"id":"usb-a","display_name":"Synthetic USB","connection":"eSATA","status":"mounted","capacity_bytes":1024,"used_bytes":512,"serial":"private-secret","device":"/private/device","mount_path":"/private/mount"}]}""")!.AsObject();
        public JsonObject Esata { get; set; } = JsonNode.Parse("""{"items":[{"id":"esata-a","name":"Synthetic eSATA","state":"busy","total_bytes":1000,"usage_bytes":1001}]}""")!.AsObject();
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); Api = new(_http); Session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            foreach(var name in new[] { UsbApi, EsataApi }) Capabilities[name] = new(name, "entry.cgi", 1, 9, format);
            Repository = new(Profile, Session, Api, Capabilities);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=',2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                var data = call["api"] == UsbApi ? owner.Usb : owner.Esata;
                var json = owner.Errors.TryGetValue(call["api"], out var error) ? JsonSerializer.Serialize(new { success = false, error = new { code = error } }) : JsonSerializer.Serialize(new { success = true, data });
                return new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
