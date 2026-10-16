using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosBackgroundTasksTests
{
    [Theory]
    [InlineData(false, 0)][InlineData(false, 19)][InlineData(true, 99)]
    public async Task ListingNeedsOnlyPhotosIdentityAndKeepsFractionalCreationTime(bool home, long owner)
    {
        using var f = new Fixture(); f.Http.HomeEnabled = home; f.Rows[0]["target_folder"]!["owner_user_id"] = owner;
        var repo = await f.Repository(); f.Http.Requests.Clear(); var task = Assert.Single(await repo.BackgroundTasksAsync());
        Assert.Equal(1788220800.123456, task.CreatedAt); Assert.Equal(2, task.SuccessfulCount); Assert.True(task.CanStop);
        Assert.Equal(owner == 0 ? SynologyPhotoSpace.Shared : owner == 19 ? SynologyPhotoSpace.Personal : (SynologyPhotoSpace?)null, task.TargetSpace);
        Assert.Collection(f.Http.Requests, request => Assert.Equal("SYNO.Foto.UserInfo", request.Api), request =>
        { Assert.Equal("SYNO.Foto.BackgroundTask.Info", request.Api); Assert.Equal("list_user_task", request.Method); Assert.Equal(1, request.Version);
            Assert.Empty(request.Values.Keys.Except(["api", "version", "method", "_sid", "SynoToken"])); });
    }
    [Theory]
    [InlineData("id")][InlineData("operation")][InlineData("status")][InlineData("total")][InlineData("completion")][InlineData("error")][InlineData("skip")][InlineData("overwrite")][InlineData("create_time")]
    public async Task MissingRequiredFieldsNeverBecomeAnEmptyList(string field)
    {
        using var f = new Fixture(); f.Rows[0].Remove(field); var repo = await f.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.BackgroundTasksAsync()); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("id", -1)][InlineData("total", -1)][InlineData("completion", -1)][InlineData("completion", 11)][InlineData("error", -1)][InlineData("error", 4)]
    [InlineData("skip", -1)][InlineData("skip", 11)][InlineData("overwrite", -1)][InlineData("overwrite", 11)][InlineData("create_time", -1)]
    public async Task InvalidCountsAndTimeAreRejected(string field, long value)
    {
        using var f = new Fixture(); f.Rows[0][field] = value; var repo = await f.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.BackgroundTasksAsync());
    }
    [Fact]
    public async Task DuplicateTasksAndWrongFieldTypesAreRejected()
    {
        using var f = new Fixture(); var repo = await f.Repository(); f.Rows.Add((JsonObject)f.Rows[0].DeepClone());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.BackgroundTasksAsync()); f.Rows.RemoveAt(1); f.Rows[0]["completion"] = "3";
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.BackgroundTasksAsync());
    }
    [Theory]
    [InlineData("other", "processing")][InlineData("copy", "future")][InlineData("move", "aborting")]
    public async Task UnknownOrAlreadyStoppingTasksHaveNoControl(string operation, string status)
    {
        using var f = new Fixture(); f.Rows[0]["operation"] = operation; f.Rows[0]["status"] = status;
        var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync()); Assert.False(task.CanStop); Assert.False(task.CanClear);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [task]), true)); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("profile")][InlineData("user")][InlineData("enabled")][InlineData("time")][InlineData("operation")][InlineData("total")]
    [InlineData("target")][InlineData("owner")][InlineData("status")][InlineData("gone")][InlineData("confirmation")]
    public async Task OriginalIdentityAndConfirmationAreRequiredBeforeWriting(string changed)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync());
        if (changed == "profile") task = task with { ProfileId = Guid.NewGuid() }; if (changed == "user") f.Http.UserId++;
        if (changed == "enabled") f.Http.Enabled = false; if (changed == "time") f.Rows[0]["create_time"] = task.CreatedAt + 0.0001;
        if (changed == "operation") f.Rows[0]["operation"] = "move"; if (changed == "total") f.Rows[0]["total"] = 11;
        if (changed == "target") f.Rows[0]["target_folder"]!["id"] = 10; if (changed == "owner") f.Rows[0]["target_folder"]!["owner_user_id"] = 0;
        if (changed == "status") f.Rows[0]["status"] = "done"; if (changed == "gone") f.Rows.Clear();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [task]), changed != "confirmation")); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task ProgressMayAdvanceAfterConfirmationAndStopUsesOneArrayId()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync()); f.Rows[0]["completion"] = 4;
        var result = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [task]), true);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(1, result.CompletedSteps);
        var write = Assert.Single(f.Writes); Assert.Equal("SYNO.Foto.BackgroundTask.Info", write.Api); Assert.Equal(1, write.Version); Assert.Equal("abort_task", write.Method); Assert.Equal("[91]", write.Values["id"]);
        Assert.True(Assert.Single(await repo.BackgroundTasksAsync()).WasStopped); Assert.Single(await repo.BackgroundChangesAsync()); Assert.Empty(await repo.SettingsChangesAsync());
        await repo.ControlBackgroundTasksAsync(result.Id, new(SynologyPhotoBackgroundAction.Stop, [task]), true); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData(false, false)][InlineData(false, true)][InlineData(true, false)][InlineData(true, true)]
    public async Task StopWaitsForDoneOrAbsenceAndColdRecoveryNeverReplays(bool drop, bool disappear)
    {
        using var f = new Fixture { Apply = false, StopAt = drop ? 1 : 0 }; var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync());
        var result = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [task]), true); Assert.True(result.Pending);
        f.Rows[0]["status"] = "aborting"; var cold = await f.Repository(f.Store.Clone()); Assert.True((await cold.ReviewSettingsChangeAsync(result.Id)).Pending);
        if (disappear) f.Rows.Clear(); else f.Rows[0]["status"] = "done";
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ReviewSettingsChangeAsync(result.Id)).State); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData(100)][InlineData(105)][InlineData(119)]
    public async Task ExplicitStopRejectionNeverBecomesSuccessFromAnotherClientsChange(int code)
    {
        using var f = new Fixture { StopAt = 1, Reject = true, Code = code }; var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync());
        var result = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [task]), true); Assert.Equal(SynologyPhotoChangeState.Failed, result.State);
        f.Rows.Clear(); var cold = await f.Repository(f.Store.Clone()); Assert.Equal(SynologyPhotoChangeState.Failed, (await cold.ReviewSettingsChangeAsync(result.Id)).State); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task ClearUsesFixedScalarTargetsAndLeavesNewlyFinishedTask()
    {
        using var f = new Fixture(); f.Rows = [Row(91, "done"), Row(92, "done")]; var repo = await f.Repository(); var original = await repo.BackgroundTasksAsync();
        f.AfterWrite = count => { if (count == 1) f.Rows.Add(Row(93, "done")); };
        var result = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Clear, original), true);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.Equal(2, result.CompletedSteps); Assert.Equal(93, Assert.Single(await repo.BackgroundTasksAsync()).Id);
        Assert.Equal(new[] { "91", "92" }, f.Writes.Select(value => value.Values["id"]));
        Assert.All(f.Writes, write => { Assert.Equal("clear_completed_task", write.Method); Assert.Equal("SYNO.Foto.BackgroundTask.Info", write.Api); });
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task PartialClearOnlyReviewsAttemptedNonRejectedTargets(bool reject)
    {
        using var f = new Fixture { StopAt = 2, Reject = reject }; f.Rows = [Row(91, "done"), Row(92, "done"), Row(93, "done")];
        var repo = await f.Repository(); var original = await repo.BackgroundTasksAsync(); var result = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Clear, original), true);
        Assert.Equal(2, f.Writes.Count); Assert.Equal(1, result.CompletedSteps); Assert.Equal(reject ? SynologyPhotoChangeState.Failed : SynologyPhotoChangeState.PendingReview, result.State);
        f.Rows.Clear(); var cold = await f.Repository(f.Store.Clone()); result = await cold.ReviewSettingsChangeAsync(result.Id);
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(reject ? 1 : 2, result.CompletedSteps); Assert.Equal(3, result.TotalSteps);
        await cold.ControlBackgroundTasksAsync(result.Id, new(SynologyPhotoBackgroundAction.Clear, original), true); Assert.Equal(2, f.Writes.Count);
    }
    [Fact]
    public async Task FreshExplicitSelectionCanFinishRemainingRecordsAfterPartialRejection()
    {
        using var f = new Fixture { StopAt = 2, Reject = true }; f.Rows = [Row(91, "done"), Row(92, "done")]; var repo = await f.Repository();
        var first = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Clear, await repo.BackgroundTasksAsync()), true); Assert.True(first.PartiallySaved);
        f.StopAt = 0; var second = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Clear, await repo.BackgroundTasksAsync()), true);
        Assert.Equal(SynologyPhotoChangeState.Completed, second.State); Assert.Equal(new[] { "91", "92", "92" }, f.Writes.Select(value => value.Values["id"]));
    }
    [Fact]
    public async Task PendingControlCannotAdoptReusedIdAndBlocksAnotherOperationOnThatId()
    {
        using var f = new Fixture { StopAt = 1, Apply = false }; var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync());
        var command = new SynologyPhotoBackgroundCommand(SynologyPhotoBackgroundAction.Stop, [task]); var result = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), command, true);
        f.Rows[0]["create_time"] = task.CreatedAt + 1; f.Rows[0]["status"] = "done";
        Assert.True((await repo.ReviewSettingsChangeAsync(result.Id)).Pending);
        var reused = await repo.BackgroundTasksAsync();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Clear, reused), true));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ControlBackgroundTasksAsync(result.Id, new(SynologyPhotoBackgroundAction.Stop, [task with { CreatedAt = task.CreatedAt + 1 }]), true)); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task ControlsAndUnrelatedSettingsDoNotBlockEachOther()
    {
        using var f = new Fixture { StopAt = 1, Apply = false }; var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync());
        var first = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [task]), true); Assert.True(first.Pending);
        f.Apply = true; Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true)).State);
        f.Rows.Add(Row(92)); var second = (await repo.BackgroundTasksAsync()).Single(value => value.Id == 92);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [second]), true)).State);
        Assert.Equal(2, (await repo.BackgroundChangesAsync()).Count); Assert.Single(await repo.SettingsChangesAsync()); Assert.Equal(3, f.Writes.Count);
    }
    [Fact]
    public async Task PendingSettingsStillAllowStoppingAnIndependentTask()
    {
        using var f = new Fixture { StopAt = 1, Apply = false }; var repo = await f.Repository(); Assert.True((await repo.SetAutomaticPreviewAsync(Guid.NewGuid(), false, true)).Pending);
        f.Apply = true; var task = Assert.Single(await repo.BackgroundTasksAsync());
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [task]), true)).State);
    }
    [Fact]
    public async Task ConcurrentClicksOnlySendOnceAndLateAccountResultCannotComplete()
    {
        using var f = new Fixture { Hold = new(TaskCreationOptions.RunContinuationsAsynchronously) }; var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync());
        var id = Guid.NewGuid(); var command = new SynologyPhotoBackgroundCommand(SynologyPhotoBackgroundAction.Stop, [task]);
        var first = repo.ControlBackgroundTasksAsync(id, command, true); await f.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True((await repo.ControlBackgroundTasksAsync(id, command, true)).Pending);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ControlBackgroundTasksAsync(Guid.NewGuid(), command, true));
        f.Http.UserId++; await repo.AccessAsync(); f.Hold.TrySetResult(); Assert.True((await first).Pending); Assert.Empty(await repo.BackgroundChangesAsync()); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task PreWriteCheckpointAndLiveCancellationAreNotSilentlyRetriedAfterRestart()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var original = Assert.Single(await repo.BackgroundTasksAsync()); using var cancel = new CancellationTokenSource(); MemoryStore? saved = null;
        f.Store.AfterSave = raw => { if (raw["Settings"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) { saved = f.Store.Clone(); cancel.Cancel(); } return Task.CompletedTask; };
        var result = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [original]), true, cancel.Token);
        Assert.Equal(SynologyPhotoChangeState.Cancelled, result.State); Assert.Empty(f.Writes); Assert.NotNull(saved);
        var cold = await f.Repository(saved); Assert.True((await cold.ReviewSettingsChangeAsync(result.Id)).Pending); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task ChangedIdentityAfterCheckpointProducesZeroWrites()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var original = Assert.Single(await repo.BackgroundTasksAsync());
        f.Store.AfterSave = raw => { if (raw["Settings"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) f.Rows[0]["create_time"] = 4; return Task.CompletedTask; };
        var result = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [original]), true);
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task FailedCheckpointPreventsNetworkSubmission()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var original = Assert.Single(await repo.BackgroundTasksAsync());
        f.Store.FailSave = raw => raw["Settings"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [original]), true)); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task ColdRecordsKeepMinimalIdentityWithoutNamesPathsCredentialsOrRequests()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var original = Assert.Single(await repo.BackgroundTasksAsync());
        var result = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [original]), true);
        var text = Encoding.UTF8.GetString(Assert.Single(f.Store.Records).Value);
        foreach (var forbidden in new[] { "synthetic-sid", "synthetic-token", "nas.invalid", "/Destination", "synthetic.jpg", "abort_task", "get_status" }) Assert.DoesNotContain(forbidden, text);
        var cold = await f.Repository(f.Store.Clone()); Assert.Equal(SynologyPhotoChangeState.Completed, Assert.Single(await cold.BackgroundChangesAsync()).State);
        var damaged = f.Store.Clone(); var json = JsonNode.Parse(damaged.Records[result.Id])!; json["Settings"]!["Background"]!["Completed"] = new JsonArray(999L); damaged.Records[result.Id] = Encoding.UTF8.GetBytes(json.ToJsonString());
        var invalid = await f.Repository(damaged); await Assert.ThrowsAsync<SynologyPhotoException>(() => invalid.BackgroundChangesAsync());
    }
    [Theory]
    [InlineData(0, "SYNO.FotoTeam.Browse.Item")][InlineData(19, "SYNO.Foto.Browse.Item")]
    public async Task ErrorNamesUseTargetSourceAndMatchIdsInBatches(long owner, string api)
    {
        using var f = new Fixture(); f.Rows[0]["target_folder"]!["owner_user_id"] = owner;
        f.Errors = Enumerable.Range(1, 101).Select(id => Error(id)).ToList(); var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync());
        var result = await repo.BackgroundTaskErrorsAsync(task); Assert.Equal(101, result.Count);
        Assert.All(result, entry => { Assert.Equal("synthetic-" + entry.ItemId, entry.Name); Assert.Equal("/Destination", entry.FolderPath); });
        var reads = f.Http.Requests.Where(request => request.Api.EndsWith(".Browse.Item", StringComparison.Ordinal)).ToArray(); Assert.Equal(2, reads.Length);
        Assert.All(reads, request => { Assert.Equal(api, request.Api); Assert.Equal(5, request.Version); Assert.Equal("[\"folder\"]", request.Values["additional"]); });
        Assert.Equal(new[] { 100, 1 }, reads.Select(request => JsonNode.Parse(request.Values["id"])!.AsArray().Count));
        Assert.Equal("91", Assert.Single(f.Http.Requests, request => request.Method == "get_error_detail").Values["id"]);
    }
    [Theory]
    [InlineData("quota_full", SynologyPhotoBackgroundErrorReason.Quota)][InlineData("space_full", SynologyPhotoBackgroundErrorReason.Space)]
    [InlineData("skipped", SynologyPhotoBackgroundErrorReason.Subfolder)][InlineData("not_existed", SynologyPhotoBackgroundErrorReason.Missing)]
    [InlineData("target_not_existed", SynologyPhotoBackgroundErrorReason.TargetMissing)][InlineData("excluded_extension", SynologyPhotoBackgroundErrorReason.Excluded)]
    [InlineData("unrecognized", SynologyPhotoBackgroundErrorReason.Unknown)]
    public async Task KnownAndUnknownReasonsRemainVisibleWhenNamesCannotBeRead(string reason, SynologyPhotoBackgroundErrorReason expected)
    {
        using var f = new Fixture { FailNames = true }; f.Errors = [Error(7, reason)]; var repo = await f.Repository();
        var result = Assert.Single(await repo.BackgroundTaskErrorsAsync(Assert.Single(await repo.BackgroundTasksAsync()))); Assert.Equal(expected, result.Reason); Assert.Null(result.Name);
    }
    [Theory]
    [InlineData("unknown-owner")][InlineData("home-disabled")][InlineData("shared-denied")]
    public async Task ErrorNamesNeverProbeAnotherSourceAfterPermissionLoss(string cause)
    {
        using var f = new Fixture(); var repo = await f.Repository();
        if (cause == "unknown-owner") f.Rows[0]["target_folder"]!["owner_user_id"] = 25;
        if (cause == "home-disabled") f.Http.HomeEnabled = false;
        if (cause == "shared-denied") { f.Rows[0]["target_folder"]!["owner_user_id"] = 0; f.Http.TeamPermission = "none"; }
        var result = await repo.BackgroundTaskErrorsAsync(Assert.Single(await repo.BackgroundTasksAsync())); Assert.Null(Assert.Single(result).Name);
        Assert.DoesNotContain(f.Http.Requests, request => request.Api.EndsWith(".Browse.Item", StringComparison.Ordinal));
    }
    [Fact]
    public async Task InvalidOrDuplicateEnrichmentDoesNotAttachWrongNames()
    {
        using var f = new Fixture { WrongNames = true }; var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync());
        Assert.Null(Assert.Single(await repo.BackgroundTaskErrorsAsync(task)).Name); f.WrongNames = false; f.Errors.Add(Error(7));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.BackgroundTaskErrorsAsync(task)); f.Errors = [Error(7, type: "unknown")];
        Assert.Equal(SynologyPhotoBackgroundErrorKind.Unknown, Assert.Single(await repo.BackgroundTaskErrorsAsync(task)).Kind);
    }
    [Fact]
    public async Task FolderErrorUsesFolderPermissionAndUnknownTypeNeverGuessesRoute()
    {
        using var f = new Fixture(); f.Errors = [Error(9, type: "folder"), Error(9, type: "future")]; var repo = await f.Repository();
        var result = await repo.BackgroundTaskErrorsAsync(Assert.Single(await repo.BackgroundTasksAsync()));
        Assert.Equal("Destination", result[0].Name); Assert.Equal("/", result[0].FolderPath); Assert.Null(result[1].Name);
        Assert.Single(f.Http.Requests, request => request.Api.EndsWith(".Browse.Folder", StringComparison.Ordinal));
    }
    [Fact]
    public async Task NoErrorDetailsRequestWhenCurrentErrorCountIsZero()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync()); f.Rows[0]["error"] = 0;
        Assert.Empty(await repo.BackgroundTaskErrorsAsync(task)); Assert.DoesNotContain(f.Http.Requests, request => request.Method == "get_error_detail");
    }
    [Theory]
    [InlineData(0)][InlineData(19)]
    public async Task DestinationNavigationChecksEveryParentInTheOriginalSource(long owner)
    {
        using var f = new Fixture(); f.Rows[0]["target_folder"]!["owner_user_id"] = owner; var repo = await f.Repository();
        var chain = await repo.BackgroundTaskLocationAsync(Assert.Single(await repo.BackgroundTasksAsync())); Assert.Equal(new long[] { 1, 9 }, chain.Select(value => value.Id));
        Assert.All(chain, value => Assert.Equal(owner == 0 ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal, value.Space));
    }
    [Theory]
    [InlineData("cycle")][InlineData("path")][InlineData("permission")][InlineData("missing-root")][InlineData("owner")]
    public async Task DestinationNavigationRejectsInvalidParentOrPermission(string cause)
    {
        using var f = new Fixture { FolderProblem = cause }; if (cause == "owner") f.Rows[0]["target_folder"]!["owner_user_id"] = 88;
        var repo = await f.Repository(); var task = Assert.Single(await repo.BackgroundTasksAsync()); await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.BackgroundTaskLocationAsync(task));
    }
    [Theory]
    [InlineData("clear_completed_task", "")][InlineData("clear_completed_task", "[91]")][InlineData("clear_completed_task", "0")]
    [InlineData("abort_task", "91")][InlineData("abort_task", "[]")][InlineData("abort_task", "[91,91]")][InlineData("abort_task", "[-1]")]
    public async Task TransportNeverAllowsUnboundedClearOrWrongIdShape(string method, string id)
    {
        using var f = new Fixture(); var fields = id.Length == 0 ? new Dictionary<string, string>() : new() { ["id"] = id };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => f.Http.Api.WritePhotoAsync(f.Http.Profile, f.Http.Session, f.Http.Capabilities["SYNO.Foto.BackgroundTask.Info"], 1, method, fields)); Assert.Empty(f.Http.Requests);
    }
    internal static JsonObject Row(long id = 91, string status = "processing") => new()
    {
        ["id"] = id, ["operation"] = "copy", ["status"] = status, ["total"] = 10, ["completion"] = 3, ["error"] = 1,
        ["skip"] = 0, ["overwrite"] = 0, ["create_time"] = 1788220800.123456,
        ["target_folder"] = new JsonObject { ["id"] = 9, ["owner_user_id"] = 19 }
    };
    private static JsonObject Error(long id, string reason = "space_full", string type = "item") => new() { ["id"] = id, ["type"] = type, ["reason"] = reason };
    private sealed class Fixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "entry", RouteSettingWrites = true };
        internal readonly MemoryStore Store = new(); internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal List<JsonObject> Rows = [Row()], Errors = [Error(7)]; internal bool Apply = true, Reject, FailNames, WrongNames, Auto;
        internal int StopAt, Code = 105; internal string FolderProblem = ""; internal Action<int>? AfterWrite;
        internal TaskCompletionSource? Hold; internal readonly TaskCompletionSource Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal Fixture()
        {
            Http.AccessResponse = api => api switch
            {
                "SYNO.Foto.UserInfo" => new() { ["enabled"] = Http.Enabled, ["id"] = Http.UserId, ["is_admin"] = false },
                "SYNO.Foto.Setting.User" => new() { ["enable_home_service"] = Http.HomeEnabled, ["team_space_permission"] = Http.TeamPermission, ["auto_generate_thumbnail"] = Auto }, _ => null
            };
            Http.Respond = async (request, token) =>
            {
                if (request.Method is "abort_task" or "clear_completed_task" or "set")
                {
                    Writes.Add(request); var stopped = Writes.Count == StopAt;
                    if (Apply && !stopped)
                    {
                        if (request.Method == "set") Auto = bool.Parse(request.Values["auto_generate_thumbnail"]);
                        else
                        {
                            var id = JsonNode.Parse(request.Values["id"])!; var number = id is JsonArray array ? array[0]!.GetValue<long>() : id.GetValue<long>();
                            if (request.Method == "abort_task") Rows.Single(value => value["id"]!.GetValue<long>() == number)["status"] = "done";
                            else Rows.RemoveAll(value => value["id"]!.GetValue<long>() == number);
                        }
                    }
                    AfterWrite?.Invoke(Writes.Count); Started.TrySetResult(); if (Hold is not null) await Hold.Task;
                    if (stopped && !Reject) throw new HttpRequestException();
                    return new(HttpStatusCode.OK) { Content = new StringContent(stopped && Reject ? new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = Code } }.ToJsonString() : "{\"success\":true}", Encoding.UTF8, "application/json") };
                }
                if (request.Method == "list_user_task") return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(Rows.Select(value => (JsonObject)value.DeepClone()).ToArray()));
                if (request.Method == "get_error_detail") return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(Errors.Select(value => (JsonObject)value.DeepClone()).ToArray()));
                if (request.Api.EndsWith(".Browse.Item", StringComparison.Ordinal))
                {
                    if (FailNames) throw new HttpRequestException();
                    var ids = JsonNode.Parse(request.Values["id"])!.AsArray().Select(value => value!.GetValue<long>()).Reverse();
                    return SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List(ids.Select(id => new JsonObject { ["id"] = WrongNames ? 999 : id, ["filename"] = "synthetic-" + id, ["additional"] = new JsonObject { ["folder"] = "/Destination" } }).ToArray()));
                }
                if (request.Api.EndsWith(".Browse.Folder", StringComparison.Ordinal))
                {
                    var id = long.Parse(request.Values["id"]); return SynologyPhotosHttpFixture.Json(new() { ["folder"] = new JsonObject { ["id"] = id,
                        ["parent"] = FolderProblem == "cycle" ? 9 : id == 1 ? 0 : 1, ["name"] = id == 1 ? FolderProblem is "path" or "missing-root" ? "/Other" : "/" : "/Destination",
                        ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = FolderProblem != "permission" } } } });
                }
                throw new InvalidOperationException(request.Api + "/" + request.Method);
            };
        }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store); await repo.AccessAsync(); return repo; }
        public void Dispose() => Http.Dispose();
    }
}
