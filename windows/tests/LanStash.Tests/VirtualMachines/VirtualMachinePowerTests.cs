using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachinePowerTests
{
    [Theory]
    [InlineData("FORM", VirtualMachinePowerAction.PowerOn, "poweron")]
    [InlineData("JSON", VirtualMachinePowerAction.PowerOn, "poweron")]
    [InlineData("FORM", VirtualMachinePowerAction.Shutdown, "shutdown")]
    [InlineData("JSON", VirtualMachinePowerAction.Shutdown, "shutdown")]
    [InlineData("FORM", VirtualMachinePowerAction.PowerOff, "poweroff")]
    [InlineData("JSON", VirtualMachinePowerAction.PowerOff, "poweroff")]
    public async Task PublicActionsSendOneGuestAndRequireFinalState(string format, VirtualMachinePowerAction action, string method)
    {
        using var f = new Fixture(format); var request = f.Request(action);
        var result = await f.Repository.ControlPowerAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status); Assert.Equal(1, result.Counts.Succeeded);
        var write = Assert.Single(f.Writes); Assert.Equal(method, write["method"]); Assert.Equal("1", write["version"]);
        Assert.Equal(format == "JSON" ? "\"guest-a\"" : "guest-a", write["guest_id"]);
        Assert.DoesNotContain("guest_name", write.Keys); Assert.DoesNotContain("task_id", write.Keys); Assert.DoesNotContain("host_id", write.Keys);
        Assert.Equal(2, f.Reads); Assert.Empty(await f.Repository.GetPowerRecoveriesAsync());
        Assert.Same(result, await f.Recreate().ControlPowerAsync(request)); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task EmptyAcknowledgementAndTransitionalStateAreNotCompletion()
    {
        using var f = new Fixture { Apply = false }; var request = f.Request(); f.AfterWrite = () => f.Status = "booting";
        using var cancellation = new CancellationTokenSource();
        var observed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.OnRead = () => { if (f.Reads >= 2) observed.TrySetResult(); };
        var operation = f.Repository.ControlPowerAsync(request, cancellation.Token);
        await observed.Task.WaitAsync(TimeSpan.FromSeconds(2)); Assert.False(operation.IsCompleted);
        cancellation.Cancel();
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await operation).Status);
        var recreated = f.Recreate(); Assert.Single(await recreated.GetPowerRecoveriesAsync());
        await recreated.ControlPowerAsync(request); Assert.Single(f.Writes);
        Assert.Equal(MutationErrorCategory.Conflict, (await recreated.ControlPowerAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        f.Status = "running"; f.Name = "renamed-after-submission";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await recreated.ReviewPowerAsync("guest-a"))!.Status); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task LostReplyCanOnlyBeResolvedByReadback()
    {
        using var f = new Fixture { LoseReply = true }; var request = f.Request();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ControlPowerAsync(request)).Status); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData(105, MutationResultStatus.PermissionDenied)] [InlineData(1003, MutationResultStatus.ConfirmedFailure)]
    public async Task ExplicitRejectionIsNotOverwrittenByAnotherActorsStateChange(int code, MutationResultStatus expected)
    {
        using var f = new Fixture { Reject = code }; var request = f.Request(); f.AfterWrite = () => f.Status = "running";
        var result = await f.Repository.ControlPowerAsync(request);
        Assert.Equal(expected, result.Status); Assert.Equal(0, result.Counts.Succeeded); Assert.Equal(1, f.Reads);
        Assert.Empty(await f.Repository.GetPowerRecoveriesAsync()); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("identity")] [InlineData("missing")] [InlineData("wrong-type")]
    public async Task MalformedPostReadbackRemainsPending(string failure)
    {
        using var f = new Fixture(); var request = f.Request(); f.AfterWrite = () => f.ReadFailure = failure;
        var result = await f.Repository.ControlPowerAsync(request);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status); Assert.Single(await f.Repository.GetPowerRecoveriesAsync());
        f.ReadFailure = null; Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewPowerAsync("guest-a"))!.Status); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("name")] [InlineData("state")] [InlineData("identity")]
    public async Task StaleOrAmbiguousPreflightNeverWrites(string change)
    {
        using var f = new Fixture(); var request = f.Request();
        if (change == "name") f.Name = "changed"; else if (change == "state") f.Status = "running"; else f.ReadFailure = "identity";
        Assert.False((await f.Repository.ControlPowerAsync(request)).Submitted); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task InvalidScopeConfirmationActionAndCompoundIdsNeverReachTransport()
    {
        using var f = new Fixture(); var request = f.Request();
        foreach (var invalid in new[] { request with { ProfileId = Guid.NewGuid() }, request with { RiskConfirmed = false }, request with { RequestId = Guid.Empty },
            request with { Action = (VirtualMachinePowerAction)99 }, request with { Baseline = request.Baseline with { Id = "one,two" } },
            request with { Baseline = request.Baseline with { Id = "one\\two" } }, request with { Baseline = request.Baseline with { State = VirtualMachineOperationalState.Unknown } } })
            Assert.False((await f.Repository.ControlPowerAsync(invalid)).Submitted);
        Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task ConcurrentCallsAndCancellationDoNotReplay()
    {
        using var f = new Fixture(); var request = f.Request(); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.WaitWrite = () => release.Task; var first = f.Repository.ControlPowerAsync(request); Assert.Single(f.Writes);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ControlPowerAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        release.SetResult(); await first; Assert.Single(f.Writes);
        using var cancelled = new Fixture(); var other = cancelled.Request(); using var cts = new CancellationTokenSource(); cancelled.AfterWrite = cts.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await cancelled.Repository.ControlPowerAsync(other, cts.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await cancelled.Recreate().ReviewPowerAsync("guest-a"))!.Status); Assert.Single(cancelled.Writes);
    }
    [Fact]
    public async Task PublicEntryRequiresConfirmationCapabilityAndUncancelledPreflight()
    {
        using var f = new Fixture(); var request = f.Request(); Assert.True(f.Repository.CanControlPower);
        Assert.False((await f.Repository.ControlPowerAsync(request with { RiskConfirmed = false })).Submitted);
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.ControlPowerAsync(request, cancelled.Token)).Status);
        f.Capabilities.Remove(Fixture.ActionApi);
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.ControlPowerAsync(request)).Status); Assert.Empty(f.Calls);
    }
    [Theory]
    [InlineData(VirtualMachinePowerAction.PowerOn, "booting", "running")]
    [InlineData(VirtualMachinePowerAction.Shutdown, "shutting_down", "shutdown")]
    [InlineData(VirtualMachinePowerAction.PowerOff, "shutting_down", "shutdown")]
    public async Task AcceptedTransitionWaitsForDesiredStateWithoutRepeatingWrite(VirtualMachinePowerAction action, string intermediate, string desired)
    {
        using var f = new Fixture { Apply = false }; var request = f.Request(action);
        f.AfterWrite = () => f.Status = intermediate;
        f.OnRead = () => { if (f.Reads >= 4) f.Status = desired; };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ControlPowerAsync(request)).Status);
        Assert.Equal(4, f.Reads); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task PendingPowerBlocksDeletionAndReusedRequestIdentity()
    {
        using var f = new Fixture { Apply = false, LoseReply = true }; var power = f.Request();
        await f.Repository.ControlPowerAsync(power);
        var deletion = new VirtualMachineDeleteRequest(f.Profile.Id, power.Baseline, Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.DeleteMachineAsync(deletion)).ErrorCategory);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.DeleteMachineAsync(deletion with { RequestId = power.RequestId })).ErrorCategory);
        Assert.Single(f.Writes);
    }

    private sealed class Fixture : IDisposable
    {
        public const string ActionApi = "SYNO.Virtualization.API.Guest.Action";
        private readonly HttpClient _http; private readonly DsmApiClient _api; private readonly DsmSession _session;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public DsmRepository Repository { get; }
        public string Status { get; set; } = "shutdown"; public string Name { get; set; } = "Synthetic VM";
        public string? ReadFailure { get; set; } public bool Apply { get; set; } = true; public bool LoseReply { get; set; }
        public int? Reject { get; set; } public Action? AfterWrite { get; set; } public Func<Task>? WaitWrite { get; set; }
        public Action? OnRead { get; set; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(call => call["api"] == ActionApi);
        public int Reads => Calls.Count(call => call["method"] == "get");
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); _api = new(_http); _session = new(Profile.Id, "synthetic-sid", "synthetic-token", null);
            foreach (var api in new[] { ActionApi, "SYNO.Virtualization.API.Guest" }) Capabilities[api] = new(api, "vmm-power-synthetic.cgi", 1, 9, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate() => new(Profile, _session, _api, Capabilities);
        public VirtualMachinePowerRequest Request(VirtualMachinePowerAction action = VirtualMachinePowerAction.PowerOn)
        {
            Status = action == VirtualMachinePowerAction.PowerOn ? "shutdown" : "running";
            return new(Profile.Id, new("guest-a", Name, action == VirtualMachinePowerAction.PowerOn ? VirtualMachineOperationalState.Stopped : VirtualMachineOperationalState.Running,
                null, null, null, null, null), action, Guid.NewGuid(), true);
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query); Assert.EndsWith("/webapi/vmm-power-synthetic.cgi", request.RequestUri.AbsolutePath);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                if (call["method"] == "get")
                {
                    owner.OnRead?.Invoke();
                    var data = new JsonObject { ["guest_id"] = owner.ReadFailure == "identity" ? "other-id" : "guest-a", ["guest_name"] = owner.Name, ["status"] = owner.Status };
                    if (owner.ReadFailure == "missing") data.Remove("status"); if (owner.ReadFailure == "wrong-type") data["status"] = true;
                    return Reply(JsonSerializer.Serialize(new { success = true, data }));
                }
                Assert.Equal(ActionApi, call["api"]); Assert.Contains(call["method"], new[] { "poweron", "poweroff", "shutdown" });
                if (owner.WaitWrite is not null) await owner.WaitWrite();
                if (owner.Apply && owner.Reject is null) owner.Status = call["method"] == "poweron" ? "running" : "shutdown";
                owner.AfterWrite?.Invoke(); token.ThrowIfCancellationRequested();
                if (owner.Reject is int code) return Reply(JsonSerializer.Serialize(new { success = false, error = new { code } }));
                if (owner.LoseReply) throw new HttpRequestException("合成回执丢失");
                return Reply("{\"success\":true}");
            }
            private static HttpResponseMessage Reply(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
