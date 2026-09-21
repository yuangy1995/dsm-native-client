using LanStash.Domain;
using LanStash.Infrastructure;
using Fixture = LanStash.Tests.NasAdmin.NasDiskTestReadTests.Fixture;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDiskTestCommandTests
{
    private static Task NoDelay(TimeSpan _, CancellationToken token) { token.ThrowIfCancellationRequested(); return Task.CompletedTask; }
    private static NasDiskTestRequest Request(Fixture f, NasDiskTestCommand command = NasDiskTestCommand.Quick) =>
        new(f.Profile.Id, new(new("disk-a", "device-a", "Synthetic disk", true), command == NasDiskTestCommand.Stop,
            command == NasDiskTestCommand.Stop ? NasDiskTestType.Extended : null, false, null, null), command, Guid.NewGuid(), true);
    private static Task<MutationResult> Run(Fixture f, NasDiskTestRequest request, CancellationToken token = default) =>
        f.Repository.ExecuteDiskTestCoreAsync(request, token, NoDelay);
    private static void Running(Fixture f)
    { f.State["testInfo"]![0]!["testing"] = true; f.State["testInfo"]![0]!["test_type"] = "extend"; }

    [Theory]
    [InlineData("FORM", NasDiskTestCommand.Quick, "quick")]
    [InlineData("JSON", NasDiskTestCommand.Quick, "quick")]
    [InlineData("FORM", NasDiskTestCommand.Extended, "extend")]
    [InlineData("JSON", NasDiskTestCommand.Extended, "extend")]
    [InlineData("FORM", NasDiskTestCommand.Stop, "stop")]
    [InlineData("JSON", NasDiskTestCommand.Stop, "stop")]
    public async Task FixedCommandsVerifyExactStateAndCannotRepeat(string format, NasDiskTestCommand command, string type)
    {
        using var f = new Fixture(format); if (command == NasDiskTestCommand.Stop) Running(f);
        var request = Request(f, command); var result = await Run(f, request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal(command == NasDiskTestCommand.Stop ? "disk.test.stopped" : "disk.test.running", result.DiagnosticTag);
        var call = Assert.Single(f.Calls, item => item["method"] == "do_smart_test");
        Assert.Equal("1", call["version"]); Assert.Equal(Fixture.DiskApi, call["api"]);
        Assert.Equal(format == "JSON" ? System.Text.Json.JsonSerializer.Serialize(type) : type, call["type"]);
        Assert.Equal(format == "JSON" ? "\"device-a\"" : "device-a", call["device"]);
        Assert.DoesNotContain("disk_id", call.Keys); Assert.Equal(1, f.StatusReadsAfterWrite);
        Assert.Same(result, await Run(f, request)); Assert.Equal(1, f.Writes); Assert.Empty(await f.Repository.GetDiskTestRecoveriesAsync());
    }
    [Fact]
    public async Task PublicDiskTestStillRejectsInvalidConfirmationAndTargets()
    {
        using var f = new Fixture(); var request = Request(f);
        await f.Repository.PrepareServiceSettingsAsync();
        Assert.True(((INasSettingsRepository)f.Repository).WriteAvailability.CanDiskTest);
        Assert.False((await f.Repository.ExecuteDiskTestAsync(request with { RiskConfirmed = false })).Submitted);
        Assert.False((await Run(f, request with { RiskConfirmed = false })).Submitted);
        Assert.False((await Run(f, request with { ProfileId = Guid.NewGuid() })).Submitted);
        Assert.False((await Run(f, request with { Baseline = request.Baseline with { IsBusyWithOtherTest = null } })).Submitted);
        Assert.Equal(0, f.Writes);
    }
    [Fact]
    public async Task PermissionStateChangeAndReplacementPreventWrites()
    {
        using var f = new Fixture(); var request = Request(f); f.Administrator = false;
        Assert.Equal(MutationErrorCategory.Permission, (await Run(f, request)).ErrorCategory);
        f.Administrator = true; Running(f); Assert.Equal(MutationErrorCategory.Conflict, (await Run(f, request)).ErrorCategory);
        f.Disks["disks"]![0]!["device"] = "replacement";
        Assert.False((await Run(f, request)).Submitted); Assert.Equal(0, f.Writes);
    }
    [Fact]
    public async Task ReplyLossRecoversWithoutReplaying()
    {
        using var f = new Fixture { LoseReply = true }; var request = Request(f);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await Run(f, request)).Status); Assert.Equal(1, f.Writes);
    }
    [Fact]
    public async Task AcceptedButUnchangedStateStaysUnknownAcrossRepositoryAndIds()
    {
        using var f = new Fixture { ApplyCommand = false }; var request = Request(f);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await Run(f, request)).Status);
        Assert.Equal(6, f.StatusReadsAfterWrite);
        Assert.Single(await f.Recreate().GetDiskTestRecoveriesAsync());
        Assert.Equal(MutationErrorCategory.Conflict, (await f.Recreate().ExecuteDiskTestCoreAsync(request with { RequestId = Guid.NewGuid() }, delay: NoDelay)).ErrorCategory);
        var alias = request with { RequestId = Guid.NewGuid(), Baseline = request.Baseline with { Target = request.Baseline.Target with { Id = "alias" } } };
        Assert.Equal(MutationErrorCategory.Conflict, (await Run(f, alias)).ErrorCategory);
        Assert.Empty(await f.Recreate("other-account").GetDiskTestRecoveriesAsync());
        f.State["testInfo"]![0]!["testing"] = true; f.State["testInfo"]![0]!["test_type"] = "quick";
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Recreate().ReviewDiskTestAsync("disk-a"))!.Status);
        Assert.Equal(1, f.Writes);
    }
    [Fact]
    public async Task ExplicitRefusalDoesNotBecomeSuccessFromAnUnrelatedState()
    {
        using var f = new Fixture { RejectionCode = 105 }; var result = await Run(f, Request(f));
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Status); Assert.Equal(0, f.StatusReadsAfterWrite);
        Assert.Empty(await f.Repository.GetDiskTestRecoveriesAsync());
    }
    [Theory]
    [InlineData(true)] [InlineData(false)]
    public async Task CancellationAfterSubmissionReadsOnceAndNeverResends(bool applies)
    {
        using var f = new Fixture { ApplyCommand = applies }; using var cts = new CancellationTokenSource(); f.AfterCommand = cts.Cancel;
        var result = await Run(f, Request(f), cts.Token);
        Assert.Equal(applies ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.CancellationRequestedAfterSubmission, result.Status);
        Assert.Equal(1, f.StatusReadsAfterWrite); Assert.Equal(1, f.Writes);
    }
    [Fact]
    public async Task PreCancelledRequestAndConcurrentStopSendNoAdditionalCommand()
    {
        using var f = new Fixture(); using var cts = new CancellationTokenSource(); cts.Cancel();
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await Run(f, Request(f), cts.Token)).Status); Assert.Empty(f.Calls);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); f.WaitCommand = () => release.Task;
        var active = Run(f, Request(f)); Assert.Equal(1, f.Writes);
        Assert.Equal(MutationErrorCategory.Conflict, (await Run(f, Request(f, NasDiskTestCommand.Stop))).ErrorCategory);
        release.SetResult(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await active).Status); Assert.Equal(1, f.Writes);
    }
    [Fact]
    public async Task TransientReadUsesBoundedRetryButPermissionStopsImmediately()
    {
        using var f = new Fixture(); f.ReadFailures.Enqueue(new HttpRequestException("合成暂时断线"));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await Run(f, Request(f))).Status); Assert.Equal(2, f.StatusReadsAfterWrite);
        using var denied = new Fixture { ReadErrorCode = 105 };
        var result = await Run(denied, Request(denied));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status); Assert.Equal(MutationErrorCategory.Permission, result.ErrorCategory);
        Assert.Equal(1, denied.StatusReadsAfterWrite); Assert.Single(await denied.Repository.GetDiskTestRecoveriesAsync());
    }
    [Fact]
    public async Task WrongRunningTypeAndMalformedReadCannotConfirmStart()
    {
        using var f = new Fixture(); f.AfterCommand = () => f.State["testInfo"]![0]!["test_type"] = "extend";
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await Run(f, Request(f))).Status); Assert.Equal(6, f.StatusReadsAfterWrite);
        using var malformed = new Fixture(); malformed.AfterCommand = () => malformed.State.Clear();
        Assert.Equal(MutationErrorCategory.Validation, (await Run(malformed, Request(malformed))).ErrorCategory);
        Assert.Equal(1, malformed.StatusReadsAfterWrite);
    }

    [Fact]
    public async Task TimeoutsExhaustOnlySixReadsAndKeepPendingRecovery()
    {
        using var f = new Fixture();
        for (var index = 0; index < 6; index++) f.ReadFailures.Enqueue(new OperationCanceledException("合成网络超时"));
        var result = await Run(f, Request(f));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(MutationErrorCategory.Network, result.ErrorCategory); Assert.Equal(6, f.StatusReadsAfterWrite);
        Assert.Single(await f.Repository.GetDiskTestRecoveriesAsync()); Assert.Equal(1, f.Writes);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await f.Repository.ReviewDiskTestAsync("disk-a"))!.Status);
        Assert.Equal(1, f.Writes);
    }

    [Fact]
    public async Task ReplacementAfterSubmissionCannotVerifyTheOldDisk()
    {
        using var f = new Fixture(); f.AfterCommand = () => f.Disks["disks"]![0]!["device"] = "replacement";
        var request = Request(f); var result = await Run(f, request);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(0, f.StatusReadsAfterWrite); Assert.Single(await f.Repository.GetDiskTestRecoveriesAsync());
        await f.Recreate().ReviewDiskTestAsync("disk-a"); Assert.Equal(0, f.StatusReadsAfterWrite); Assert.Equal(1, f.Writes);
    }
}
