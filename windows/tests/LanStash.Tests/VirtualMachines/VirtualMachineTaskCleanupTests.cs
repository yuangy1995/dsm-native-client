using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineTaskCleanupTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task OnlyConfirmedFinishedSubsetIsClearedAndReadBack(string format)
    {
        using var f = new Fixture(format); var selected = await f.Repository.LoadVirtualMachineTasksAsync();
        f.Tasks.Add("unrelated", false);
        var request = f.Request(selected);
        var result = await f.Repository.ClearFinishedTasksAsync(request);
        Assert.Equal(new VirtualMachineTaskCleanupResult(2, 2, 0, 0, 0), result);
        Assert.Equal(2, f.Writes.Count()); Assert.True(f.Tasks.ContainsKey("unrelated"));
        Assert.All(f.Writes, item => { Assert.Equal("1", item["version"]); Assert.Equal(Fixture.Api, item["api"]); Assert.DoesNotContain("guest_id", item.Keys); });
        Assert.Equal(format == "JSON" ? JsonSerializer.Serialize("@synthetic/a") : "@synthetic/a", f.Writes.First()["task_id"]);
        await f.Repository.ClearFinishedTasksAsync(request); Assert.Equal(2, f.Writes.Count());
        Assert.DoesNotContain("synthetic", JsonSerializer.Serialize(request));
    }
    [Fact]
    public async Task ChangedLastTargetPreventsEveryClear()
    {
        using var f = new Fixture(); var request = f.Request(await f.Repository.LoadVirtualMachineTasksAsync());
        f.Tasks["@synthetic/b"] = false;
        var result = await f.Repository.ClearFinishedTasksAsync(request);
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.Equal(2, result.NotStartedCount); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task UnknownClearIsProtectedAndOnlyReviewedAfterReopening()
    {
        using var f = new Fixture { Apply = false, LoseReply = true }; var request = f.Request(await f.Repository.LoadVirtualMachineTasksAsync());
        var result = await f.Repository.ClearFinishedTasksAsync(request);
        Assert.Equal(1, result.NeedsReviewCount); Assert.Equal(1, result.NotStartedCount); Assert.Single(f.Writes);
        Assert.Single(await f.Recreate().GetTaskCleanupRecoveriesAsync());
        Assert.Single(await f.Repository.LoadVirtualMachineTasksAsync(), item => item.IsProtected);
        await f.Recreate().ClearFinishedTasksAsync(request); Assert.Single(f.Writes);
        var retry = await f.Repository.ClearFinishedTasksAsync(request with { RequestId = Guid.NewGuid() });
        Assert.Equal(MutationErrorCategory.Conflict, retry.ErrorCategory); Assert.Single(f.Writes);
        f.Tasks.Remove("@synthetic/a");
        var reviewed = await f.Recreate().ReviewTaskCleanupAsync(request.RequestId);
        Assert.Equal(1, reviewed!.ClearedCount); Assert.Equal(1, reviewed.NotStartedCount); Assert.Equal(0, reviewed.NeedsReviewCount);
        Assert.Single(f.Writes); Assert.Empty(await f.Repository.GetTaskCleanupRecoveriesAsync());
    }
    [Fact]
    public async Task CancelledOrRejectedRequestsNeverClearTheRemainder()
    {
        using var f = new Fixture(); var request = f.Request(await f.Repository.LoadVirtualMachineTasksAsync());
        using var cancel = new CancellationTokenSource(); cancel.Cancel();
        Assert.True((await f.Repository.ClearFinishedTasksAsync(request, cancel.Token)).Cancelled); Assert.Empty(f.Writes);
        using var after = new CancellationTokenSource(); f.AfterClear = after.Cancel;
        var result = await f.Repository.ClearFinishedTasksAsync(request, after.Token);
        Assert.True(result.Cancelled); Assert.Equal(1, result.NeedsReviewCount); Assert.Equal(1, result.NotStartedCount);
        Assert.Equal(1, (await f.Repository.ReviewTaskCleanupAsync(request.RequestId))!.ClearedCount); Assert.Single(f.Writes);
        using var rejected = new Fixture { Error = 105 }; var failed = await rejected.Repository.ClearFinishedTasksAsync(rejected.Request(await rejected.Repository.LoadVirtualMachineTasksAsync()));
        Assert.Equal(1, failed.FailedCount); Assert.Equal(1, failed.NotStartedCount); Assert.Equal(0, failed.ClearedCount); Assert.Single(rejected.Writes);
    }
    [Fact]
    public async Task MalformedReadbackAndDifferentProfileCannotConfirmOrReplay()
    {
        using var f = new Fixture(); var request = f.Request(await f.Repository.LoadVirtualMachineTasksAsync());
        f.AfterClear = () => f.BadList = true;
        var result = await f.Repository.ClearFinishedTasksAsync(request);
        Assert.Equal(1, result.NeedsReviewCount); Assert.Single(f.Writes);
        var other = f.RecreateOtherProfile();
        Assert.Null(await other.ReviewTaskCleanupAsync(request.RequestId));
        Assert.Equal(MutationErrorCategory.Validation, (await other.ClearFinishedTasksAsync(request)).ErrorCategory);
        Assert.Single(f.Writes);
    }
    [Fact]
    public async Task RenewedLoginForSameAccountMayOnlyReviewUnknownCleanup()
    {
        using var f = new Fixture { Apply = false, LoseReply = true }; var request = f.Request(await f.Repository.LoadVirtualMachineTasksAsync());
        await f.Repository.ClearFinishedTasksAsync(request);
        var renewed = f.Recreate("renewed-session"); await renewed.ClearFinishedTasksAsync(request); Assert.Single(f.Writes);
        f.Tasks.Remove("@synthetic/a");
        Assert.Equal(1, (await renewed.ReviewTaskCleanupAsync(request.RequestId))!.ClearedCount); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task ConfirmationAndScopeAreRequired()
    {
        using var f = new Fixture(); var request = f.Request(await f.Repository.LoadVirtualMachineTasksAsync()); f.Calls.Clear();
        foreach (var invalid in new[] { request with { RiskConfirmed = false }, request with { ProfileId = Guid.NewGuid() }, request with { Keys = [] }, request with { Keys = [request.Keys[0], request.Keys[0]] } })
            Assert.Equal(MutationErrorCategory.Validation, (await f.Repository.ClearFinishedTasksAsync(invalid)).ErrorCategory);
        Assert.Empty(f.Calls);
    }
    private sealed class Fixture : IDisposable
    {
        public const string Api = "SYNO.Virtualization.API.Task.Info";
        private readonly HttpClient _http; private readonly DsmApiClient _api; private readonly DsmSession _session;
        private readonly Dictionary<string, ApiCapability> _capabilities;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public DsmRepository Repository { get; }
        public Dictionary<string, bool> Tasks { get; } = new() { ["@synthetic/a"] = true, ["@synthetic/b"] = true };
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(item => item["method"] == "clear");
        public bool Apply = true, LoseReply, BadList; public int? Error; public Action? AfterClear;
        private readonly string _format;
        public Fixture(string format = "FORM")
        { _format = format; _http = new(new Handler(this)); _api = new(_http); _session = new(Profile.Id, "synthetic", null, null); _capabilities = new() { [Api] = new(Api, "entry.cgi", 1, 2, format) }; Repository = Recreate(); }
        public DsmRepository Recreate(string? sid = null) => new(Profile, sid is null ? _session : _session with { Sid = sid }, _api, _capabilities);
        public DsmRepository RecreateOtherProfile()
        { var profile = Profile with { Id = Guid.NewGuid() }; return new(profile, new(profile.Id, "other-session", null, null), _api, _capabilities); }
        public VirtualMachineTaskCleanupRequest Request(IReadOnlyList<VirtualMachineTaskSummary> items) => new(Profile.Id, Guid.NewGuid(), items.Where(item => item.State == VirtualMachineTaskState.Finished).Select(item => item.Key).ToArray(), true);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                if (call["method"] == "list") return Reply(owner.BadList ? "{\"success\":true,\"data\":{}}" : JsonSerializer.Serialize(new { success = true, data = new { task_ids = owner.Tasks.Keys.ToArray() } }));
                var id = owner._format == "JSON" ? JsonSerializer.Deserialize<string>(call["task_id"])! : call["task_id"];
                if (call["method"] == "get") return Reply(JsonSerializer.Serialize(new { success = true, data = new { finish = owner.Tasks[id], task_info = new { progress = 100 } } }));
                Assert.Equal("clear", call["method"]);
                if (owner.Error is { } error) return Reply(JsonSerializer.Serialize(new { success = false, error = new { code = error } }));
                if (owner.Apply) owner.Tasks.Remove(id); owner.AfterClear?.Invoke(); token.ThrowIfCancellationRequested();
                if (owner.LoseReply) throw new HttpRequestException("synthetic");
                return Reply("{\"success\":true}");
            }
            private static HttpResponseMessage Reply(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
