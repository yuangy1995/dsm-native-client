using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineImageDeletionTests
{
    [Theory]
    [InlineData("FORM")]
    [InlineData("JSON")]
    public async Task SingleIdEmptyReplyAndSameApiReadbackDoNotDependOnGuestApi(string format)
    {
        using var f = new Fixture(format); var request = await f.Request();
        Assert.True(f.Repository.CanDeleteVirtualMachineImages); Assert.True(((IVirtualMachineManagerRepository)f.Repository).CanDeleteImages); Assert.False(f.Repository.CanDeleteMachines);
        var result = await f.Repository.DeleteImageAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var write = Assert.Single(f.Writes); Assert.Equal("1", write["version"]);
        Assert.Equal(format == "JSON" ? "\"image-a\"" : "image-a", write["image_id"]);
        Assert.All(f.Calls, item => { Assert.Equal(Fixture.Api, item["api"]); Assert.Contains(item["method"], new[] { "list", "delete" }); });
        await f.Recreate().DeleteImageAsync(request); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("name")]
    [InlineData("type")]
    [InlineData("scope")]
    [InlineData("confirmation")]
    public async Task ChangedOrInvalidTargetDoesNotWrite(string kind)
    {
        using var f = new Fixture(); var request = await f.Request();
        if (kind == "name") f.Name = "changed";
        if (kind == "type") f.Type = "iso";
        if (kind == "scope") request = request with { ProfileId = Guid.NewGuid() };
        if (kind == "confirmation") request = request with { RiskConfirmed = false };
        Assert.False((await f.Repository.DeleteImageAsync(request)).Submitted); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("missing")]
    [InlineData("duplicate")]
    [InlineData("numeric")]
    public async Task InvalidReadbackStaysUnknownAndNeverReplays(string kind)
    {
        using var f = new Fixture(); var request = await f.Request(); f.AfterDelete = () => f.BadList = kind;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.DeleteImageAsync(request)).Status);
        Assert.Single(await f.Repository.GetVirtualMachineImageDeletionRecoveriesAsync());
        await f.Recreate().DeleteImageAsync(request); Assert.Single(f.Writes);
        f.BadList = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewImageDeletionAsync("image-a"))!.Status);
        Assert.Single(f.Writes);
    }
    [Fact]
    public async Task RejectionCannotBeOverwrittenByAbsenceAndLostReplyCanBeVerified()
    {
        using var f = new Fixture { Reject = 105 }; var request = await f.Request();
        Assert.Equal(MutationResultStatus.PermissionDenied, (await f.Repository.DeleteImageAsync(request)).Status);
        Assert.Equal(3, f.Calls.Count);
        using var lost = new Fixture { LoseReply = true };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await lost.Repository.DeleteImageAsync(await lost.Request())).Status);
        Assert.Single(lost.Writes);
    }
    [Fact]
    public async Task PendingImageDeletionBlocksCreationUsingItAndCannotBecomeVmDeletion()
    {
        using var f = new Fixture { Apply = false }; var request = await f.Request(); await f.Repository.DeleteImageAsync(request);
        foreach (var suffix in new[] { "Guest", "Storage", "Task.Info" }) { var api = "SYNO.Virtualization.API." + suffix; f.Capabilities[api] = new(api, "entry.cgi", 1, 1, "FORM"); }
        var creation = new VirtualMachineCreationRequest(f.Profile.Id, new("store", "Store", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy),
            [new(null, request.Baseline)], [new(null)], new("New VM", "", 1, 1024, VirtualMachineAutoStart.Off), Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.CreateMachineAsync(creation)).Result.ErrorCategory);
        var vm = new VirtualMachineDeleteRequest(f.Profile.Id, new("image-a", "Image", VirtualMachineOperationalState.Stopped, null, null, null, null, null), request.RequestId, true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.DeleteMachineAsync(vm)).ErrorCategory);
        Assert.Single(f.Writes);
    }
    [Fact]
    public async Task CancelAfterSubmissionRetainsReadOnlyRecovery()
    {
        using var f = new Fixture(); var request = await f.Request(); using var cancellation = new CancellationTokenSource(); f.AfterDelete = cancellation.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await f.Repository.DeleteImageAsync(request, cancellation.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewImageDeletionAsync(request.Baseline.Id))!.Status);
        Assert.Single(f.Writes);
    }
    private sealed class Fixture : IDisposable
    {
        public const string Api = "SYNO.Virtualization.API.Guest.Image";
        private readonly HttpClient _http; private readonly DsmApiClient _api; private readonly DsmSession _session;
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public DsmRepository Repository { get; }
        public List<Dictionary<string, string>> Calls { get; } = [];
        public IEnumerable<Dictionary<string, string>> Writes => Calls.Where(item => item["method"] == "delete");
        public bool Exists = true, Apply = true, LoseReply; public int? Reject; public string? BadList; public string Name = "Image", Type = "disk"; public Action? AfterDelete;
        public Fixture(string format = "FORM")
        { _http = new(new Handler(this)); _api = new(_http); _session = new(Profile.Id, "synthetic", null, null); Capabilities[Api] = new(Api, "entry.cgi", 1, 2, format); Repository = Recreate(); }
        public DsmRepository Recreate() => new(Profile, _session, _api, Capabilities);
        public async Task<VirtualMachineImageDeleteRequest> Request() => new(Profile.Id, Assert.Single(await Repository.LoadImageDeletionTargetsAsync()), Guid.NewGuid(), true);
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                Assert.Equal(Api, call["api"]);
                if (call["method"] == "list")
                {
                    var rows = new JsonArray(); if (owner.Exists) rows.Add(new JsonObject { ["image_id"] = "image-a", ["image_name"] = owner.Name, ["type"] = owner.Type });
                    if (owner.BadList == "numeric") rows.Add(new JsonObject { ["image_id"] = 7 });
                    if (owner.BadList == "duplicate") { rows.Add(new JsonObject { ["image_id"] = "other" }); rows.Add(new JsonObject { ["image_id"] = "other" }); }
                    return Reply(JsonSerializer.Serialize(new { success = true, data = owner.BadList == "missing" ? new JsonObject() : new JsonObject { ["images"] = rows } }));
                }
                Assert.Equal("delete", call["method"]); if (owner.Apply) owner.Exists = false; owner.AfterDelete?.Invoke(); token.ThrowIfCancellationRequested();
                if (owner.Reject is { } code) return Reply(JsonSerializer.Serialize(new { success = false, error = new { code } }));
                if (owner.LoseReply) throw new HttpRequestException("synthetic");
                return Reply("{\"success\":true}");
            }
            private static HttpResponseMessage Reply(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
