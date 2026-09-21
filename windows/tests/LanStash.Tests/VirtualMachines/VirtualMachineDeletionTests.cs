using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineDeletionTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task DeletesOneGuestWithEmptyAcknowledgementAndStrictReadback(string format)
    {
        using var f = new Fixture(format); var request = f.Request();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.DeleteMachineAsync(request)).Status);
        var write = Assert.Single(f.Writes);
        Assert.Equal(format == "JSON" ? "\"guest-a\"" : "guest-a", write["guest_id"]);
        Assert.Equal("1", write["version"]); Assert.DoesNotContain("task_id", write.Keys);
        Assert.All(f.Calls, item => Assert.Equal("SYNO.Virtualization.API.Guest", item["api"]));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().DeleteMachineAsync(request)).Status);
        Assert.Single(f.Writes); Assert.Empty(await f.Repository.GetDeletionRecoveriesAsync());
    }
    [Theory]
    [InlineData("scope")]
    [InlineData("confirmation")]
    [InlineData("id")]
    [InlineData("running")]
    [InlineData("name")]
    public async Task InvalidOrChangedTargetDoesNotDelete(string kind)
    {
        using var f = new Fixture(); var request = f.Request();
        request = kind switch
        {
            "scope" => request with { ProfileId = Guid.NewGuid() },
            "confirmation" => request with { RiskConfirmed = false },
            "id" => request with { Baseline = request.Baseline with { Id = "one,two" } },
            "running" => request with { Baseline = request.Baseline with { State = VirtualMachineOperationalState.Running } },
            _ => request,
        };
        if (kind == "name") f.Name = "changed";
        Assert.False((await f.Repository.DeleteMachineAsync(request)).Submitted); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("missing")]
    [InlineData("numeric")]
    [InlineData("duplicate")]
    public async Task MalformedListCannotProveDeletion(string kind)
    {
        using var f = new Fixture { BadList = kind }; var request = f.Request();
        var result = await f.Repository.DeleteMachineAsync(request);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.Single(await f.Repository.GetDeletionRecoveriesAsync());
        f.BadList = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewDeletionAsync("guest-a"))!.Status);
        Assert.Single(f.Writes);
    }
    [Fact]
    public async Task LostReplyAndExplicitRejectionHaveDifferentOutcomes()
    {
        using var lost = new Fixture { LoseReply = true };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await lost.Repository.DeleteMachineAsync(lost.Request())).Status);
        using var rejected = new Fixture { Reject = 105 };
        Assert.Equal(MutationResultStatus.PermissionDenied, (await rejected.Repository.DeleteMachineAsync(rejected.Request())).Status);
        Assert.Equal(2, rejected.Calls.Count);
    }
    [Fact]
    public async Task PendingDeletionBlocksPowerAndSettingsAndDoesNotReplay()
    {
        using var f = new Fixture { Apply = false }; var request = f.Request();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.DeleteMachineAsync(request)).Status);
        await f.Recreate().DeleteMachineAsync(request); Assert.Single(f.Writes);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.DeleteMachineAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        var power = new VirtualMachinePowerRequest(f.Profile.Id, request.Baseline, VirtualMachinePowerAction.PowerOn, Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ControlPowerAsync(power)).ErrorCategory);
        var settings = new VirtualMachineSettings("guest-a", VirtualMachineOperationalState.Stopped, new("VM", "", 1, 1024, VirtualMachineAutoStart.Off));
        var update = new VirtualMachineSettingsRequest(f.Profile.Id, settings, settings.Configuration with { Description = "new" }, Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.SaveSettingsAsync(update)).ErrorCategory);
        f.Exists = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewDeletionAsync("guest-a"))!.Status);
        Assert.Single(f.Writes);
    }
    [Fact]
    public async Task CancellationAndDuplicateInvocationNeverSendAnotherDelete()
    {
        using var f = new Fixture(); var request = f.Request(); using var cancel = new CancellationTokenSource();
        cancel.Cancel(); Assert.False((await f.Repository.DeleteMachineAsync(request, cancel.Token)).Submitted); Assert.Empty(f.Calls);
        using var after = new CancellationTokenSource(); f.AfterWrite = after.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await f.Repository.DeleteMachineAsync(request, after.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewDeletionAsync("guest-a"))!.Status); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task DeletionCapabilityDoesNotRequirePowerApiAndBlocksNameReuseWhilePending()
    {
        using var f = new Fixture { Apply = false }; f.Capabilities.Remove("SYNO.Virtualization.API.Guest.Action");
        Assert.True(f.Repository.CanDeleteMachines); Assert.False(f.Repository.CanControlPower);
        var request = f.Request(); await f.Repository.DeleteMachineAsync(request);
        foreach (var api in new[] { "SYNO.Virtualization.API.Task.Info", "SYNO.Virtualization.API.Storage", "SYNO.Virtualization.API.Network", "SYNO.Virtualization.API.Guest.Image" })
            f.Capabilities[api] = new(api, "entry.cgi", 1, 1, "FORM");
        var create = new VirtualMachineCreationRequest(f.Profile.Id, new("storage-a", "Storage", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy),
            [new(1024)], [new(null)], new("VM", "", 1, 1024, VirtualMachineAutoStart.Off), Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.CreateMachineAsync(create)).Result.ErrorCategory);
        Assert.Single(f.Writes); Assert.Equal(3, f.Calls.Count);
    }

    private sealed class Fixture : IDisposable
    {
        private readonly HttpClient _http; private readonly DsmApiClient _api; private readonly DsmSession _session;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public DsmRepository Repository { get; }
        public string Name = "VM", Status = "shutdown";
        public bool Exists = true, Apply = true, LoseReply;
        public int? Reject; public string? BadList; public Action? AfterWrite;
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(item => item["method"] == "delete");
        public Fixture(string format = "FORM")
        {
            _http = new(new Handler(this)); _api = new(_http); _session = new(Profile.Id, "synthetic", null, null);
            foreach (var api in new[] { "SYNO.Virtualization.API.Guest", "SYNO.Virtualization.API.Guest.Action" }) Capabilities[api] = new(api, "entry.cgi", 1, 2, format);
            Repository = Recreate();
        }
        public DsmRepository Recreate() => new(Profile, _session, _api, Capabilities);
        public VirtualMachineDeleteRequest Request() => new(Profile.Id, new("guest-a", "VM", VirtualMachineOperationalState.Stopped, null, null, null, null, null), Guid.NewGuid(), true);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                owner.Calls.Add(call);
                if (call["method"] == "get") return Reply(JsonSerializer.Serialize(new { success = true, data = new { guest_id = "guest-a", guest_name = owner.Name, status = owner.Status } }));
                if (call["method"] == "list")
                {
                    var rows = new JsonArray();
                    if (owner.Exists) rows.Add(new JsonObject { ["guest_id"] = "guest-a" });
                    if (owner.BadList == "numeric") rows.Add(new JsonObject { ["guest_id"] = 7 });
                    if (owner.BadList == "duplicate") { rows.Add(new JsonObject { ["guest_id"] = "other" }); rows.Add(new JsonObject { ["guest_id"] = "other" }); }
                    return Reply(JsonSerializer.Serialize(new { success = true, data = owner.BadList == "missing" ? new JsonObject() : new JsonObject { ["guests"] = rows } }));
                }
                Assert.Equal("delete", call["method"]);
                if (owner.Apply) owner.Exists = false;
                owner.AfterWrite?.Invoke(); token.ThrowIfCancellationRequested();
                if (owner.Reject is { } code) return Reply(JsonSerializer.Serialize(new { success = false, error = new { code } }));
                if (owner.LoseReply) throw new HttpRequestException("synthetic");
                return Reply("{\"success\":true}");
            }
            private static HttpResponseMessage Reply(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
