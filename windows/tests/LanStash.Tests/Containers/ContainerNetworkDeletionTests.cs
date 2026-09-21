using System.Text.Json.Nodes;
using LanStash.Domain;
using Fixture = LanStash.Tests.Containers.ContainerNetworkCreationTests.Fixture;

namespace LanStash.Tests.Containers;

public sealed class ContainerNetworkDeletionTests
{
    private static ContainerResourceSummary Target(string id = "network-a", string name = "synthetic-a") =>
        new(id, name, ContainerResourceKind.Network, ContainerOperationalState.Unknown)
        { Network = new("bridge", 0, Array.Empty<string>(), null, null, null, false) };
    private static ContainerNetworkDeleteRequest Request(Fixture f, params ContainerResourceSummary[] targets) =>
        new(f.Profile.Id, targets.Length == 0 ? [Target()] : targets, Guid.NewGuid(), true);
    private static void Add(Fixture f, ContainerResourceSummary? target = null)
    { target ??= Target(); f.AddNetwork(target.Id, target.Name); }

    [Theory]
    [InlineData("FORM")] [InlineData("JSON")]
    public async Task RemoveUsesRecordedObjectArrayAndWhitelistedFieldsExactlyOnce(string format)
    {
        using var f = new Fixture(format); Add(f);
        f.Networks[0]!["unknown_field"] = "not-copied";
        var request = Request(f); var result = await f.Repository.DeleteContainerNetworksCoreAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(1, result.Counts.Succeeded);
        var call = Assert.Single(f.Writes); Assert.Equal("remove", call["method"]); Assert.Equal("1", call["version"]);
        Assert.DoesNotContain("id", call.Keys);
        var row = Assert.Single(JsonNode.Parse(call["networks"])!.AsArray())!.AsObject();
        Assert.Equal(13, row.Count);
        Assert.Equal("network-a", row["id"]!.GetValue<string>()); Assert.Equal("network-a", row["_key"]!.GetValue<string>());
        Assert.Equal("synthetic-a", row["name"]!.GetValue<string>()); Assert.Equal("bridge", row["driver"]!.GetValue<string>());
        Assert.Empty(row["containers"]!.AsArray()); Assert.False(row["enable_ipv6"]!.GetValue<bool>());
        Assert.False(row["disable_masquerade"]!.GetValue<bool>());
        foreach (var key in new[] { "subnet", "gateway", "iprange", "ipv6_subnet", "ipv6_gateway", "ipv6_iprange" }) Assert.Equal("", row[key]!.GetValue<string>());
        Assert.DoesNotContain("unknown_field", row.Select(pair => pair.Key));
        Assert.Empty(await f.Repository.GetNetworkDeletionRecoveriesAsync());
        Assert.Same(result, await f.Recreate().DeleteContainerNetworksCoreAsync(request)); Assert.Single(f.Writes);
    }

    [Theory]
    [InlineData("bridge")] [InlineData("host")] [InlineData("none")]
    public async Task SystemNetworksNeverReachTransport(string name)
    {
        using var f = new Fixture();
        var result = await f.Repository.DeleteContainerNetworksCoreAsync(Request(f, Target(name: name)));
        Assert.False(result.Submitted); Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task InUseUnknownAndInconsistentBaselinesAreRejectedBeforeTransport()
    {
        using var f = new Fixture(); var target = Target();
        var invalid = new[]
        {
            target with { Network = null }, target with { Kind = ContainerResourceKind.Image },
            target with { Network = target.Network! with { ConnectedContainerCount = 1 } },
            target with { Network = target.Network! with { ConnectedContainerNames = ["attached"] } },
            target with { Network = target.Network! with { IsIpv6Enabled = null } },
            target with { Network = target.Network! with { Driver = null } }
        };
        foreach (var item in invalid) Assert.False((await f.Repository.DeleteContainerNetworksCoreAsync(Request(f, item))).Submitted);
        Assert.False((await f.Repository.DeleteContainerNetworksCoreAsync(Request(f, target, target))).Submitted);
        Assert.Empty(f.Calls);
    }

    [Theory]
    [InlineData("name")] [InlineData("driver")] [InlineData("containers")] [InlineData("enable_ipv6")]
    public async Task ChangedOrNowAttachedNetworkInvalidatesConfirmation(string changed)
    {
        using var f = new Fixture(); Add(f);
        f.Networks[0]![changed] = changed switch
        {
            "containers" => new JsonArray("attached"), "enable_ipv6" => JsonValue.Create(true), _ => JsonValue.Create("changed")
        };
        var result = await f.Repository.DeleteContainerNetworksCoreAsync(Request(f));
        Assert.False(result.Submitted); Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.Empty(f.Writes);
    }

    [Theory]
    [InlineData("disable_masquerade")] [InlineData("ipv6_subnet")] [InlineData("gateway")]
    public async Task MalformedRemovalFieldsPreventWrite(string key)
    {
        using var f = new Fixture(); Add(f); f.Networks[0]![key] = new JsonObject();
        Assert.False((await f.Repository.DeleteContainerNetworksCoreAsync(Request(f))).Submitted); Assert.Empty(f.Writes);
    }

    [Fact]
    public async Task PartialBatchKeepsOnlyUnknownTargetsAndNeverResubmits()
    {
        using var f = new Fixture { RemoveIdsToApply = ["network-a"] }; Add(f); var second = Target("network-b", "synthetic-b"); Add(f, second);
        var request = Request(f, Target(), second); var result = await f.Repository.DeleteContainerNetworksCoreAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Status); Assert.Equal(1, result.Counts.Succeeded); Assert.Equal(1, result.Counts.Unknown);
        Assert.Equal("network-b", Assert.Single(await f.Recreate().GetNetworkDeletionRecoveriesAsync()).Id);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().DeleteContainerNetworksCoreAsync(Request(f, second))).ErrorCategory);
        await f.Recreate().DeleteContainerNetworksCoreAsync(request); Assert.Single(f.Writes);
        f.Networks.Clear();
        var verified = await f.Recreate().ReviewNetworkDeletionAsync("network-b");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, verified!.Status); Assert.Equal(2, verified.Counts.Succeeded);
        Assert.Empty(await f.Repository.GetNetworkDeletionRecoveriesAsync()); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task LostReplyRequiresIdentityAbsenceNotNameAbsence()
    {
        using var f = new Fixture { Apply = false, LoseReply = true }; Add(f);
        f.AfterRemove = () => f.Networks[0]!["name"] = "renamed";
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.DeleteContainerNetworksCoreAsync(Request(f))).Status);
        f.Networks.Clear(); f.AddNetwork("replacement-id", "synthetic-a");
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewNetworkDeletionAsync("network-a"))!.Status);
        Assert.Single(f.Writes);
    }

    [Theory]
    [InlineData(105, MutationResultStatus.PermissionDenied)] [InlineData(120, MutationResultStatus.ConfirmedFailure)]
    public async Task ExplicitRejectionCannotBecomeSuccessWhenAnotherClientRemovesTarget(int code, MutationResultStatus status)
    {
        using var f = new Fixture { Reject = code }; Add(f); f.AfterRemove = f.Networks.Clear;
        var result = await f.Repository.DeleteContainerNetworksCoreAsync(Request(f));
        Assert.Equal(status, result.Status); Assert.Equal(0, result.Counts.Succeeded); Assert.Equal(1, result.Counts.Failed);
        Assert.Empty(await f.Repository.GetNetworkDeletionRecoveriesAsync()); Assert.Single(f.Writes);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task MissingOrNonemptyFailureListIsNotSuccessWithoutReadback(bool nonempty)
    {
        using var f = new Fixture { Apply = false, RemoveResponse = nonempty ? new() { ["failed"] = new JsonArray("network-a") } : new() }; Add(f);
        var result = await f.Repository.DeleteContainerNetworksCoreAsync(Request(f));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.Equal("container.network.delete.response-unverified", result.DiagnosticTag);
        f.Networks.Clear(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewNetworkDeletionAsync("network-a"))!.Status);
        Assert.Single(f.Writes);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task MalformedOrIncompleteReadbackNeverProvesAbsence(bool incomplete)
    {
        using var f = new Fixture(); Add(f);
        f.AfterRemove = () => f.TransformList = data => incomplete ? new JsonObject { ["network"] = new JsonArray(), ["total"] = 1 } : new();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.DeleteContainerNetworksCoreAsync(Request(f))).Status);
        Assert.Single(await f.Repository.GetNetworkDeletionRecoveriesAsync()); f.TransformList = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewNetworkDeletionAsync("network-a"))!.Status); Assert.Single(f.Writes);
    }

    [Fact]
    public async Task PendingCreateAndDeleteBlockEachOthersTargets()
    {
        using var deletion = new Fixture { Apply = false }; Add(deletion);
        await deletion.Repository.DeleteContainerNetworksCoreAsync(Request(deletion)); deletion.Networks.Clear();
        var create = deletion.Request(new("synthetic-a"));
        Assert.Equal(MutationErrorCategory.Conflict, (await deletion.Recreate().CreateContainerNetworkCoreAsync(create)).ErrorCategory); Assert.Single(deletion.Writes);
        using var creation = new Fixture { Apply = false }; await creation.Repository.CreateContainerNetworkCoreAsync(creation.Request(new("synthetic-a"))); Add(creation);
        Assert.Equal(MutationErrorCategory.Conflict, (await creation.Recreate().DeleteContainerNetworksCoreAsync(Request(creation))).ErrorCategory); Assert.Single(creation.Writes);
    }

    [Fact]
    public async Task ConcurrentAndCancelledRequestsPreserveSingleSubmissionAndRecovery()
    {
        using var f = new Fixture(); Add(f); using var before = new CancellationTokenSource(); before.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.DeleteContainerNetworksCoreAsync(Request(f), before.Token)).Status); Assert.Empty(f.Calls);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); f.WaitRemove = () => release.Task;
        var first = f.Repository.DeleteContainerNetworksCoreAsync(Request(f)); Assert.Single(f.Writes);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().DeleteContainerNetworksCoreAsync(Request(f))).ErrorCategory);
        release.SetResult(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await first).Status);
        using var after = new Fixture(); Add(after); using var cancel = new CancellationTokenSource(); after.AfterRemove = cancel.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await after.Repository.DeleteContainerNetworksCoreAsync(Request(after), cancel.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await after.Recreate().ReviewNetworkDeletionAsync("network-a"))!.Status); Assert.Single(after.Writes);
    }

    [Fact]
    public async Task PublicDeletionStillRejectsChangedPayloadWrongProfileAndMissingConfirmation()
    {
        using var f = new Fixture(); Add(f); var request = Request(f);
        Assert.False((await f.Repository.DeleteContainerNetworksCoreAsync(request with { ProfileId = Guid.NewGuid() })).Submitted);
        Assert.False((await f.Repository.DeleteContainerNetworksCoreAsync(request with { RiskConfirmed = false })).Submitted);
        await f.Repository.PrepareNetworkManagementAsync(); Assert.True(f.Repository.CanDeleteNetworks);
        Assert.False((await f.Repository.DeleteNetworksAsync(request with { RiskConfirmed = false })).Submitted); Assert.Empty(f.Writes);
        await f.Repository.DeleteNetworksAsync(request);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.DeleteContainerNetworksCoreAsync(request with { Baselines = [Target("other-id")] })).ErrorCategory);
        Assert.Single(f.Writes);
    }
}
