using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using Fixture = LanStash.Tests.NasAdmin.NasTaskReadTests.Fixture;

namespace LanStash.Tests.NasAdmin;

public sealed class NasTaskSaveTests
{
    private static async Task<NasTaskSaveRequest> Request(Fixture f, bool create = false)
    {
        NasTaskEntry? task = null;
        if (create) { f.Tasks["tasks"]!.AsArray().Clear(); f.Detail["id"] = -1; f.Detail["name"] = ""; f.Detail["extra"]!["script"] = ""; }
        else task = Assert.Single(await f.Repository.LoadScheduledTasksAsync());
        var baseline = await f.Repository.LoadScheduledTaskDetailAsync(task?.Id, "synthetic-owner");
        f.Calls.Clear();
        return new(f.Profile.Id, task, baseline, baseline with { Name = "changed-task", Script = " synthetic-secret-script\n", Schedule = baseline.Schedule! with { Hour = 7, Minute = 5, WeekDays = "1,3,5" } }, Guid.NewGuid(), true);
    }

    [Theory]
    [InlineData("FORM", false)] [InlineData("JSON", false)] [InlineData("FORM", true)] [InlineData("JSON", true)]
    public async Task CreatesOrEditsV4AndVerifiesFullConfiguration(string format, bool create)
    {
        using var f = new Fixture(format); var request = await Request(f, create);
        var result = await f.Repository.ExecuteTaskSaveCoreAsync(request); Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        var save = Assert.Single(f.Saves); Assert.Equal(create ? "create" : "set", save["method"]); Assert.Equal("4", save["version"]);
        Assert.Equal(create, !save.ContainsKey("id"));
        var schedule = JsonNode.Parse(save["schedule"])!; Assert.Equal(7, schedule["hour"]!.GetValue<int>()); Assert.Equal("1,3,5", schedule["week_day"]!.ToString());
        Assert.Equal(new[] { 1, 5, 10, 15, 20, 30 }, schedule["repeat_min_store_config"]!.AsArray().Select(item => item!.GetValue<int>()));
        Assert.Equal(Enumerable.Range(1, 23), schedule["repeat_hour_store_config"]!.AsArray().Select(item => item!.GetValue<int>()));
        var extra = JsonNode.Parse(save["extra"])!; Assert.Equal(" synthetic-secret-script\n", extra["script"]!.ToString()); Assert.True(extra["notify_enable"]!.GetValue<bool>());
        Assert.Equal(nameof(NasTaskSaveRequest), request.ToString()); Assert.DoesNotContain("synthetic-secret-script", JsonSerializer.Serialize(request));
        var count = f.Calls.Count; await f.Recreate().ExecuteTaskSaveCoreAsync(request); Assert.Equal(count, f.Calls.Count);
        Assert.Empty(await f.Repository.GetTaskSaveRecoveriesAsync());
    }

    [Fact]
    public async Task UnknownOptionalPlanValuesAreNotInventedOrOverwritten()
    {
        using var f = new Fixture(); f.Detail["schedule"]!.AsObject().Remove("monthly_week"); var request = await Request(f);
        Assert.Null(request.BaselineDetail.Schedule!.MonthlyWeek);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteTaskSaveCoreAsync(request)).Status);
        Assert.DoesNotContain("monthly_week", JsonNode.Parse(Assert.Single(f.Saves)["schedule"])!.AsObject().Select(pair => pair.Key));
    }

    [Fact]
    public async Task InvalidUnconfirmedUnknownAndOpaquePlanChangesDoNotSend()
    {
        using var f = new Fixture(); var request = await Request(f);
        foreach (var invalid in new[] { request with { RiskConfirmed = false }, request with { RequestId = Guid.Empty },
            request with { Desired = request.Desired with { Script = "" } }, request with { Desired = request.Desired with { Owner = "" } },
            request with { Desired = request.Desired with { Schedule = request.Desired.Schedule! with { Hour = 24 } } },
            request with { Desired = request.Desired with { Schedule = request.Desired.Schedule! with { WeekDays = "1,1" } } },
            request with { Desired = request.Desired with { Schedule = request.Desired.Schedule! with { DateType = 99 } } },
            request with { BaselineDetail = request.BaselineDetail with { Schedule = request.BaselineDetail.Schedule! with { Hour = null } } },
            request with { BaselineDetail = request.BaselineDetail with { RequestedRealOwner = "other" }, Desired = request.Desired with { RequestedRealOwner = "other" } } })
            Assert.False((await f.Repository.ExecuteTaskSaveCoreAsync(invalid)).Submitted);
        Assert.Empty(f.Calls);
    }

    [Theory]
    [InlineData("script")] [InlineData("owner")] [InlineData("schedule")]
    public async Task ChangedDetailBaselinePreventsSaving(string field)
    {
        using var f = new Fixture(); var request = await Request(f);
        if (field == "script") f.Detail["extra"]!["script"] = "externally-changed";
        else if (field == "owner") f.Detail["owner"] = "other-owner";
        else f.Detail["schedule"]!["minute"] = 9;
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Repository.ExecuteTaskSaveCoreAsync(request)).ErrorCategory); Assert.Empty(f.Saves);
    }

    [Theory]
    [InlineData("script")] [InlineData("mail")] [InlineData("schedule")] [InlineData("owner")]
    public async Task ExistingIdAndNameCannotHideReadbackMismatch(string field)
    {
        using var f = new Fixture(); var request = await Request(f);
        f.AfterCommand = () =>
        {
            if (field == "script") f.Detail["extra"]!["script"] = "not-saved";
            else if (field == "mail") f.Detail["extra"]!["notify_mail"] = "different@example.invalid";
            else if (field == "owner") f.Detail["owner"] = "different-owner";
            else f.Detail["schedule"]!["hour"] = 6;
        };
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteTaskSaveCoreAsync(request)).Status); Assert.Single(f.Saves);
    }

    [Fact]
    public async Task LostAcknowledgementUsesFullReadbackAndDoesNotReplay()
    {
        using var f = new Fixture { LoseCommand = true }; var request = await Request(f, true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ExecuteTaskSaveCoreAsync(request)).Status); Assert.Single(f.Saves);
        Assert.DoesNotContain(f.Calls, call => call["method"] == "run");
    }

    [Fact]
    public async Task UnknownSaveBlocksCommandsAndResubmissionButCanBeReviewed()
    {
        using var f = new Fixture { ApplyCommand = false, LoseCommand = true }; var request = await Request(f);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await f.Repository.ExecuteTaskSaveCoreAsync(request)).Status);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteTaskSaveCoreAsync(request with { RequestId = Guid.NewGuid() })).ErrorCategory);
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteTaskCommandCoreAsync(new(f.Profile.Id, request.BaselineTask!, NasTaskCommand.Delete, null, Guid.NewGuid(), true))).ErrorCategory);
        var pending = Assert.Single(await f.Recreate().GetTaskSaveRecoveriesAsync()); Assert.Equal(request.RequestId, pending.RequestId);
        Assert.Empty(await f.Recreate("other").GetTaskSaveRecoveriesAsync());
        f.Detail["name"] = request.Desired.Name; f.Detail["extra"]!["script"] = request.Desired.Script;
        f.Detail["schedule"]!["hour"] = 7; f.Detail["schedule"]!["minute"] = 5; f.Detail["schedule"]!["week_day"] = "1,3,5";
        f.Tasks["tasks"]![0]!["name"] = request.Desired.Name;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewTaskSaveAsync(request.RequestId))!.Status); Assert.Single(f.Saves);
    }

    [Fact]
    public async Task MonthlyArrayIsCopiedBeforeAwaitingPreflight()
    {
        using var f = new Fixture(); var request = await Request(f); var months = new[] { 1, 3 };
        request = request with { BaselineDetail = request.BaselineDetail with { Schedule = request.BaselineDetail.Schedule! with { MonthlyWeek = months } },
            Desired = request.Desired with { Schedule = request.Desired.Schedule! with { MonthlyWeek = months } } };
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        f.WaitAdmin = async () => { entered.SetResult(); await release.Task; };
        var saving = f.Repository.ExecuteTaskSaveCoreAsync(request); await entered.Task; months[0] = 9; release.SetResult();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await saving).Status);
        Assert.Equal(1, JsonNode.Parse(Assert.Single(f.Saves)["schedule"])!["monthly_week"]![0]!.GetValue<int>());
    }

    [Fact]
    public async Task RejectionCancellationAndClosedProductionGateAreDistinct()
    {
        using var f = new Fixture(); var request = await Request(f);
        Assert.Equal(MutationResultStatus.Unsupported, (await f.Repository.SaveScheduledTaskAsync(request)).Status); Assert.Empty(f.Calls);
        using var before = new CancellationTokenSource(); before.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await f.Repository.ExecuteTaskSaveCoreAsync(request, before.Token)).Status);
        using var after = new CancellationTokenSource(); f.AfterCommand = after.Cancel;
        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, (await f.Repository.ExecuteTaskSaveCoreAsync(request, after.Token)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewTaskSaveAsync(request.RequestId))!.Status);
        using var rejected = new Fixture { CommandError = 105 }; var attempt = await Request(rejected);
        Assert.Equal(MutationResultStatus.PermissionDenied, (await rejected.Repository.ExecuteTaskSaveCoreAsync(attempt)).Status); Assert.Empty(await rejected.Repository.GetTaskSaveRecoveriesAsync());
    }
}
