using LanStash.Domain;
using System.Text.Json.Nodes;
using Fixture = LanStash.Tests.NasAdmin.NasTaskReadTests.Fixture;

namespace LanStash.Tests.NasAdmin;

public sealed class NasTaskCommandTests
{
    private static async Task<NasTaskCommandRequest> Request(Fixture f, NasTaskCommand command)
    {
        f.Tasks["tasks"]![0]!["enable"] = command != NasTaskCommand.Enable; f.Detail["enable"] = command != NasTaskCommand.Enable;
        var task = Assert.Single(await f.Repository.LoadScheduledTasksAsync());
        var detail = await f.Repository.LoadScheduledTaskDetailAsync(task.Id, task.RealOwner); f.Calls.Clear();
        return new(f.Profile.Id, task, command, detail, Guid.NewGuid(), true);
    }

    [Theory]
    [InlineData("FORM", NasTaskCommand.Enable)] [InlineData("JSON", NasTaskCommand.Enable)]
    [InlineData("FORM", NasTaskCommand.Disable)] [InlineData("JSON", NasTaskCommand.Disable)]
    [InlineData("FORM", NasTaskCommand.Run)] [InlineData("JSON", NasTaskCommand.Run)]
    [InlineData("FORM", NasTaskCommand.Delete)] [InlineData("JSON", NasTaskCommand.Delete)]
    public async Task CommandsUseV3AndNeverSendScriptsOrSubstituteOwner(string format, NasTaskCommand command)
    {
        using var f = new Fixture(format); var request = await Request(f, command);
        var result = await f.Repository.ExecuteTaskCommandCoreAsync(request); Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var write = Assert.Single(f.Commands); Assert.Equal("3", write["version"]); Assert.Equal("12", write["id"]);
        Assert.Equal(format == "JSON" ? "\"synthetic-owner\"" : "synthetic-owner", write["real_owner"]);
        Assert.DoesNotContain(write.Keys, key => key is "script" or "extra" or "schedule" or "owner");
        if (command is NasTaskCommand.Enable or NasTaskCommand.Disable) Assert.Equal(command == NasTaskCommand.Enable ? "true" : "false", write["enable"]);
        if (command is NasTaskCommand.Enable or NasTaskCommand.Run) Assert.Contains(f.Calls, call => call["method"] == "get" && call["version"] == "4");
        if (command == NasTaskCommand.Run)
        {
            Assert.Equal("task.run.accepted", result.DiagnosticTag); Assert.DoesNotContain(f.Calls, call => call["api"] == Fixture.EventApi);
        }
        var count = f.Calls.Count; await f.Recreate().ExecuteTaskCommandCoreAsync(request); Assert.Equal(count, f.Calls.Count);
    }

    [Fact]
    public async Task MissingRealOwnerDoesNotFallBackToExecutionOwner()
    {
        using var f = new Fixture(); f.Tasks["tasks"]![0]!.AsObject().Remove("real_owner");
        var request = await Request(f, NasTaskCommand.Disable); await f.Repository.ExecuteTaskCommandCoreAsync(request);
        Assert.DoesNotContain("real_owner", Assert.Single(f.Commands).Keys);
    }

    [Fact]
    public async Task NoConfirmationPermissionMissingPreviewAndUnknownScheduleMakeNoRequests()
    {
        using var f = new Fixture(); var request = await Request(f, NasTaskCommand.Enable);
        foreach (var invalid in new[] { request with { RiskConfirmed = false }, request with { RequestId = Guid.Empty }, request with { ProfileId = Guid.NewGuid() },
            request with { DetailBaseline = null }, request with { Baseline = request.Baseline with { EditAllowed = false } },
            request with { DetailBaseline = request.DetailBaseline! with { Schedule = request.DetailBaseline.Schedule! with { Hour = null } } } })
            Assert.False((await f.Repository.ExecuteTaskCommandCoreAsync(invalid)).Submitted);
        Assert.Empty(f.Calls);
    }

    [Theory]
    [InlineData("script")] [InlineData("owner")] [InlineData("hour")]
    public async Task ScriptOrExecutionConfigurationChangePreventsRun(string field)
    {
        using var f = new Fixture(); var request = await Request(f, NasTaskCommand.Run);
        if (field == "script") f.Detail["extra"]!["script"] = "changed-script";
        else if (field == "hour") f.Detail["schedule"]!["hour"] = 4;
        else f.Detail["owner"] = "different-owner";
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ExecuteTaskCommandCoreAsync(request)).ErrorCategory); Assert.Empty(f.Commands);
    }

    [Fact]
    public async Task StaleListUnknownAdministratorAndUnavailableVersionNeverWrite()
    {
        using var f = new Fixture(); var request = await Request(f, NasTaskCommand.Disable);
        f.Tasks["tasks"]![0]!["name"] = "changed-name";
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ExecuteTaskCommandCoreAsync(request)).ErrorCategory);
        f.Administrator = false; Assert.False((await f.Repository.ExecuteTaskCommandCoreAsync(request)).Submitted); Assert.Empty(f.Commands);
        f.Calls.Clear(); f.Capabilities[Fixture.TaskApi] = new(Fixture.TaskApi, "entry.cgi", 4, 9, "FORM");
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.ExecuteTaskCommandCoreAsync(request)).Status); Assert.Empty(f.Calls);
    }

    [Fact]
    public async Task LostRunNeverUsesLatestHistoryAsProofOrReplays()
    {
        using var f = new Fixture { LoseCommand = true }; var request = await Request(f, NasTaskCommand.Run);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteTaskCommandCoreAsync(request)).Status);
        var count = f.Calls.Count;
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Recreate().ReviewTaskCommandAsync(12))!.Status); Assert.Equal(count, f.Calls.Count);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ExecuteTaskCommandCoreAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        Assert.Single(f.Commands); Assert.DoesNotContain(f.Calls, call => call["api"] == Fixture.EventApi);
    }

    [Theory]
    [InlineData(NasTaskCommand.Enable)] [InlineData(NasTaskCommand.Disable)] [InlineData(NasTaskCommand.Delete)]
    public async Task AmbiguousConfigurationCommandsOnlyReadBack(NasTaskCommand command)
    {
        using var f = new Fixture { LoseCommand = true }; var request = await Request(f, command);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteTaskCommandCoreAsync(request)).Status); Assert.Single(f.Commands);
    }

    [Fact]
    public async Task UnknownDeleteDoesNotTreatAnotherOwnerOrMalformedListAsAbsence()
    {
        using var f = new Fixture { ApplyCommand = false }; var request = await Request(f, NasTaskCommand.Delete);
        f.AfterCommand = () => f.Tasks["tasks"]![0]!["real_owner"] = "other-owner";
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteTaskCommandCoreAsync(request)).Status);
        Assert.Single(await f.Recreate().GetTaskRecoveriesAsync()); Assert.Empty(await f.Recreate("other-account").GetTaskRecoveriesAsync());
        f.Tasks = new(); Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Recreate().ReviewTaskCommandAsync(12))!.Status);
        f.Tasks = new JsonObject { ["tasks"] = new JsonArray() };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewTaskCommandAsync(12))!.Status); Assert.Single(f.Commands);
    }

    [Fact]
    public async Task CancellationAndExplicitRejectionKeepDistinctResults()
    {
        using var f = new Fixture(); var request = await Request(f, NasTaskCommand.Disable);
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.ExecuteTaskCommandCoreAsync(request, cancelled.Token)).Status); Assert.Empty(f.Calls);
        using var after = new CancellationTokenSource(); f.AfterCommand = after.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await f.Repository.ExecuteTaskCommandCoreAsync(request, after.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewTaskCommandAsync(12))!.Status);
        using var rejection = new Fixture { CommandError = 105 }; var next = await Request(rejection, NasTaskCommand.Delete);
        Assert.Equal(MutationResultStatus.PermissionDenied, (await rejection.Repository.ExecuteTaskCommandCoreAsync(next)).Status);
        Assert.Empty(await rejection.Repository.GetTaskRecoveriesAsync());
    }

    [Fact]
    public async Task DifferentCommandsForSameTaskCannotOverlap()
    {
        using var f = new Fixture(); var request = await Request(f, NasTaskCommand.Disable);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.WaitCommand = async () => { entered.SetResult(); await finish.Task; }; var active = f.Repository.ExecuteTaskCommandCoreAsync(request); await entered.Task;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteTaskCommandCoreAsync(request with { Command = NasTaskCommand.Delete, RequestId = Guid.NewGuid() })).ErrorCategory);
        finish.SetResult(); await active; Assert.Single(f.Commands);
    }

    [Fact]
    public async Task PublicTaskCommandsRequireConfirmationAndDoNotReplay()
    {
        using var f = new Fixture(); var request = await Request(f, NasTaskCommand.Run); await f.Repository.PrepareServiceSettingsAsync(); f.Calls.Clear();
        var availability = f.Repository.TaskCommandAvailability;
        Assert.True(availability.CanRun); Assert.True(availability.CanDelete); Assert.True(availability.CanEnableDisable);
        Assert.False((await f.Repository.ExecuteTaskCommandAsync(request with { RiskConfirmed = false })).Submitted); Assert.Empty(f.Calls);
        Assert.True((await f.Repository.ExecuteTaskCommandAsync(request)).Submitted);
        await f.Repository.ExecuteTaskCommandAsync(request); Assert.Single(f.Calls, call => call["method"] == "run");
    }
}
