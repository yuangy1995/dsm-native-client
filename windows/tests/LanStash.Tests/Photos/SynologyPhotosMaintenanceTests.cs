using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed class SynologyPhotosMaintenanceTests
{
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal, SynologyPhotoMaintenanceAction.Reindex)]
    [InlineData(SynologyPhotoSpace.Personal, SynologyPhotoMaintenanceAction.Previews)]
    [InlineData(SynologyPhotoSpace.Shared, SynologyPhotoMaintenanceAction.Reindex)]
    [InlineData(SynologyPhotoSpace.Shared, SynologyPhotoMaintenanceAction.Previews)]
    public async Task MaintenanceUsesOriginalSpaceAndActionAndEndsOnlyWithReceiptAndZero(SynologyPhotoSpace space, SynologyPhotoMaintenanceAction action)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var original = await repo.LibraryMaintenanceAsync(space);
        Assert.Empty(f.Writes); var result = await repo.MaintainLibraryAsync(Guid.NewGuid(), original, action, true);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.True(result.MaintenanceAccepted); Assert.Equal(1, result.CompletedSteps);
        var request = Assert.Single(f.Writes); Assert.Equal(space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam.Index" : "SYNO.Foto.Index", request.Api);
        Assert.Equal(1, request.Version); Assert.Equal("reindex", request.Method); Assert.Equal(action == SynologyPhotoMaintenanceAction.Reindex ? "\"basic\"" : "\"thumbnail\"", request.Values["type"]);
        Assert.DoesNotContain(f.Http.Requests, value => value.Api == "SYNO.Foto.Setting.Admin" && value.Method != "get");
        Assert.Equal(result.Id, (await repo.MaintainLibraryAsync(result.Id, original, action, true)).Id); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData("missing-basic")][InlineData("missing-thumbnail")][InlineData("string")][InlineData("negative")][InlineData("fraction")]
    public async Task MalformedCountsNeverBecomeIdle(string cause)
    {
        using var f = new Fixture { BadCounts = cause }; var repo = await f.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Personal)); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task H264CapabilityOnlyRestrictsPreviews()
    {
        using var f = new Fixture { H264 = false }; var repo = await f.Repository(); var original = await repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Personal);
        Assert.True(original.CanStart(SynologyPhotoMaintenanceAction.Reindex)); Assert.False(original.CanStart(SynologyPhotoMaintenanceAction.Previews));
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.MaintainLibraryAsync(Guid.NewGuid(), original, SynologyPhotoMaintenanceAction.Previews, true));
        Assert.Empty(f.Writes); Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.MaintainLibraryAsync(Guid.NewGuid(), original, SynologyPhotoMaintenanceAction.Reindex, true)).State);
    }
    [Theory]
    [InlineData("home")][InlineData("admin")][InlineData("team")][InlineData("role")][InlineData("user")][InlineData("enabled")][InlineData("busy")][InlineData("h264")][InlineData("profile")][InlineData("confirmation")]
    public async Task ChangedOwnerPermissionCountOrConfirmationPreventsSubmission(string cause)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var space = cause is "admin" or "team" or "role" ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal;
        var original = await repo.LibraryMaintenanceAsync(space);
        if (cause == "home") f.Http.HomeEnabled = false; if (cause == "admin") f.Admin = false; if (cause == "team") f.Http.TeamEnabled = false;
        if (cause == "role") f.Http.TeamPermission = "none"; if (cause == "user") f.Http.UserId++; if (cause == "enabled") f.Http.Enabled = false;
        if (cause == "busy") f.Basic = 2; if (cause == "h264") f.H264 = false; if (cause == "profile") original = original with { ProfileId = Guid.NewGuid() };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.MaintainLibraryAsync(Guid.NewGuid(), original,
            cause == "h264" ? SynologyPhotoMaintenanceAction.Previews : SynologyPhotoMaintenanceAction.Reindex, cause != "confirmation")); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task OnlyTheSelectedCounterMustBeIdleAndNonAdminCanMaintainPersonal()
    {
        using var f = new Fixture { Admin = false, Thumbnail = 9 }; var repo = await f.Repository();
        var a = await repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Personal); Assert.False(a.CanStart(SynologyPhotoMaintenanceAction.Previews));
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.MaintainLibraryAsync(Guid.NewGuid(), a, SynologyPhotoMaintenanceAction.Reindex, true)).State);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Shared));
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task LostReceiptNeverResolvesFromRisingThenZeroCountsEvenAfterRestart(bool previews)
    {
        using var f = new Fixture { StopAt = 1, StopStatus = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository();
        var a = await repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Personal); var action = previews ? SynologyPhotoMaintenanceAction.Previews : SynologyPhotoMaintenanceAction.Reindex;
        var result = await repo.MaintainLibraryAsync(Guid.NewGuid(), a, action, true); Assert.True(result.Pending); Assert.False(result.MaintenanceAccepted);
        f.Basic = 3; f.Thumbnail = 2; Assert.True((await repo.ReviewSettingsChangeAsync(result.Id)).Pending);
        f.Basic = 0; f.Thumbnail = 0; var cold = await f.Repository(f.Store.Clone()); Assert.True((await cold.ReviewSettingsChangeAsync(result.Id)).Pending);
        Assert.True((await cold.MaintainLibraryAsync(result.Id, a, action, true)).Pending);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.MaintainLibraryAsync(Guid.NewGuid(), a, action, true)); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task AcceptedMaintenanceSurvivesReadFailureAndRestartWithoutResubmission()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Shared);
        f.OnWrite = () => { f.Basic = 8; f.FailReads = true; };
        var result = await repo.MaintainLibraryAsync(Guid.NewGuid(), a, SynologyPhotoMaintenanceAction.Reindex, true); Assert.True(result.Pending); Assert.True(result.MaintenanceAccepted);
        f.FailReads = false; var cold = await f.Repository(f.Store.Clone()); var current = await cold.ReviewSettingsChangeAsync(result.Id); Assert.Equal(8, current.MaintenanceResult!.IndexingCount);
        f.Basic = 0; Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ReviewSettingsChangeAsync(result.Id)).State); Assert.Single(f.Writes);
    }
    [Theory]
    [InlineData(100)][InlineData(105)][InlineData(119)]
    public async Task ExplicitMaintenanceRejectionStaysFailed(int code)
    {
        using var f = new Fixture { StopAt = 1, StopStatus = SynologyPhotoWriteStatus.Rejected, RejectionCode = code }; var repo = await f.Repository(); var a = await repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Personal);
        var result = await repo.MaintainLibraryAsync(Guid.NewGuid(), a, SynologyPhotoMaintenanceAction.Reindex, true);
        Assert.Equal(SynologyPhotoChangeState.Failed, result.State); Assert.Equal(SynologyPhotoChangeState.Failed, (await repo.ReviewSettingsChangeAsync(result.Id)).State); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task DuplicateClicksAndDifferentSettingsShareTheExistingOperationGate()
    {
        using var f = new Fixture { Hold = new(TaskCreationOptions.RunContinuationsAsynchronously) }; var repo = await f.Repository(); var a = await repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Personal); var id = Guid.NewGuid();
        var first = repo.MaintainLibraryAsync(id, a, SynologyPhotoMaintenanceAction.Reindex, true); await f.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True((await repo.MaintainLibraryAsync(id, a, SynologyPhotoMaintenanceAction.Reindex, true)).Pending);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.MaintainLibraryAsync(id, a, SynologyPhotoMaintenanceAction.Previews, true));
        var prompt = await repo.CodecPromptAsync(); await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, false));
        Assert.Single(f.Writes); f.Hold.TrySetResult(); Assert.Equal(SynologyPhotoChangeState.Completed, (await first).State);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task CheckpointBeforeWriteIsConservativeOnColdRecoveryButLiveCancellationDoesNotClaimSubmission(bool codec)
    {
        using var f = new Fixture(); var repo = await f.Repository(); using var cancellation = new CancellationTokenSource(); MemoryStore? checkpoint = null;
        var a = await repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Personal); var prompt = await repo.CodecPromptAsync();
        f.Store.AfterSave = raw => { if (raw["Settings"]?["State"]?.GetValue<int>() == (int)SynologyPhotoChangeState.Submitting) { checkpoint = f.Store.Clone(); cancellation.Cancel(); } return Task.CompletedTask; };
        var result = codec ? await repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, true, cancellation.Token) :
            await repo.MaintainLibraryAsync(Guid.NewGuid(), a, SynologyPhotoMaintenanceAction.Reindex, true, cancellation.Token);
        Assert.Empty(f.Writes); Assert.Equal(SynologyPhotoChangeState.Cancelled, result.State); Assert.NotNull(checkpoint);
        var cold = await f.Repository(checkpoint!); Assert.True((await cold.ReviewSettingsChangeAsync(result.Id)).Pending); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData(false, true, "reindex")][InlineData(true, false, "reindex_all_user")][InlineData(true, true, "reindex_all_user")]
    public async Task CodecGenerationUsesTheExactScopeThenOnlyDismissesTheKnownPrompt(bool admin, bool home, string method)
    {
        using var f = new Fixture { Admin = admin }; f.Http.HomeEnabled = home; var repo = await f.Repository(); var prompt = await repo.CodecPromptAsync();
        Assert.True(prompt.CanGenerate); Assert.Empty(f.Writes); var result = await repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, true);
        Assert.Equal(SynologyPhotoChangeState.Completed, result.State); Assert.True(result.CodecGenerationAccepted); Assert.False(result.IsRunning); Assert.Equal(2, result.CompletedSteps);
        Assert.Collection(f.Writes, write => { Assert.Equal("SYNO.Foto.Index", write.Api); Assert.Equal(method, write.Method); Assert.Equal("\"thumbnail\"", write.Values["type"]); },
            write => { Assert.Equal("SYNO.Foto.Setting.Wizard", write.Api); Assert.Equal("set", write.Method); Assert.Equal("[{\"name\":\"new_codec_installed\",\"show\":false}]", write.Values["prompt"]); });
        Assert.True(f.OtherPrompt); Assert.DoesNotContain(f.Http.Requests, value => value.Api.EndsWith(".Index", StringComparison.Ordinal) && value.Method == "get");
        Assert.Equal(result.Id, (await repo.RespondToCodecPromptAsync(result.Id, prompt, true, true)).Id); Assert.Equal(2, f.Writes.Count);
    }
    [Fact]
    public async Task LaterNeverStartsGenerationEvenWhenPersonalLibraryIsDisabled()
    {
        using var f = new Fixture { Admin = false }; f.Http.HomeEnabled = false; var repo = await f.Repository(); var prompt = await repo.CodecPromptAsync(); Assert.False(prompt.CanGenerate);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, true)); Assert.Empty(f.Writes);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, false)).State); Assert.Equal("SYNO.Foto.Setting.Wizard", Assert.Single(f.Writes).Api);
    }
    [Theory]
    [InlineData("duplicate")][InlineData("missing")][InlineData("show")][InlineData("name")][InlineData("admin")][InlineData("home")]
    public async Task IncompletePromptAndIdentityAreNotWritable(string cause)
    {
        using var f = new Fixture(); var repo = await f.Repository(); f.BadPrompt = cause;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.CodecPromptAsync()); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task MissingKnownPromptIsAnEmptyStateAndNeverWritesOtherPrompts()
    {
        using var f = new Fixture { BadPrompt = "absent" }; var repo = await f.Repository(); var prompt = await repo.CodecPromptAsync();
        Assert.False(prompt.ShouldShow); await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, false)); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData("admin")][InlineData("home")][InlineData("user")][InlineData("shown")][InlineData("confirmation")]
    public async Task CodecRechecksIdentityAndOriginalScopeBeforeStarting(string cause)
    {
        using var f = new Fixture(); var repo = await f.Repository(); var prompt = await repo.CodecPromptAsync();
        if (cause == "admin") f.Admin = false; if (cause == "home") f.Http.HomeEnabled = false; if (cause == "user") f.Http.UserId++; if (cause == "shown") f.Shown = false;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, cause != "confirmation")); Assert.Empty(f.Writes);
    }
    [Theory]
    [InlineData(SynologyPhotoWriteStatus.Unknown)][InlineData(SynologyPhotoWriteStatus.Rejected)]
    public async Task GenerationWithoutAcceptanceNeverHidesThePromptAndCannotBeInferredFromItsLaterAbsence(SynologyPhotoWriteStatus status)
    {
        using var f = new Fixture { StopAt = 1, StopStatus = status }; var repo = await f.Repository(); var prompt = await repo.CodecPromptAsync();
        var result = await repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, true); Assert.Single(f.Writes); Assert.True(f.Shown); Assert.False(result.IsRunning);
        f.Shown = false; var cold = await f.Repository(f.Store.Clone()); var reviewed = await cold.ReviewSettingsChangeAsync(result.Id);
        Assert.Equal(status == SynologyPhotoWriteStatus.Unknown ? SynologyPhotoChangeState.PendingReview : SynologyPhotoChangeState.Failed, reviewed.State); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task PartialGenerationPersistsAndContinuingAfterRestartOnlySavesThePrompt()
    {
        using var f = new Fixture { StopAt = 2, StopStatus = SynologyPhotoWriteStatus.Rejected }; var repo = await f.Repository(); var prompt = await repo.CodecPromptAsync();
        var result = await repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, true); Assert.True(result.PartiallySaved); Assert.True(result.CodecGenerationAccepted);
        var cold = await f.Repository(f.Store.Clone()); var again = await cold.CodecPromptAsync(); Assert.True(again.GenerationAlreadySubmitted); Assert.False(again.CanGenerate);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, true)); Assert.Equal(2, f.Writes.Count);
        Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.RespondToCodecPromptAsync(Guid.NewGuid(), again, false)).State); Assert.Equal("SYNO.Foto.Setting.Wizard", f.Writes[2].Api);
        Assert.False((await cold.CodecPromptAsync()).ShouldShow); f.Shown = true; Assert.True((await cold.CodecPromptAsync()).CanGenerate);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task UnknownPromptSaveCanResolveReadOnlyButNeverRepeatsGeneration(bool apply)
    {
        using var f = new Fixture { StopAt = 2, StopStatus = SynologyPhotoWriteStatus.Unknown, ApplyStopped = apply }; var repo = await f.Repository(); var prompt = await repo.CodecPromptAsync();
        var result = await repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, true); Assert.Equal(apply ? SynologyPhotoChangeState.Completed : SynologyPhotoChangeState.PendingReview, result.State);
        f.Shown = false; var cold = await f.Repository(f.Store.Clone()); Assert.Equal(SynologyPhotoChangeState.Completed, (await cold.ReviewSettingsChangeAsync(result.Id)).State); Assert.Equal(2, f.Writes.Count);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task CancellationOrChangedRoleAfterAcceptedGenerationPreservesPartialWithoutSendingPrompt(bool cancel)
    {
        using var f = new Fixture(); using var token = new CancellationTokenSource(); var repo = await f.Repository(); var prompt = await repo.CodecPromptAsync();
        f.Store.AfterSave = raw => { if (raw["Settings"]?["Codec"]?["GenerationReceipt"]?.GetValue<int>() == (int)SynologyPhotoWriteStatus.Accepted && raw["Settings"]?["Codec"]?["PromptReceipt"] is null)
            { if (cancel) token.Cancel(); else f.Admin = false; } return Task.CompletedTask; };
        var result = await repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, true, token.Token);
        Assert.True(result.PartiallySaved); Assert.True(result.CodecGenerationAccepted); Assert.Single(f.Writes);
        var cold = await f.Repository(f.Store.Clone()); Assert.True((await cold.CodecPromptAsync()).GenerationAlreadySubmitted);
    }
    [Theory]
    [InlineData("receipt")][InlineData("count")][InlineData("profile")][InlineData("space")][InlineData("codec-order")]
    public async Task CorruptRecoveryNeverUnlocksWrites(string cause)
    {
        using var f = new Fixture { StopAt = 1, StopStatus = SynologyPhotoWriteStatus.Unknown }; var repo = await f.Repository(); var a = await repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Personal);
        var result = await repo.MaintainLibraryAsync(Guid.NewGuid(), a, SynologyPhotoMaintenanceAction.Reindex, true); var store = f.Store.Clone(); var raw = JsonNode.Parse(store.Records[result.Id])!; var record = raw["Settings"]!;
        if (cause == "receipt") record["Maintenance"]!["Receipt"] = 999; if (cause == "count") record["CompletedSteps"] = 2;
        if (cause == "profile") record["Maintenance"]!["Change"]!["Original"]!["ProfileId"] = Guid.NewGuid();
        if (cause == "space") record["Maintenance"]!["Change"]!["Original"]!["Space"] = 999;
        if (cause == "codec-order") { record["Maintenance"] = null; record["Codec"] = JsonNode.Parse(System.Text.Json.JsonSerializer.Serialize(new { Response = new SynologyPhotoCodecResponse(await repo.CodecPromptAsync(), true), PromptReceipt = SynologyPhotoWriteStatus.Accepted })); }
        store.Records[result.Id] = Encoding.UTF8.GetBytes(raw.ToJsonString()); var cold = await f.Repository(store);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.SettingsChangesAsync()); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task CrashBetweenGenerationReceiptAndPromptAttemptRecoversAsPartialAndNeverReplaysGeneration()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var prompt = await repo.CodecPromptAsync(); MemoryStore? checkpoint = null;
        f.Store.AfterSave = raw => { if (raw["Settings"]?["Codec"]?["GenerationReceipt"]?.GetValue<int>() == (int)SynologyPhotoWriteStatus.Accepted && raw["Settings"]?["Codec"]?["PromptReceipt"] is null)
            checkpoint = f.Store.Clone(); return Task.CompletedTask; };
        var result = await repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, true); Assert.NotNull(checkpoint); f.Shown = true;
        var cold = await f.Repository(checkpoint!); var partial = await cold.ReviewSettingsChangeAsync(result.Id); Assert.True(partial.PartiallySaved);
        var current = await cold.CodecPromptAsync(); Assert.True(current.GenerationAlreadySubmitted); var before = f.Writes.Count;
        await cold.RespondToCodecPromptAsync(Guid.NewGuid(), current, false); Assert.Equal(before + 1, f.Writes.Count); Assert.Equal("SYNO.Foto.Setting.Wizard", f.Writes[^1].Api);
    }
    [Theory]
    [InlineData("SYNO.Foto.Index")][InlineData("SYNO.Foto.Setting.Wizard")]
    public async Task MissingCapabilityFailsOnlyTheRequestedFeature(string name)
    {
        using var f = new Fixture(); f.Http.Capabilities.Remove(name); var repo = await f.Repository();
        if (name.EndsWith(".Index", StringComparison.Ordinal)) await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Personal));
        else await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.CodecPromptAsync());
        Assert.NotEmpty((await repo.AccessAsync()).Spaces); Assert.Empty(f.Writes);
    }
    [Fact]
    public async Task IdentityChangeAfterReceiptCannotCompleteAgainstAnotherUser()
    {
        using var f = new Fixture(); var repo = await f.Repository(); var a = await repo.LibraryMaintenanceAsync(SynologyPhotoSpace.Personal);
        f.OnWrite = () => f.Http.UserId++; var result = await repo.MaintainLibraryAsync(Guid.NewGuid(), a, SynologyPhotoMaintenanceAction.Reindex, true);
        Assert.True(result.Pending); Assert.True(result.MaintenanceAccepted); Assert.Null(result.MaintenanceResult);
        Assert.True((await repo.ReviewSettingsChangeAsync(result.Id)).Pending); Assert.Single(f.Writes);
    }
    [Fact]
    public async Task LatePromptReadCannotReturnAcrossAccessGenerationEvenWhenOnlyLocalMarkerWasSaved()
    {
        using var f = new Fixture { StopAt = 2, StopStatus = SynologyPhotoWriteStatus.Rejected }; var repo = await f.Repository(); var prompt = await repo.CodecPromptAsync();
        await repo.RespondToCodecPromptAsync(Guid.NewGuid(), prompt, true, true); f.Shown = false;
        f.Store.AfterSave = async raw => { if (raw["Settings"]?["Codec"]?["PromptClosed"]?.GetValue<bool>() == true) { f.Http.UserId++; await repo.AccessAsync(); } };
        await Assert.ThrowsAsync<OperationCanceledException>(() => repo.CodecPromptAsync()); Assert.Equal(2, f.Writes.Count);
    }
    private sealed class Fixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new(); internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal bool Admin = true, H264 = true, Shown = true, OtherPrompt = true, FailReads, ApplyStopped;
        internal long Basic, Thumbnail; internal string BadCounts = "", BadPrompt = ""; internal int StopAt, RejectionCode = 100;
        internal SynologyPhotoWriteStatus StopStatus = SynologyPhotoWriteStatus.Unknown; internal Action? OnWrite;
        internal TaskCompletionSource? Hold; internal readonly TaskCompletionSource Started = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal Fixture()
        {
            Http.TeamEnabled = true; Http.TeamPermission = "management";
            foreach (var name in new[] { "SYNO.Foto.Index", "SYNO.FotoTeam.Index", "SYNO.Foto.Setting.Wizard" }) Http.Capabilities.Add(name, new(name, "entry.cgi", 1, 9, "JSON"));
            Http.AccessResponse = api => api switch
            {
                "SYNO.Foto.UserInfo" => new() { ["enabled"] = Http.Enabled, ["id"] = Http.UserId, ["is_admin"] = BadPrompt == "admin" ? null : Admin },
                "SYNO.Foto.Setting.User" => new() { ["enable_home_service"] = BadPrompt == "home" ? null : Http.HomeEnabled, ["team_space_permission"] = Http.TeamPermission, ["ame_status"] = new JsonObject { ["has_h264"] = H264 } },
                _ => null
            };
            Http.Respond = async (request, token) =>
            {
                if (request.Method == "get")
                {
                    if (FailReads) throw new HttpRequestException(); Assert.Empty(request.Values.Keys.Except(["api", "version", "method", "_sid", "SynoToken"])); Assert.Equal(1, request.Version);
                    if (request.Api.EndsWith(".Index", StringComparison.Ordinal))
                    {
                        var counts = new JsonObject { ["basic"] = Basic, ["thumbnail"] = Thumbnail };
                        if (BadCounts == "missing-basic") counts.Remove("basic"); if (BadCounts == "missing-thumbnail") counts.Remove("thumbnail");
                        if (BadCounts == "string") counts["basic"] = "0"; if (BadCounts == "negative") counts["thumbnail"] = -1; if (BadCounts == "fraction") counts["thumbnail"] = 0.5;
                        return SynologyPhotosHttpFixture.Json(counts);
                    }
                    var entry = new JsonObject { ["name"] = "new_codec_installed", ["show"] = Shown };
                    if (BadPrompt == "name") entry["name"] = false; if (BadPrompt == "show") entry["show"] = "true";
                    var list = new JsonArray { new JsonObject { ["name"] = "other_prompt", ["show"] = OtherPrompt } }; if (BadPrompt != "absent") list.Add(entry);
                    if (BadPrompt == "duplicate") list.Add(entry.DeepClone()); return SynologyPhotosHttpFixture.Json(BadPrompt == "missing" ? new() : new() { ["prompt"] = list });
                }
                Writes.Add(request); var stopped = Writes.Count == StopAt; if (request.Api == "SYNO.Foto.Setting.Wizard" && (!stopped || ApplyStopped)) Shown = false;
                OnWrite?.Invoke(); Started.TrySetResult(); if (Hold is { } hold) await hold.Task;
                if (stopped && StopStatus == SynologyPhotoWriteStatus.Unknown) throw new HttpRequestException();
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(stopped && StopStatus == SynologyPhotoWriteStatus.Rejected ?
                    new JsonObject { ["success"] = false, ["error"] = new JsonObject { ["code"] = RejectionCode } }.ToJsonString() : "{\"success\":true}", Encoding.UTF8, "application/json") };
            };
        }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, managementStore: store ?? Store); await repo.AccessAsync(); return repo; }
        public void Dispose() => Http.Dispose();
    }
}
