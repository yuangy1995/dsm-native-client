using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineTasksRepositoryTests
{
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task UsesOfficialVersionDiscoveredPathAndTypedIdentifierWithoutExposingIt(string format)
    {
        using var f = new Fixture(format); var result = await f.Repository.LoadVirtualMachineTasksAsync();
        var item = Assert.Single(result); Assert.Equal(VirtualMachineTaskState.Running, item.State); Assert.Equal(40, item.ProgressPercent);
        Assert.DoesNotContain("synthetic", item.Key); Assert.DoesNotContain("synthetic", item.ToString());
        Assert.Equal(item.Key, Assert.Single(await f.Repository.LoadVirtualMachineTasksAsync()).Key);
        Assert.All(f.Calls, call => { Assert.Equal(Fixture.Api, call["api"]); Assert.Equal("1", call["version"]); Assert.Contains(call["method"], new[] { "list", "get" }); });
        Assert.Equal(format == "JSON" ? JsonSerializer.Serialize(Fixture.Id) : Fixture.Id, f.Calls[1]["task_id"]);
    }
    [Theory]
    [InlineData("{}")][InlineData("{\"task_ids\":null}")][InlineData("{\"task_ids\":[1]}")]
    [InlineData("{\"task_ids\":[\"same\",\"same\"]}")][InlineData("{\"task_ids\":[\"a,b\"]}")]
    public async Task InvalidListsDoNotBecomeEmptyOrPartialSuccess(string data)
    {
        using var f = new Fixture { ListData = data };
        await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadVirtualMachineTasksAsync()); Assert.Single(f.Calls);
    }
    [Theory]
    [InlineData("{\"finish\":1,\"task_info\":{}}")]
    [InlineData("{\"finish\":true}")]
    [InlineData("{\"finish\":false,\"task_info\":{\"progress\":true}}")]
    [InlineData("{\"finish\":false,\"task_info\":{\"progress\":40.5}}")]
    [InlineData("{\"finish\":false,\"task_info\":{\"progress\":101}}")]
    public async Task InvalidDetailsAreVisibleAsReadFailure(string data)
    {
        using var f = new Fixture { DetailData = data }; var task = Assert.Single(await f.Repository.LoadVirtualMachineTasksAsync());
        Assert.Equal(VirtualMachineTaskState.ReadFailed, task.State); Assert.Null(task.ProgressPercent);
    }
    [Fact]
    public async Task FinishedDoesNotBecomeSuccessAndAbsentProgressDoesNotBecomeOneHundred()
    {
        using var f = new Fixture { DetailData = "{\"finish\":true,\"task_info\":{\"status\":\"failure\",\"message\":\"private-content\"}}" };
        var result = Assert.Single(await f.Repository.LoadVirtualMachineTasksAsync());
        Assert.Equal(VirtualMachineTaskState.Finished, result.State); Assert.Null(result.ProgressPercent);
        Assert.DoesNotContain("private-content", JsonSerializer.Serialize(result));
        f.DetailData = "{\"finish\":false,\"task_info\":{\"progress\":100}}";
        Assert.Equal(VirtualMachineTaskState.Running, Assert.Single(await f.Repository.LoadVirtualMachineTasksAsync()).State);
    }
    [Fact]
    public async Task FullListIsNotTruncatedAndEmptyListMakesNoDetailCalls()
    {
        using var f = new Fixture { ListData = JsonSerializer.Serialize(new { task_ids = Enumerable.Range(0, 201).Select(i => "task-" + i).ToArray() }) };
        Assert.Equal(201, (await f.Repository.LoadVirtualMachineTasksAsync()).Count); Assert.Equal(202, f.Calls.Count);
        f.Calls.Clear(); f.ListData = "{\"task_ids\":[]}"; Assert.Empty(await f.Repository.LoadVirtualMachineTasksAsync()); Assert.Single(f.Calls);
    }
    [Fact]
    public async Task SessionFailureAndCancellationDoNotBecomePerItemReadErrors()
    {
        using var f = new Fixture { DetailError = 119 };
        var error = await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadVirtualMachineTasksAsync()); Assert.True(error.AuthenticationFailure || error.Code == 119);
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel(); f.Calls.Clear();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => f.Repository.LoadVirtualMachineTasksAsync(cancelled.Token)); Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task UnsupportedCapabilityDoesNotIssueRequests()
    {
        using var f = new Fixture(); f.Capabilities[Fixture.Api] = new(Fixture.Api, "vmm-tasks-synthetic.cgi", 2, 3, "FORM");
        Assert.False(f.Repository.CanReadTasks); await Assert.ThrowsAsync<DsmException>(() => f.Repository.LoadVirtualMachineTasksAsync()); Assert.Empty(f.Calls);
    }
    private sealed class Fixture : IDisposable
    {
        public const string Api = "SYNO.Virtualization.API.Task.Info", Id = "@synthetic/task-a";
        private readonly HttpClient _http;
        public DsmRepository Repository { get; }
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public List<Dictionary<string, string>> Calls { get; } = [];
        public string ListData = JsonSerializer.Serialize(new { task_ids = new[] { Id } });
        public string DetailData = "{\"finish\":false,\"task_info\":{\"progress\":40}}";
        public int? DetailError;
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); var profile = new NasProfile(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
            Capabilities[Api] = new(Api, "vmm-tasks-synthetic.cgi", 1, 9, format);
            Repository = new(profile, new(profile.Id, "synthetic-sid", null, null), new DsmApiClient(_http), Capabilities);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query); Assert.EndsWith("/vmm-tasks-synthetic.cgi", request.RequestUri.AbsolutePath);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                var body = call["method"] == "get" && owner.DetailError is { } code ? JsonSerializer.Serialize(new { success = false, error = new { code } }) :
                    "{\"success\":true,\"data\":" + (call["method"] == "list" ? owner.ListData : owner.DetailData) + "}";
                return new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            }
        }
        public void Dispose() => _http.Dispose();
    }
}
