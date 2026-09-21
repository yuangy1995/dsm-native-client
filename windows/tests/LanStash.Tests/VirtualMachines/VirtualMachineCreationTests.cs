using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineCreationTests
{
    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task CreatesOnceBindsTaskAndVerifiesResourcesBeforeApplyingSettings(string format)
    {
        using var f = new Fixture(format); var request = f.Request();
        var result = await f.Repository.CreateMachineAsync(request);
        Assert.Equal(VirtualMachineCreationStage.Complete, result.Stage); Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        var create = Assert.Single(f.Writes("create")); var set = Assert.Single(f.Writes("set"));
        Assert.Equal("false", create["auto_clean_task"]); Assert.Equal(format == "JSON" ? "\"New VM\"" : "New VM", create["guest_name"]);
        Assert.DoesNotContain("vcpu_num", create.Keys); Assert.DoesNotContain("name", create.Keys); Assert.DoesNotContain("synovmm_ui_id", create.Keys);
        Assert.Equal(8192, JsonNode.Parse(create["vdisks"])![0]!["vdisk_size"]!.GetValue<int>());
        Assert.Equal("", JsonNode.Parse(create["vnics"])![0]!["network_id"]!.GetValue<string>());
        Assert.Equal("4", set["vcpu_num"]); Assert.Equal("4096", set["vram_size"]);
        Assert.DoesNotContain("storage_id", set.Keys); Assert.DoesNotContain("new_guest_name", set.Keys);
        Assert.All(f.Calls, call => { Assert.Equal("1", call["version"]); Assert.StartsWith("SYNO.Virtualization.API.", call["api"]); });
        Assert.DoesNotContain(f.Calls, call => call["method"] is "delete" or "clear" or "poweron");
        Assert.Same(result, await f.Recreate().CreateMachineAsync(request)); Assert.Single(f.Writes("create")); Assert.Single(f.Writes("set"));
    }
    [Fact]
    public async Task ReadOnlyReviewNeverStartsDeferredConfiguration()
    {
        using var f = new Fixture { Finished = false }; var request = f.Request();
        Assert.Equal(VirtualMachineCreationStage.Creating, (await f.Repository.CreateMachineAsync(request)).Stage);
        f.Finished = true;
        var review = await f.Recreate().ReviewCreationAsync(request.RequestId); Assert.True(review!.CanContinue); Assert.Equal(VirtualMachineCreationStage.Configure, review.Stage);
        Assert.Empty(f.Writes("set")); await f.Repository.CreateMachineAsync(request); Assert.Empty(f.Writes("set"));
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.ContinueCreationAsync(request.RequestId, true))!.Stage);
        await f.Repository.ContinueCreationAsync(request.RequestId, true); Assert.Single(f.Writes("create")); Assert.Single(f.Writes("set"));
    }
    [Theory]
    [InlineData(true)][InlineData(false)]
    public async Task MissingCreationReceiptNeverAdoptsByNameOrResubmits(bool loseReply)
    {
        using var f = new Fixture { LoseCreateReply = loseReply, MissingTaskId = !loseReply }; var request = f.Request();
        var result = await f.Repository.CreateMachineAsync(request); Assert.Equal(VirtualMachineCreationStage.VerifyReceipt, result.Stage);
        await f.Recreate().CreateMachineAsync(request); await f.Repository.ReviewCreationAsync(request.RequestId);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.CreateMachineAsync(request with { RequestId = Guid.NewGuid() })).Result.ErrorCategory);
        Assert.Single(f.Writes("create")); Assert.Empty(f.Writes("set")); Assert.DoesNotContain(f.Calls, call => call["method"] == "get");
    }
    [Theory]
    [InlineData("old-id")][InlineData("identity")][InlineData("disk")][InlineData("network")][InlineData("storage")]
    public async Task ChangedOrAmbiguousCreatedResourceCannotReceiveConfiguration(string fault)
    {
        using var f = new Fixture(); if (fault == "old-id") { f.Existing = true; f.TaskGuestId = "old-vm"; }
        f.AfterCreate = () =>
        {
            if (fault == "identity") f.Guest["guest_id"] = "unrelated";
            if (fault == "disk") f.Guest["vdisks"]![0]!["vdisk_size"] = 1;
            if (fault == "network") f.Guest["vnics"]![0]!["network_id"] = "unrelated";
            if (fault == "storage") f.Guest["storage_id"] = "unrelated";
        };
        var result = await f.Repository.CreateMachineAsync(f.Request());
        Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory); Assert.NotEqual(VirtualMachineCreationStage.Complete, result.Stage); Assert.Empty(f.Writes("set"));
    }
    [Fact]
    public async Task UnknownConfigurationOnlyReviewsAndDoesNotRepeatSet()
    {
        using var f = new Fixture { ApplySettings = false }; var request = f.Request();
        var result = await f.Repository.CreateMachineAsync(request); Assert.Equal(VirtualMachineCreationStage.VerifyConfiguration, result.Stage);
        await f.Recreate().ContinueCreationAsync(request.RequestId, true); Assert.Single(f.Writes("set"));
        f.Apply(request.Settings);
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.ReviewCreationAsync(request.RequestId))!.Stage); Assert.Single(f.Writes("create"));
    }
    [Fact]
    public async Task ExplicitConfigurationRejectionIsPartialAndNeverDeletesCreatedGuest()
    {
        using var f = new Fixture { SetError = 105 }; var request = f.Request();
        var result = await f.Repository.CreateMachineAsync(request);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Result.Status); Assert.Equal(MutationErrorCategory.Permission, result.Result.ErrorCategory);
        Assert.Equal(1, result.Result.Counts.Failed); Assert.NotNull(result.VirtualMachineId);
        Assert.Same(result, await f.Repository.ReviewCreationAsync(request.RequestId)); Assert.DoesNotContain(f.Calls, call => call["method"] == "delete");
    }
    [Fact]
    public async Task LostSetResponseCanBeConfirmedByExactFinalReadback()
    {
        using var f = new Fixture { LoseSetReply = true };
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.CreateMachineAsync(f.Request())).Stage); Assert.Single(f.Writes("set"));
    }
    [Fact]
    public async Task FinalResourceChangesCannotBeHiddenByMatchingCpuAndMemory()
    {
        using var f = new Fixture(); f.AfterSet = () => f.Guest["vdisks"]![0]!["vdisk_size"] = 1;
        var result = await f.Repository.CreateMachineAsync(f.Request());
        Assert.NotEqual(VirtualMachineCreationStage.Complete, result.Stage); Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory);
    }
    [Fact]
    public async Task RunningGuestHardwareWaitsWithoutForcedPowerActions()
    {
        using var f = new Fixture(); f.AfterCreate = () => f.Guest["status"] = "running"; var request = f.Request();
        Assert.Equal(VirtualMachineCreationStage.Configure, (await f.Repository.CreateMachineAsync(request)).Stage); Assert.Empty(f.Writes("set"));
        f.Guest["status"] = "shutdown";
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.ContinueCreationAsync(request.RequestId, true))!.Stage);
        Assert.DoesNotContain(f.Calls, call => call["api"].EndsWith(".Action", StringComparison.Ordinal));
    }
    [Fact]
    public async Task ImageCloneRequiresBoundSuccessfulTaskNotSizeAlone()
    {
        using var f = new Fixture { Finished = false }; var request = f.Request() with { Disks = [new(null, Fixture.Image)] };
        var result = await f.Repository.CreateMachineAsync(request);
        Assert.Equal(VirtualMachineCreationStage.Creating, result.Stage); Assert.Equal(1, result.Result.Counts.Unknown); Assert.Empty(f.Writes("set"));
        Assert.Equal("image-a", JsonNode.Parse(Assert.Single(f.Writes("create"))["vdisks"])![0]!["image_id"]!.GetValue<string>());
        f.Finished = true; f.MutateTask = info => info["status"] = "failed";
        Assert.Equal(VirtualMachineCreationStage.Creating, (await f.Repository.ReviewCreationAsync(request.RequestId))!.Stage); Assert.Empty(f.Writes("set"));
        f.MutateTask = info => info["progress"] = 99;
        Assert.Equal(VirtualMachineCreationStage.Creating, (await f.Repository.ReviewCreationAsync(request.RequestId))!.Stage); Assert.Empty(f.Writes("set"));
        f.MutateTask = null;
        Assert.Equal(VirtualMachineCreationStage.Configure, (await f.Repository.ReviewCreationAsync(request.RequestId))!.Stage); Assert.Empty(f.Writes("set"));
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.ContinueCreationAsync(request.RequestId, true))!.Stage);
        Assert.Single(f.Writes("create")); Assert.Single(f.Writes("set")); Assert.Empty(await f.Repository.GetCreationRecoveriesAsync());
    }
    [Theory]
    [InlineData("name")][InlineData("storage")][InlineData("network")]
    public async Task PreflightChangesPreventCreation(string fault)
    {
        using var f = new Fixture(); var request = f.Request();
        if (fault == "name") { f.Existing = true; f.ExistingName = "NEW VM"; }
        if (fault == "storage") f.StorageStatus = "offline";
        if (fault == "network") request = request with { Networks = [new(new("missing", "Missing", VirtualizationResourceKind.Network, VirtualizationResourceHealth.Unknown))] };
        Assert.False((await f.Repository.CreateMachineAsync(request)).Result.Submitted); Assert.Empty(f.Writes("create"));
    }
    [Fact]
    public async Task CapabilityConfirmationValidationAndCancelledPreparationDoNotSend()
    {
        using var f = new Fixture(); var request = f.Request();
        Assert.True(f.Repository.CanCreateMachine); Assert.False((await f.Repository.CreateMachineAsync(request with { RiskConfirmed = false })).Result.Submitted);
        Assert.False((await f.Repository.CreateMachineAsync(request with { RiskConfirmed = false })).Result.Submitted);
        Assert.False((await f.Repository.CreateMachineAsync(request with { ProfileId = Guid.NewGuid() })).Result.Submitted);
        Assert.False((await f.Repository.CreateMachineAsync(request with { Disks = [new(0)] })).Result.Submitted);
        using var token = new CancellationTokenSource(); token.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.CreateMachineAsync(request, token.Token)).Result.Status); Assert.Empty(f.Calls);
    }
    [Fact]
    public async Task CancellationAfterCreateOrSetNeverReplaysWrites()
    {
        using var create = new Fixture(); using var cancellation = new CancellationTokenSource(); create.AfterCreate = cancellation.Cancel;
        var request = create.Request(); Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await create.Repository.CreateMachineAsync(request, cancellation.Token)).Result.Status);
        await create.Repository.CreateMachineAsync(request); Assert.Single(create.Writes("create"));
        using var set = new Fixture(); using var afterSet = new CancellationTokenSource(); set.AfterSet = afterSet.Cancel;
        var next = set.Request(); await set.Repository.CreateMachineAsync(next, afterSet.Token);
        Assert.Equal(VirtualMachineCreationStage.Complete, (await set.Recreate().ReviewCreationAsync(next.RequestId))!.Stage); Assert.Single(set.Writes("set"));
    }
    [Fact]
    public async Task PendingCreationProtectsItsNameAndNewGuestFromPowerAndSettings()
    {
        using var f = new Fixture { Finished = false }; var request = f.Request(); await f.Repository.CreateMachineAsync(request);
        var power = new VirtualMachinePowerRequest(f.Profile.Id, new("created-vm", "New VM", VirtualMachineOperationalState.Stopped, null, null, null, null, null), VirtualMachinePowerAction.PowerOn, Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ControlPowerAsync(power)).ErrorCategory);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().DeleteMachineAsync(new(f.Profile.Id, power.Baseline, Guid.NewGuid(), true))).ErrorCategory);
        var settings = new VirtualMachineSettingsRequest(f.Profile.Id, new("created-vm", VirtualMachineOperationalState.Stopped, request.Settings), request.Settings with { Description = "other" }, Guid.NewGuid(), true);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().SaveSettingsAsync(settings)).ErrorCategory);
        Assert.Single(f.Writes("create")); Assert.Empty(f.Writes("set"));
    }
    [Fact]
    public async Task ConfirmedConfigurationListsAreFrozenBeforeFirstAwait()
    {
        using var f = new Fixture(); var disks = new List<VirtualMachineCreationDisk> { new(8192) }; var request = f.Request() with { Disks = disks };
        f.BeforeGuestList = () => disks[0] = new(123);
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.CreateMachineAsync(request)).Stage);
        Assert.Equal(8192, JsonNode.Parse(Assert.Single(f.Writes("create"))["vdisks"])![0]!["vdisk_size"]!.GetValue<int>());
    }
    [Fact]
    public async Task ExplicitCreationRejectionNeverStartsReadbackOrConfiguration()
    {
        using var f = new Fixture { CreateError = 105 }; var request = f.Request();
        var result = await f.Repository.CreateMachineAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status); Assert.Equal(MutationErrorCategory.Permission, result.Result.ErrorCategory);
        Assert.Same(result, await f.Repository.CreateMachineAsync(request));
        Assert.DoesNotContain(f.Calls, call => call["method"] is "get" or "set"); Assert.Single(f.Writes("create"));
    }
    [Fact]
    public async Task RepeatedNewRequestAfterSuccessSeesExistingGuestInsteadOfCreatingDuplicate()
    {
        using var f = new Fixture(); var request = f.Request(); await f.Repository.CreateMachineAsync(request);
        var duplicate = await f.Repository.CreateMachineAsync(request with { RequestId = Guid.NewGuid() });
        Assert.False(duplicate.Result.Submitted); Assert.Equal(MutationErrorCategory.Conflict, duplicate.Result.ErrorCategory); Assert.Single(f.Writes("create"));
    }
    [Fact]
    public async Task ReviewStopsWhenRequiredPublicVersionIsNoLongerAvailable()
    {
        using var f = new Fixture { Finished = false }; var request = f.Request(); await f.Repository.CreateMachineAsync(request);
        var count = f.Calls.Count; var name = "SYNO.Virtualization.API.Task.Info";
        f.Capabilities[name] = f.Capabilities[name] with { MinVersion = 2 };
        Assert.Equal(MutationErrorCategory.Unsupported, (await f.Repository.ReviewCreationAsync(request.RequestId))!.Result.ErrorCategory);
        Assert.Equal(count, f.Calls.Count);
    }
    [Fact]
    public async Task DisconnectedNetworkDoesNotDependOnNetworkListCapability()
    {
        using var f = new Fixture(); f.Capabilities.Remove("SYNO.Virtualization.API.Network");
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.CreateMachineAsync(f.Request())).Stage);
        Assert.DoesNotContain(f.Calls, call => call["api"].EndsWith(".Network", StringComparison.Ordinal));
    }
    [Fact]
    public async Task RecoveryDoesNotLeakAcrossProfilesOrAllowEditingStoredConfiguration()
    {
        using var f = new Fixture { Finished = false }; var request = f.Request(); await f.Repository.CreateMachineAsync(request);
        var recovery = Assert.Single(await f.Recreate().GetCreationRecoveriesAsync()); Assert.False(recovery.Request.RiskConfirmed);
        Assert.Equal(request.RequestId, recovery.Request.RequestId);
        ((VirtualMachineCreationDisk[])recovery.Request.Disks)[0] = new(1);
        var other = f.RecreateOtherProfile(); Assert.Empty(await other.GetCreationRecoveriesAsync()); Assert.Null(await other.ReviewCreationAsync(request.RequestId));
        f.Finished = true;
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.ContinueCreationAsync(request.RequestId, true))!.Stage);
        Assert.Empty(await f.Repository.GetCreationRecoveriesAsync());
    }
    [Fact]
    public async Task PublicWriteAvailabilityDoesNotBypassMissingOrMismatchedSessions()
    {
        using var f = new Fixture(); var request = f.Request();
        foreach (var mismatch in new[] { false, true })
        {
            var repository = f.RecreateInvalidSession(mismatch);
            Assert.False(repository.CanCreateMachine); Assert.False(repository.CanControlPower); Assert.False(repository.CanEditSettings);
            Assert.Equal(MutationResultStatus.Unsupported, (await repository.CreateMachineAsync(request)).Result.Status);
            var baseline = new VirtualMachineSettings("guest-a", VirtualMachineOperationalState.Stopped, request.Settings);
            Assert.Equal(MutationResultStatus.Unsupported, (await repository.SaveSettingsAsync(new VirtualMachineSettingsRequest(f.Profile.Id, baseline, request.Settings with { Description = "change" }, Guid.NewGuid(), true))).Status);
            Assert.Empty(f.Calls);
        }
    }
    [Fact]
    public async Task CreationIdCannotBeReusedAcrossDifferentConfirmedConfiguration()
    {
        using var f = new Fixture(); var request = f.Request(); await f.Repository.CreateMachineAsync(request);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.CreateMachineAsync(request with { Settings = request.Settings with { MemoryMiB = 8192 } })).Result.ErrorCategory);
        Assert.Single(f.Writes("create"));
    }

    [Fact]
    public async Task FinishedCreationTaskCannotBeClearedBeforeResourceVerification()
    {
        using var f = new Fixture { Finished = false }; var request = f.Request();
        await f.Repository.CreateMachineAsync(request); f.Finished = true;
        var task = Assert.Single(await f.Repository.LoadVirtualMachineTasksAsync());
        Assert.Equal(VirtualMachineTaskState.Finished, task.State); Assert.True(task.IsProtected);
        var cleanup = new VirtualMachineTaskCleanupRequest(f.Profile.Id, Guid.NewGuid(), [task.Key], true);
        var result = await f.Repository.ClearFinishedTasksAsync(cleanup);
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.Equal(1, result.NotStartedCount);
        Assert.Empty(f.Writes("clear"));
    }

    [Fact]
    public async Task PendingCreationProtectsItsSourceImageFromDeletion()
    {
        using var f = new Fixture { Finished = false };
        var image = Assert.Single(await f.Repository.LoadImageDeletionTargetsAsync());
        var request = f.Request() with { Disks = [new(null, image)] }; await f.Repository.CreateMachineAsync(request);
        var result = await f.Repository.DeleteImageAsync(new(f.Profile.Id, image, Guid.NewGuid(), true));
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.Empty(f.Writes("delete"));
    }

    [Theory]
    [InlineData("FORM")][InlineData("JSON")]
    public async Task OptionalPowerOnRunsOnceOnlyAfterResourceAndConfigurationProof(string format)
    {
        using var f = new Fixture(format); var request = f.Request() with { PowerOnAfterCreation = true };
        var result = await f.Repository.CreateMachineAsync(request);
        Assert.Equal(VirtualMachineCreationStage.Complete, result.Stage); Assert.Equal(3, result.Result.Counts.Succeeded);
        var power = Assert.Single(f.Writes("poweron")); Assert.Equal("SYNO.Virtualization.API.Guest.Action", power["api"]); Assert.Equal("1", power["version"]);
        Assert.Equal(format == "JSON" ? "\"created-vm\"" : "created-vm", power["guest_id"]);
        Assert.True(f.Calls.IndexOf(Assert.Single(f.Writes("set"))) < f.Calls.IndexOf(power));
        Assert.DoesNotContain("poweron_after_create", Assert.Single(f.Writes("create")).Keys);
        Assert.Same(result, await f.Recreate().CreateMachineAsync(request)); await f.Repository.ContinueCreationAsync(request.RequestId, true);
        Assert.Single(f.Writes("create")); Assert.Single(f.Writes("set")); Assert.Single(f.Writes("poweron"));
    }
    [Fact]
    public async Task DeferredPowerRequiresNewConfirmationAndReadOnlyRecoveryNeverStartsIt()
    {
        using var f = new Fixture { ApplySettings = false }; var request = f.Request() with { PowerOnAfterCreation = true };
        await f.Repository.CreateMachineAsync(request); f.Apply(request.Settings);
        var review = await f.Recreate().ReviewCreationAsync(request.RequestId);
        Assert.Equal(VirtualMachineCreationStage.PowerOn, review!.Stage); Assert.True(review.CanContinue); Assert.Empty(f.Writes("poweron"));
        await f.Repository.CreateMachineAsync(request); await f.Repository.ContinueCreationAsync(request.RequestId, false); Assert.Empty(f.Writes("poweron"));
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.ContinueCreationAsync(request.RequestId, true))!.Stage);
        Assert.Single(f.Writes("set")); Assert.Single(f.Writes("poweron"));
    }
    [Fact]
    public async Task UnknownPowerKeepsCreationAndTaskProtectedAndNeverRepeatsStart()
    {
        using var f = new Fixture { ApplyPower = false, LosePowerReply = true }; var request = f.Request() with { PowerOnAfterCreation = true };
        var result = await f.Repository.CreateMachineAsync(request); Assert.Equal(VirtualMachineCreationStage.VerifyPower, result.Stage);
        Assert.True(Assert.Single(await f.Repository.LoadVirtualMachineTasksAsync()).IsProtected);
        Assert.True(Assert.Single(await f.Recreate().GetCreationRecoveriesAsync()).Request.PowerOnAfterCreation);
        await f.Recreate().ContinueCreationAsync(request.RequestId, true); Assert.Single(f.Writes("poweron"));
        var deletion = await f.Repository.DeleteMachineAsync(new(f.Profile.Id, new("created-vm", "New VM", VirtualMachineOperationalState.Stopped, null, null, null, null, null), Guid.NewGuid(), true));
        Assert.Equal(MutationErrorCategory.Conflict, deletion.ErrorCategory); Assert.Empty(f.Writes("delete"));
        f.Guest["status"] = "running";
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Recreate().ReviewCreationAsync(request.RequestId))!.Stage);
        Assert.Empty(await f.Repository.GetCreationRecoveriesAsync()); Assert.Single(f.Writes("poweron"));
    }
    [Fact]
    public async Task ExplicitPowerRejectionLeavesCreatedGuestAndDoesNotBecomeSuccessFromLaterRunningState()
    {
        using var f = new Fixture { PowerError = 105 }; var request = f.Request() with { PowerOnAfterCreation = true };
        var result = await f.Repository.CreateMachineAsync(request); Assert.Equal(VirtualMachineCreationStage.Rejected, result.Stage);
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Result.Status); Assert.Equal(MutationErrorCategory.Permission, result.Result.ErrorCategory);
        f.Guest["status"] = "running"; Assert.Same(result, await f.Repository.ReviewCreationAsync(request.RequestId));
        Assert.DoesNotContain(f.Calls, call => call["method"] is "delete" or "poweroff" or "clear");
    }
    [Fact]
    public async Task CancelledPowerSubmissionCanOnlyBeReviewed()
    {
        using var f = new Fixture(); using var cancellation = new CancellationTokenSource(); f.AfterPower = cancellation.Cancel;
        var request = f.Request() with { PowerOnAfterCreation = true };
        Assert.Equal(VirtualMachineCreationStage.VerifyPower, (await f.Repository.CreateMachineAsync(request, cancellation.Token)).Stage);
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Recreate().ReviewCreationAsync(request.RequestId))!.Stage);
        Assert.Single(f.Writes("poweron"));
    }
    [Fact]
    public async Task MissingPowerCapabilityDoesNotPreventOrdinaryCreationButRejectsRequestedPowerBeforeWriting()
    {
        using var f = new Fixture(); f.Capabilities.Remove("SYNO.Virtualization.API.Guest.Action"); var request = f.Request();
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.CreateMachineAsync(request with { PowerOnAfterCreation = true })).Result.Status); Assert.Empty(f.Calls);
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.CreateMachineAsync(request)).Stage);
    }
    [Fact]
    public async Task MissingCloneReceiptOrChangedConfigurationCannotTriggerAutomaticPower()
    {
        using var image = new Fixture { LoseCreateReply = true }; var request = image.Request() with { PowerOnAfterCreation = true, Disks = [new(null, Fixture.Image)] };
        Assert.Equal(VirtualMachineCreationStage.VerifyReceipt, (await image.Repository.CreateMachineAsync(request)).Stage); Assert.Empty(image.Writes("poweron"));
        using var changed = new Fixture(); changed.AfterSet = () => changed.Guest["vdisks"]![0]!["vdisk_size"] = 1;
        Assert.NotEqual(VirtualMachineCreationStage.Complete, (await changed.Repository.CreateMachineAsync(changed.Request() with { PowerOnAfterCreation = true })).Stage);
        Assert.Empty(changed.Writes("poweron"));
    }
    [Theory]
    [InlineData("FORM", false)][InlineData("JSON", true)]
    public async Task VerifiedCloneCompletesAndOnlyPowersOnWhenRequested(string format, bool powerOn)
    {
        using var f = new Fixture(format); var request = f.Request() with { Disks = [new(null, Fixture.Image)], PowerOnAfterCreation = powerOn };
        var result = await f.Repository.CreateMachineAsync(request);
        Assert.Equal(VirtualMachineCreationStage.Complete, result.Stage); Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(powerOn ? 1 : 0, f.Writes("poweron").Count()); Assert.Single(f.Writes("create"));
        Assert.Empty(await f.Repository.GetCreationRecoveriesAsync());
    }
    [Theory]
    [InlineData("missing-status")][InlineData("wrong-status")][InlineData("missing-progress")][InlineData("unfinished-progress")][InlineData("string-progress")]
    public async Task FinishedFlagAloneCannotAuthorizeConfigurationOrPower(string fault)
    {
        using var f = new Fixture(); f.MutateTask = info =>
        {
            switch (fault)
            {
                case "missing-status": info.Remove("status"); break;
                case "wrong-status": info["status"] = "failed"; break;
                case "missing-progress": info.Remove("progress"); break;
                case "unfinished-progress": info["progress"] = 50; break;
                default: info["progress"] = "100"; break;
            }
        };
        var result = await f.Repository.CreateMachineAsync(f.Request() with { Disks = [new(null, Fixture.Image)], PowerOnAfterCreation = true });
        Assert.NotEqual(VirtualMachineCreationStage.Complete, result.Stage); Assert.Empty(f.Writes("set")); Assert.Empty(f.Writes("poweron"));
    }
    [Theory]
    [InlineData("disk-id")][InlineData("disk-size")][InlineData("nic-id")][InlineData("mac")][InlineData("controller")]
    public async Task CloneHardwareCannotDriftWhileSettingsAreApplied(string fault)
    {
        using var f = new Fixture(); f.AfterSet = () =>
        {
            switch (fault)
            {
                case "disk-id": f.Guest["vdisks"]![0]!["vdisk_id"] = "changed"; break;
                case "disk-size": f.Guest["vdisks"]![0]!["vdisk_size"] = 1; break;
                case "nic-id": f.Guest["vnics"]![0]!["vnic_id"] = "changed"; break;
                case "mac": f.Guest["vnics"]![0]!["mac"] = "02:00:00:00:00:ff"; break;
                default: f.Guest["vdisks"]![0]!["controller"] = 2; break;
            }
        };
        var request = f.Request() with { Disks = [new(null, Fixture.Image)], PowerOnAfterCreation = true };
        Assert.Equal(VirtualMachineCreationStage.VerifyConfiguration, (await f.Repository.CreateMachineAsync(request)).Stage);
        await f.Repository.ReviewCreationAsync(request.RequestId); Assert.Single(f.Writes("set")); Assert.Empty(f.Writes("poweron"));
    }
    [Fact]
    public async Task TrustedTaskResultSurvivesTaskExpirationButStillChecksCurrentHardware()
    {
        using var f = new Fixture { ApplySettings = false }; var request = f.Request() with { Disks = [new(null, Fixture.Image)] };
        Assert.Equal(VirtualMachineCreationStage.VerifyConfiguration, (await f.Repository.CreateMachineAsync(request)).Stage);
        var taskReads = f.Calls.Count(call => call["api"].EndsWith(".Task.Info", StringComparison.Ordinal));
        f.FailTaskReads = true; f.Apply(request.Settings);
        Assert.Equal(VirtualMachineCreationStage.Complete, (await f.Repository.ReviewCreationAsync(request.RequestId))!.Stage);
        Assert.Equal(taskReads, f.Calls.Count(call => call["api"].EndsWith(".Task.Info", StringComparison.Ordinal))); Assert.Single(f.Writes("create")); Assert.Single(f.Writes("set"));
    }
    [Theory]
    [InlineData("id")][InlineData("name")][InlineData("type")]
    public async Task ChangedCloneSourcePreventsSubmission(string fault)
    {
        using var f = new Fixture(); if (fault == "id") f.ImageId = "other"; else if (fault == "name") f.ImageName = "Changed"; else f.ImageType = "iso";
        Assert.False((await f.Repository.CreateMachineAsync(f.Request() with { Disks = [new(null, Fixture.Image)] })).Result.Submitted);
        Assert.Empty(f.Writes("create"));
    }
    [Fact]
    public async Task ExistingCreationIdentityCannotBeReusedToAddPowerAuthorization()
    {
        using var f = new Fixture(); var request = f.Request(); await f.Repository.CreateMachineAsync(request);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.CreateMachineAsync(request with { PowerOnAfterCreation = true })).Result.ErrorCategory);
        Assert.Empty(f.Writes("poweron"));
    }

    private sealed class Fixture : IDisposable
    {
        public static readonly VirtualizationResourceSummary Storage = new("store-a", "Pool", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy);
        public static readonly VirtualizationResourceSummary Image = new("image-a", "Disk image", VirtualizationResourceKind.Image, VirtualizationResourceHealth.Unknown, Type: "disk");
        public NasProfile Profile { get; } = new(Guid.NewGuid(), "Synthetic", "nas.invalid", 5001, "synthetic");
        private readonly HttpClient _http; private readonly DsmApiClient _api; private readonly DsmSession _session; private readonly string _format;
        public Dictionary<string, ApiCapability> Capabilities { get; } = [];
        public DsmRepository Repository { get; }
        public JsonObject Guest { get; private set; } = new();
        public List<Dictionary<string, string>> Calls { get; } = [];
        public bool Finished = true, Existing, ApplySettings = true, LoseCreateReply, MissingTaskId, LoseSetReply;
        public int? SetError, CreateError, PowerError;
        public bool ApplyPower = true, LosePowerReply;
        public string TaskGuestId = "created-vm", ExistingName = "Existing VM", StorageStatus = "online";
        public Action? AfterCreate, AfterSet, BeforeGuestList, AfterPower;
        public Action<JsonObject>? MutateTask;
        public bool FailTaskReads;
        public string ImageId = "image-a", ImageName = "Disk image", ImageType = "disk";
        public Fixture(string format = "FORM")
        {
            _format = format; _http = new(new Handler(this)); _api = new(_http); _session = new(Profile.Id, "synthetic-sid", null, null);
            foreach (var suffix in new[] { "Guest", "Guest.Action", "Task.Info", "Storage", "Network", "Guest.Image" })
            { var name = "SYNO.Virtualization.API." + suffix; Capabilities[name] = new(name, "vm-create-synthetic.cgi", 1, 9, format); }
            Repository = Recreate();
        }
        public DsmRepository Recreate() => new(Profile, _session, _api, Capabilities);
        public DsmRepository RecreateOtherProfile()
        { var profile = Profile with { Id = Guid.NewGuid() }; return new(profile, new(profile.Id, "synthetic-sid", null, null), _api, Capabilities); }
        public DsmRepository RecreateInvalidSession(bool mismatch) => new(Profile, new(mismatch ? Guid.NewGuid() : Profile.Id, mismatch ? "synthetic-sid" : "", null, null), _api, Capabilities);
        public VirtualMachineCreationRequest Request() => new(Profile.Id, Storage, [new(8192)], [new(null)], new("New VM", "Configured", 4, 4096, VirtualMachineAutoStart.Off), Guid.NewGuid(), true);
        public IEnumerable<Dictionary<string, string>> Writes(string method) => Calls.Where(call => call["method"] == method);
        public void Apply(VirtualMachineConfiguration settings)
        { Guest["guest_name"] = settings.Name; Guest["description"] = settings.Description; Guest["vcpu_num"] = settings.CpuCount; Guest["vram_size"] = settings.MemoryMiB; Guest["autorun"] = (int)settings.AutoStart; }
        private sealed class Handler(Fixture owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
            {
                Assert.Equal(HttpMethod.Post, request.Method); Assert.Empty(request.RequestUri!.Query); Assert.EndsWith("/vm-create-synthetic.cgi", request.RequestUri.AbsolutePath);
                var call = (await request.Content!.ReadAsStringAsync(token)).Split('&').Select(part => part.Split('=', 2)).ToDictionary(part => WebUtility.UrlDecode(part[0]), part => WebUtility.UrlDecode(part[1])); owner.Calls.Add(call);
                string Text(string key) => owner._format == "JSON" ? JsonSerializer.Deserialize<string>(call[key])! : call[key];
                var api = call["api"]; var method = call["method"];
                if (api.EndsWith(".Guest.Action", StringComparison.Ordinal))
                {
                    Assert.Equal("poweron", method); Assert.Equal("created-vm", Text("guest_id"));
                    if (owner.PowerError is int code) return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = false, error = new { code } }), Encoding.UTF8, "application/json") };
                    if (owner.ApplyPower) owner.Guest["status"] = "running";
                    owner.AfterPower?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.LosePowerReply) throw new HttpRequestException("synthetic");
                    return Reply(new { });
                }
                if (api.EndsWith(".Task.Info", StringComparison.Ordinal))
                {
                    if (owner.FailTaskReads) throw new HttpRequestException("synthetic expired task");
                    if (method == "list") return Reply(new { task_ids = new[] { "@synthetic/create-task" } });
                    Assert.Equal("get", method);
                    var info = new JsonObject { ["guest_id"] = owner.TaskGuestId, ["progress"] = owner.Finished ? 100 : 20, ["status"] = "create" };
                    owner.MutateTask?.Invoke(info); return Reply(new { finish = owner.Finished, task_info = info });
                }
                if (api.EndsWith(".Storage", StringComparison.Ordinal)) return Reply(new { storages = new[] { new { storage_id = "store-a", storage_name = "Pool", status = owner.StorageStatus, size = 30000, used = 1000 } } });
                if (api.EndsWith(".Network", StringComparison.Ordinal)) return Reply(new { networks = Array.Empty<object>() });
                if (api.EndsWith(".Guest.Image", StringComparison.Ordinal)) return Reply(new { images = new[] { new { image_id = owner.ImageId, image_name = owner.ImageName, type = owner.ImageType, size = 8192 } } });
                if (method == "list")
                {
                    owner.BeforeGuestList?.Invoke(); var guests = new JsonArray();
                    if (owner.Existing) guests.Add(new JsonObject { ["guest_id"] = "old-vm", ["guest_name"] = owner.ExistingName, ["status"] = "shutdown" });
                    if (owner.Guest.Count > 0) guests.Add(owner.Guest.DeepClone());
                    return Reply(new JsonObject { ["guests"] = guests });
                }
                if (method == "get") return Reply(owner.Guest);
                if (method == "create")
                {
                    if (owner.CreateError is int code) return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = false, error = new { code } }), Encoding.UTF8, "application/json") };
                    var disks = JsonNode.Parse(call["vdisks"])!.AsArray(); var nics = JsonNode.Parse(call["vnics"])!.AsArray();
                    owner.Guest = new() { ["guest_id"] = "created-vm", ["guest_name"] = Text("guest_name"), ["storage_id"] = Text("storage_id"), ["description"] = "", ["vcpu_num"] = 1, ["vram_size"] = 1024, ["autorun"] = 0, ["status"] = "shutdown",
                        ["vdisks"] = new JsonArray(disks.Select((disk, i) => (JsonNode)new JsonObject { ["vdisk_id"] = "disk-" + i, ["vdisk_size"] = disk!["vdisk_size"]?.GetValue<int>() ?? 8192 }).ToArray()),
                        ["vnics"] = new JsonArray(nics.Select((nic, i) => (JsonNode)new JsonObject { ["vnic_id"] = "nic-" + i, ["network_id"] = nic!["network_id"]!.GetValue<string>(), ["mac"] = nic["mac"]?.GetValue<string>() ?? "02:00:00:00:00:01" }).ToArray()) };
                    owner.AfterCreate?.Invoke(); token.ThrowIfCancellationRequested();
                    if (owner.LoseCreateReply) throw new HttpRequestException("synthetic");
                    return owner.MissingTaskId ? Reply(new { }) : Reply(new { task_id = "@synthetic/create-task" });
                }
                Assert.Equal("set", method);
                if (owner.ApplySettings && owner.SetError is null)
                {
                    foreach (var key in new[] { "description", "vcpu_num", "vram_size", "autorun" }) if (call.ContainsKey(key)) owner.Guest[key] = key == "description" ? JsonValue.Create(Text(key)) : JsonValue.Create(int.Parse(call[key], System.Globalization.CultureInfo.InvariantCulture));
                }
                owner.AfterSet?.Invoke(); token.ThrowIfCancellationRequested();
                if (owner.SetError is int error) return new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = false, error = new { code = error } }), Encoding.UTF8, "application/json") };
                if (owner.LoseSetReply) throw new HttpRequestException("synthetic");
                return Reply(new { });
            }
            private static HttpResponseMessage Reply(object data) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(new { success = true, data }), Encoding.UTF8, "application/json") };
        }
        public void Dispose() => _http.Dispose();
    }
}
