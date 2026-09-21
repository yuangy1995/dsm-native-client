using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Containers;

public sealed class ContainerMutationTests
{
    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task TransitionDoesNotBypassManagedOrPausedProtection(bool managed, bool paused)
    {
        using var fixture = new Fixture("JSON") { Restarting = true, Managed = managed, Paused = paused };
        Assert.False((await fixture.Repository.MutateContainerAsync(fixture.Request(ContainerMutationAction.Stop))).Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] != "list");
    }
    [Theory]
    [InlineData(ContainerMutationAction.Stop, false)]
    [InlineData(ContainerMutationAction.Stop, true)]
    [InlineData(ContainerMutationAction.Restart, false)]
    [InlineData(ContainerMutationAction.Restart, true)]
    public async Task RestartingContainerCanBeStoppedOrRestarted(ContainerMutationAction action, bool running)
    {
        using var fixture = new Fixture("JSON") { Running = running, Restarting = true };
        var snapshot = await fixture.Repository.LoadSnapshotAsync();
        Assert.Equal(ContainerOperationalState.Restarting, Assert.Single(snapshot.Containers.Items).State);
        var result = await fixture.Repository.MutateContainerAsync(fixture.Request(action));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Single(fixture.Calls, call => call["method"] != "list");
    }

    [Theory]
    [InlineData(ContainerMutationAction.Start)]
    [InlineData(ContainerMutationAction.Delete)]
    public async Task RestartingContainerCannotBeStartedOrDeleted(ContainerMutationAction action)
    {
        using var fixture = new Fixture("FORM") { Restarting = true };
        Assert.False((await fixture.Repository.MutateContainerAsync(fixture.Request(action))).Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] != "list");
    }

    [Theory]
    [InlineData(ContainerMutationAction.Stop)]
    [InlineData(ContainerMutationAction.Restart)]
    public async Task OngoingRestartNeverConfirmsCompletion(ContainerMutationAction action)
    {
        using var fixture = new Fixture("JSON") { Restarting = true, KeepRestarting = true };
        var request = fixture.Request(action);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.MutateContainerAsync(request)).Status);
        fixture.Restarting = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ReviewContainerMutationAsync(request.RequestId))!.Status);
        Assert.Single(fixture.Calls, call => call["method"] != "list");
    }
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ProjectOwnershipIsCheckedBeforeAnyMutation(bool managed)
    {
        using var fixture = new Fixture("JSON") { HasProject = true, ProjectManaged = managed };
        var result = await fixture.Repository.MutateContainerAsync(fixture.Request(ContainerMutationAction.Start));
        Assert.Equal(managed ? MutationResultStatus.ConfirmedFailure : MutationResultStatus.ConfirmedSuccess, result.Status);
        if (managed)
        { Assert.Equal(MutationErrorCategory.Permission, result.ErrorCategory); Assert.DoesNotContain(fixture.Calls, call => call["method"] != "list"); }
        Assert.Contains(fixture.Calls, call => call["api"] == "SYNO.Docker.Project");
    }
    [Theory]
    [InlineData("FORM", ContainerMutationAction.Start)]
    [InlineData("FORM", ContainerMutationAction.Stop)]
    [InlineData("FORM", ContainerMutationAction.Restart)]
    [InlineData("FORM", ContainerMutationAction.Delete)]
    [InlineData("JSON", ContainerMutationAction.Start)]
    [InlineData("JSON", ContainerMutationAction.Stop)]
    [InlineData("JSON", ContainerMutationAction.Restart)]
    [InlineData("JSON", ContainerMutationAction.Delete)]
    public async Task OfficialNameAndFlagsAreUsedWithReadbackAndNoReplay(string format, ContainerMutationAction action)
    {
        using var fixture = new Fixture(format) { Running = action is ContainerMutationAction.Stop or ContainerMutationAction.Restart };
        var request = fixture.Request(action);
        Assert.True(fixture.Repository.CanMutateContainers);
        var result = await fixture.Repository.MutateContainerAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var mutation = Assert.Single(fixture.Calls, call => call["method"] != "list");
        Assert.Equal(format == "JSON" ? "\"synthetic-worker\"" : "synthetic-worker", mutation["name"]);
        Assert.Equal("1", mutation["version"]);
        Assert.DoesNotContain("id", mutation.Keys);
        if (action == ContainerMutationAction.Delete)
        { Assert.Equal("false", mutation["force"]); Assert.Equal("false", mutation["preserve_profile"]); }
        else { Assert.DoesNotContain("force", mutation.Keys); Assert.DoesNotContain("preserve_profile", mutation.Keys); }
        Assert.Equal(2, fixture.Calls.Count(call => call["method"] == "list"));
        Assert.Empty(await fixture.Repository.GetContainerMutationRecoveriesAsync());
        Assert.Equal(result, await fixture.Repository.MutateContainerAsync(request));
        Assert.Equal(3, fixture.Calls.Count);
    }

    [Fact]
    public async Task RestartNeedsNewStartTimeAndRecoveryNeverResends()
    {
        using var fixture = new Fixture("JSON") { Running = true, AdvanceRestart = false };
        var request = fixture.Request(ContainerMutationAction.Restart);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.MutateContainerAsync(request)).Status);
        Assert.Single(await fixture.Repository.GetContainerMutationRecoveriesAsync());
        var conflict = await fixture.Repository.MutateContainerAsync(request with { RequestId = Guid.NewGuid() });
        Assert.Equal(MutationErrorCategory.Conflict, conflict.ErrorCategory);
        fixture.StartedAt = "2026-01-01T01:00:00.123456789Z";
        var recreated = fixture.Reconnect();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await recreated.ReviewContainerMutationAsync(request.RequestId))!.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "restart");
        Assert.Empty(await recreated.GetContainerMutationRecoveriesAsync());
    }

    [Fact]
    public async Task LostResponseOnlyChecksTheOriginalTargetAndPreventsDifferentAction()
    {
        using var fixture = new Fixture("FORM") { LoseResponse = true };
        var request = fixture.Request(ContainerMutationAction.Start);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.MutateContainerAsync(request)).Status);
        var conflicting = await fixture.Repository.MutateContainerAsync(request with { Action = ContainerMutationAction.Delete });
        Assert.Equal(MutationErrorCategory.Conflict, conflicting.ErrorCategory);
        fixture.Running = true;
        fixture.Name = "renamed-worker";
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await fixture.Repository.ReviewContainerMutationAsync(request.RequestId))!.Status);
        fixture.Name = "synthetic-worker";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ReviewContainerMutationAsync(request.RequestId))!.Status);
        Assert.Single(fixture.Calls, call => call["method"] != "list");
    }

    [Theory]
    [InlineData("name")]
    [InlineData("state")]
    [InlineData("missing-runtime")]
    [InlineData("paused")]
    [InlineData("restarting")]
    [InlineData("managed")]
    [InlineData("unknown-managed")]
    public async Task ChangedOrUncertainPreflightSendsNoWrite(string change)
    {
        using var fixture = new Fixture("JSON");
        var request = fixture.Request(ContainerMutationAction.Start);
        if (change == "name") fixture.Name = "other";
        if (change == "state") fixture.Running = true;
        if (change == "missing-runtime") fixture.MissingRuntime = true;
        if (change == "paused") fixture.Paused = true;
        if (change == "restarting") fixture.Restarting = true;
        if (change == "managed") fixture.Managed = true;
        if (change == "unknown-managed") fixture.Managed = null;
        Assert.False((await fixture.Repository.MutateContainerAsync(request)).Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] != "list");
    }

    [Theory]
    [InlineData("none")]
    [InlineData("wrong-profile")]
    [InlineData("unsupported")]
    [InlineData("cancelled")]
    public async Task InvalidConfirmationSessionOrCapabilityMakesZeroRequests(string invalid)
    {
        using var fixture = new Fixture("FORM");
        var repository = fixture.Repository;
        var request = fixture.Request(ContainerMutationAction.Start);
        using var cancellation = new CancellationTokenSource();
        if (invalid == "none") request = request with { RiskConfirmed = false };
        if (invalid == "wrong-profile") repository = fixture.Reconnect(wrongProfile: true);
        if (invalid == "unsupported") repository = fixture.Reconnect(unsupported: true);
        if (invalid == "cancelled") cancellation.Cancel();
        Assert.False((await repository.MutateContainerAsync(request, cancellation.Token)).Submitted);
        Assert.Empty(fixture.Calls);
    }

    [Fact]
    public async Task RunningContainerCannotBeDeletedAndRestartWithoutTimeCannotBeSubmitted()
    {
        using var fixture = new Fixture("JSON") { Running = true, StartedAt = "0001-01-01T00:00:00Z" };
        Assert.False((await fixture.Repository.MutateContainerAsync(fixture.Request(ContainerMutationAction.Delete))).Submitted);
        Assert.False((await fixture.Repository.MutateContainerAsync(fixture.Request(ContainerMutationAction.Restart))).Submitted);
        Assert.DoesNotContain(fixture.Calls, call => call["method"] != "list");
    }

    [Fact]
    public async Task ExplicitRejectionIsCachedAndDoesNotBecomeSuccessFromReadback()
    {
        using var fixture = new Fixture("JSON") { Reject = true };
        var request = fixture.Request(ContainerMutationAction.Start);
        var first = await fixture.Repository.MutateContainerAsync(request);
        Assert.Equal(MutationResultStatus.PermissionDenied, first.Status);
        fixture.Running = true;
        Assert.Equal(first, await fixture.Repository.MutateContainerAsync(request));
        Assert.Equal(2, fixture.Calls.Count);
        Assert.Empty(await fixture.Repository.GetContainerMutationRecoveriesAsync());
    }

    [Fact]
    public async Task CancellationAfterSubmissionKeepsRecoveryWithoutReplay()
    {
        using var cancellation = new CancellationTokenSource();
        using var fixture = new Fixture("FORM") { OnMutation = cancellation.Cancel };
        var request = fixture.Request(ContainerMutationAction.Start);
        var first = await fixture.Repository.MutateContainerAsync(request, cancellation.Token);
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, first.Status);
        Assert.Single(await fixture.Repository.GetContainerMutationRecoveriesAsync());
        fixture.Running = true;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await fixture.Repository.ReviewContainerMutationAsync(request.RequestId))!.Status);
        Assert.Single(fixture.Calls, call => call["method"] == "start");
    }

    private sealed class Fixture : IDisposable
    {
        private readonly NasProfile _profile = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic-user");
        private readonly HttpClient _http;
        private readonly DsmApiClient _api;
        private readonly string _format;
        public IContainerManagerRepository Repository { get; }
        public bool Running { get; set; }
        public bool Paused { get; set; }
        public bool Restarting { get; set; }
        public bool Deleted { get; set; }
        public bool MissingRuntime { get; set; }
        public bool? Managed { get; set; } = false;
        public bool ProjectManaged { get; set; }
        public bool HasProject { get; set; }
        public bool AdvanceRestart { get; init; } = true;
        public bool KeepRestarting { get; init; }
        public bool LoseResponse { get; init; }
        public bool Reject { get; init; }
        public Action? OnMutation { get; init; }
        public string Name { get; set; } = "synthetic-worker";
        public string StartedAt { get; set; } = "2026-01-01T00:00:00Z";
        public List<Dictionary<string, string>> Calls { get; } = [];
        public Fixture(string format)
        {
            _format = format;
            _http = new HttpClient(new Handler(this)); _api = new(_http);
            Repository = Reconnect();
        }
        public IContainerManagerRepository Reconnect(bool wrongProfile = false, bool unsupported = false) => new DsmRepository(_profile,
            new(wrongProfile ? Guid.NewGuid() : _profile.Id, "synthetic-sid", "synthetic-token", null), _api,
            new Dictionary<string, ApiCapability> { ["SYNO.Docker.Container"] = new("SYNO.Docker.Container", "entry.cgi", unsupported ? 2 : 1, 2, _format),
                ["SYNO.Docker.Project"] = new("SYNO.Docker.Project", "entry.cgi", 1, 1, _format) });
        public ContainerMutationRequest Request(ContainerMutationAction action) => new(_profile.Id,
            new("synthetic-id", "synthetic-worker", Restarting ? ContainerOperationalState.Restarting : Running ? ContainerOperationalState.Running : ContainerOperationalState.Stopped, "synthetic:latest"), action, Guid.NewGuid(), true);
        private JsonObject Inventory()
        {
            var row = new JsonObject { ["id"] = "synthetic-id", ["name"] = Name, ["image"] = "synthetic:latest", ["status"] = Running ? "running" : "stopped",
                ["is_package"] = Managed, ["Labels"] = HasProject ? new JsonObject { ["com.docker.compose.project"] = "synthetic-project" } : new JsonObject() };
            if (!MissingRuntime) row["State"] = new JsonObject { ["Running"] = Running, ["Paused"] = Paused, ["Restarting"] = Restarting, ["StartedAt"] = StartedAt };
            return new JsonObject { ["containers"] = Deleted ? new JsonArray() : new JsonArray(row) };
        }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query); Assert.Equal("nas.invalid", request.RequestUri.Host);
                var body = await request.Content!.ReadAsStringAsync(cancellationToken);
                var form = body.Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1]));
                Assert.Contains(form["api"], new[] { "SYNO.Docker.Container", "SYNO.Docker.Project" }); owner.Calls.Add(form);
                var data = new JsonObject();
                if (form["api"] == "SYNO.Docker.Project") data = new JsonObject { ["synthetic-project-id"] = new JsonObject { ["name"] = "synthetic-project", ["is_package"] = owner.ProjectManaged } };
                else if (form["method"] == "list") data = owner.Inventory();
                else
                {
                    owner.OnMutation?.Invoke();
                    cancellationToken.ThrowIfCancellationRequested();
                    if (owner.Reject) return Reply("{\"success\":false,\"error\":{\"code\":105}}");
                    if (owner.LoseResponse) throw new HttpRequestException("synthetic");
                    if (form["method"] is "start" or "restart") owner.Running = true;
                    if (form["method"] == "stop") owner.Running = false;
                    if (!owner.KeepRestarting) owner.Restarting = false;
                    if (form["method"] == "delete") owner.Deleted = true;
                    if (form["method"] == "restart" && owner.AdvanceRestart) owner.StartedAt = "2026-01-01T01:00:00Z";
                }
                return Reply(new JsonObject { ["success"] = true, ["data"] = data }.ToJsonString());
            }
            private static HttpResponseMessage Reply(string json) => new(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
