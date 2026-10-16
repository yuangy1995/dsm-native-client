using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;
using MemoryStore = LanStash.Tests.SynologyPhotosUploadTests.MemoryStore;

namespace LanStash.Tests;

public sealed partial class SynologyPhotosPreviewGenerationTests
{
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal)]
    [InlineData(SynologyPhotoSpace.Shared)]
    public async Task NasGenerationSubscribesBeforeOneWriteAndReadsActualPhoto(SynologyPhotoSpace space)
    {
        using var f = new Fixture(space); var repo = await f.Repository();
        var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request());
        Assert.True(result.Completed); Assert.False(result.Running); Assert.Equal("new-preview", Assert.Single(result.Items).Updated!.Thumbnail!.Revision);
        Assert.Equal(["subscribe", "set_regenerating", "regenerate_preview_by_nas", "event", "dispose"], f.Events);
        Assert.Equal(0, f.Conversions); Assert.Equal(0, f.Downloads);
        var writes = f.Http.Requests.Where(call => call.Method is "set_regenerating" or "regenerate_preview_by_nas").ToArray();
        Assert.All(writes, call => { Assert.Equal(1, call.Version); Assert.Equal(space == SynologyPhotoSpace.Shared ? "SYNO.FotoTeam.RegeneratePreview" : "SYNO.Foto.RegeneratePreview", call.Api); Assert.DoesNotContain("album_id", call.Values.Keys); });
        Assert.Equal("[7]", writes[0].Values["item_id"]); Assert.Equal("7", writes[1].Values["unit_id"]);
    }
    [Fact]
    public async Task PngConvertsBeforeMarkingAndUploadsThreeThumbnails()
    {
        using var f = new Fixture { Extension = ".png" }; var repo = await f.Repository(); var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request());
        Assert.True(result.Completed); Assert.Equal(["download", "convert", "set_regenerating", "upload"], f.Events);
        Assert.Equal(1, f.Conversions); Assert.False(File.Exists(f.LocalSource)); Assert.False(Directory.Exists(Path.GetDirectoryName(f.LocalSource)));
        var record = Encoding.UTF8.GetString(f.Store.Records[result.Id]);
        Assert.DoesNotContain(f.LocalSource!, record); Assert.DoesNotContain("synthetic-sid", record); Assert.DoesNotContain("synthetic-token", record); Assert.DoesNotContain("Large", record);
    }
    [Theory]
    [InlineData("event-false")]
    [InlineData("nas-reject")]
    [InlineData("subscribe-failed")]
    public async Task ExplicitNasFailureFallsBackToLocalOnce(string problem)
    {
        using var f = new Fixture { Problem = problem }; var repo = await f.Repository(); var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request());
        Assert.True(result.Completed); Assert.Equal(1, f.Conversions); Assert.Equal(1, f.Events.Count(value => value == "upload"));
        Assert.Equal(1, f.Events.Count(value => value == "set_regenerating")); Assert.DoesNotContain("restore_from_regenerating", f.Events);
    }
    [Fact]
    public async Task PngRejectedUploadCanUseNasWithoutRepeatingMark()
    {
        using var f = new Fixture { Extension = ".png", UploadStatus = SynologyPhotoWriteStatus.Rejected }; var repo = await f.Repository();
        Assert.True((await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request())).Completed);
        Assert.Equal(["download", "convert", "set_regenerating", "upload", "subscribe", "regenerate_preview_by_nas", "event", "dispose"], f.Events);
    }
    [Theory]
    [InlineData("nas-lost")]
    [InlineData("event-disconnected")]
    [InlineData("upload-lost")]
    public async Task UnknownConversionNeverFallbacksOrReplaysAfterRestart(string problem)
    {
        using var f = new Fixture { Problem = problem, Extension = problem == "upload-lost" ? ".png" : ".jpg" }; var repo = await f.Repository(); var request = f.Request(); var id = Guid.NewGuid();
        var result = await repo.GeneratePreviewsAsync(id, request); Assert.True(result.Pending); Assert.False(result.CanContinue); var writes = f.Writes;
        await repo.GeneratePreviewsAsync(id, request); await repo.ContinuePreviewGenerationAsync(id); Assert.Equal(writes, f.Writes);
        var cold = await f.Repository(f.Store.Clone()); Assert.True(Assert.Single(await cold.PreviewGenerationsAsync()).Pending);
        await cold.ContinuePreviewGenerationAsync(id); await cold.ReviewPreviewGenerationAsync(id); Assert.Equal(writes, f.Writes);
        Assert.DoesNotContain("restore_from_regenerating", f.Events); Assert.Equal(problem == "upload-lost" ? 1 : 0, f.Conversions);
    }
    [Theory]
    [InlineData("same-version")]
    [InlineData("empty-version")]
    [InlineData("different-unit")]
    [InlineData("different-original")]
    [InlineData("second-queue-present")]
    [InlineData("unstable-version")]
    [InlineData("complete-proof")]
    public async Task UnknownRecoveryRequiresTwoQueueAbsencesAndStableNewPreview(string proof)
    {
        using var f = new Fixture { Problem = "nas-lost" }; var repo = await f.Repository(); var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request()); Assert.True(result.Pending);
        var cold = await f.Repository(f.Store.Clone()); f.Queued.Clear(); f.Revision = proof == "same-version" ? "synthetic-revision" : proof == "empty-version" ? "" : "new-preview";
        if (proof == "different-unit") f.ThumbnailUnit = 98;
        if (proof == "different-original") f.Size = 9;
        f.QueueReads = 0; f.ItemReads = 0;
        f.BeforeRead = call => { if (proof == "second-queue-present" && call.Method == "list_regenerating" && f.QueueReads == 2) f.Queued.Add(7); if (proof == "unstable-version" && call.Api.EndsWith("Browse.Item") && f.ItemReads == 2) f.Revision = "third-preview"; };
        var writes = f.Writes; result = await cold.ReviewPreviewGenerationAsync(result.Id);
        Assert.Equal(proof == "complete-proof", result.Completed); Assert.Equal(proof != "complete-proof", result.Pending); Assert.Equal(writes, f.Writes);
    }
    [Fact]
    public async Task LostMarkReceiptOnlyBecomesReadyAndNeedsExplicitContinue()
    {
        using var f = new Fixture { Problem = "mark-lost" }; var repo = await f.Repository(); var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request()); Assert.True(result.Pending);
        var cold = await f.Repository(f.Store.Clone()); var writes = f.Writes; result = await cold.ReviewPreviewGenerationAsync(result.Id);
        Assert.True(result.CanContinue); Assert.Equal(SynologyPhotoChangeState.Ready, result.Items[0].State); Assert.Equal(writes, f.Writes);
        result = await cold.ContinuePreviewGenerationAsync(result.Id); Assert.True(result.Completed); Assert.Equal(1, f.Events.Count(value => value == "set_regenerating"));
    }
    [Fact]
    public async Task ResumeExistingQueueNeverMarksAgain()
    {
        using var f = new Fixture(); f.Queued.Add(7); var repo = await f.Repository(); var request = f.Request(resuming: true);
        var queued = await repo.PendingPreviewGenerationsAsync(f.Space); Assert.Equal(f.Photo().Id, Assert.Single(queued).Id); Assert.Empty(f.Events);
        Assert.True((await repo.GeneratePreviewsAsync(Guid.NewGuid(), request)).Completed); Assert.DoesNotContain("set_regenerating", f.Events);
    }
    [Theory]
    [InlineData("missing")]
    [InlineData("filename")]
    [InlineData("type")]
    [InlineData("duplicate")]
    public async Task ResumeRequiresMatchingQueueIdentity(string problem)
    {
        using var f = new Fixture { QueueProblem = problem }; if (problem != "missing") f.Queued.Add(7); var repo = await f.Repository();
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request(resuming: true))); Assert.Empty(f.Events);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AllKnownFailuresRestoreOnceAndNeverClaimGeneration(bool lostRestore)
    {
        using var f = new Fixture { Problem = "event-false", ConversionFails = true, LostRestore = lostRestore }; var repo = await f.Repository(); var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request());
        Assert.Equal(SynologyPhotoChangeState.Failed, result.Items[0].State); Assert.False(result.Completed); Assert.Equal(1, f.Events.Count(value => value == "restore_from_regenerating"));
        var cold = await f.Repository(f.Store.Clone()); var writes = f.Writes; await cold.ContinuePreviewGenerationAsync(result.Id); Assert.Equal(writes, f.Writes);
    }
    [Theory]
    [InlineData("personal-denied")]
    [InlineData("shared-no-view")]
    [InlineData("shared-no-download-manage")]
    [InlineData("source-disabled")]
    [InlineData("user-changed")]
    public async Task PermissionFailureBeforeStartWritesNothing(string permission)
    {
        using var f = new Fixture(permission.StartsWith("shared") ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal);
        f.Http.TeamPermission = "entry"; var repo = await f.Repository();
        switch (permission) { case "personal-denied": f.Manage = false; break; case "shared-no-view": f.View = false; break; case "shared-no-download-manage": f.Download = f.Manage = false; break; case "source-disabled": f.Http.HomeEnabled = false; break; default: f.Http.UserId = 20; break; }
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request()))).Failure); Assert.Empty(f.Events);
    }
    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task SharedEntryMayUseEitherDownloadOrManage(bool download, bool manage)
    {
        using var f = new Fixture(SynologyPhotoSpace.Shared) { Download = download, Manage = manage }; f.Http.TeamPermission = "entry"; var repo = await f.Repository();
        Assert.True((await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request())).Completed);
    }
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal, 19, 19, false, false, true)]
    [InlineData(SynologyPhotoSpace.Personal, 19, 20, false, false, false)]
    [InlineData(SynologyPhotoSpace.Personal, 19, 20, true, false, true)]
    [InlineData(SynologyPhotoSpace.Personal, 19, 20, false, true, true)]
    [InlineData(SynologyPhotoSpace.Personal, 20, 20, true, false, false)]
    [InlineData(SynologyPhotoSpace.Shared, 0, 19, false, false, true)]
    [InlineData(SynologyPhotoSpace.Shared, 0, 20, false, false, false)]
    public async Task AlbumProviderAndOriginalSourceControlGeneration(SynologyPhotoSpace space, long owner, long provider, bool conditional, bool frozen, bool allowed)
    {
        using var f = new Fixture(space) { Album = new(41, owner, provider), Conditional = conditional, Frozen = frozen }; f.Http.TeamPermission = "entry"; var repo = await f.Repository();
        if (allowed) Assert.True((await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request())).Completed);
        else { Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request()))).Failure); Assert.Empty(f.Events); }
        Assert.All(f.Http.Requests.Where(call => call.Api.EndsWith("RegeneratePreview")), call => Assert.DoesNotContain("album_id", call.Values.Keys));
    }
    [Fact]
    public async Task OtherSharedProviderRequiresGlobalRoleEvenWhenFolderManageGranted()
    {
        using var f = new Fixture(SynologyPhotoSpace.Shared) { Album = new(41, 0, 20) }; var repo = await f.Repository();
        Assert.True((await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request())).Completed);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MixedSpaceSelectionRequiresGlobalManagement(bool global)
    {
        using var f = new Fixture(); f.Http.TeamPermission = global ? "management" : "entry"; var repo = await f.Repository();
        var request = new SynologyPhotoPreviewGenerationRequest([f.Photo(), f.Photo() with { Id = f.Photo().Id with { Space = SynologyPhotoSpace.Shared } }]);
        if (global) Assert.True((await repo.GeneratePreviewsAsync(Guid.NewGuid(), request)).Completed);
        else { await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GeneratePreviewsAsync(Guid.NewGuid(), request)); Assert.Empty(f.Events); }
    }
    [Theory]
    [InlineData("permission")]
    [InlineData("identity")]
    [InlineData("source")]
    public async Task ConversionRevalidatesBeforeAnyNasWrite(string problem)
    {
        using var f = new Fixture { Extension = ".png" }; var repo = await f.Repository();
        f.AfterConvert = () => { if (problem == "permission") f.Manage = false; else if (problem == "identity") f.Size = 9; else f.Http.HomeEnabled = false; };
        var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request()); Assert.Equal(SynologyPhotoChangeState.Failed, result.Items[0].State); Assert.Equal(0, f.Writes); Assert.False(File.Exists(f.LocalSource));
    }
    [Fact]
    public async Task CancelStopsEventWaitAndLeavesUnknownWorkForReadOnlyRecovery()
    {
        using var f = new Fixture { HoldEvent = true }; var repo = await f.Repository(); var id = Guid.NewGuid();
        var running = repo.GeneratePreviewsAsync(id, new([f.Photo(), f.Photo(8)])); await f.EventStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var stopped = await repo.CancelPreviewGenerationAsync(id).WaitAsync(TimeSpan.FromSeconds(5)); await running;
        Assert.True(stopped.Pending); Assert.Equal(SynologyPhotoChangeState.Cancelled, stopped.Items[1].State); Assert.Contains("dispose", f.Events); var writes = f.Writes;
        var cold = await f.Repository(f.Store.Clone()); await cold.ContinuePreviewGenerationAsync(id); Assert.Equal(writes, f.Writes);
    }
    [Fact]
    public async Task SameIdWhileRunningAndNewIdForSamePhotoCannotRepeatWrite()
    {
        using var f = new Fixture { HoldEvent = true }; var repo = await f.Repository(); var id = Guid.NewGuid(); var request = f.Request();
        var running = repo.GeneratePreviewsAsync(id, request); await f.EventStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.True((await repo.GeneratePreviewsAsync(id, request)).Running);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GeneratePreviewsAsync(Guid.NewGuid(), request))).Failure);
        await repo.CancelPreviewGenerationAsync(id); await running; Assert.Equal(2, f.Writes);
    }
    [Fact]
    public async Task LateCompletionCannotPublishForNewAccount()
    {
        using var f = new Fixture { HoldEvent = true }; var repo = await f.Repository(); var id = Guid.NewGuid(); var running = repo.GeneratePreviewsAsync(id, f.Request());
        await f.EventStarted.Task.WaitAsync(TimeSpan.FromSeconds(5)); f.Http.UserId = 20; await repo.AccessAsync(); f.ReleaseEvent.TrySetResult(true);
        var result = await running; Assert.True(result.Pending); Assert.Null(result.Items[0].Updated); Assert.Empty(await repo.PreviewGenerationsAsync());
        f.Http.UserId = 19; await repo.AccessAsync(); Assert.True((await repo.ReviewPreviewGenerationAsync(id)).Completed); Assert.Equal(2, f.Writes);
    }
    [Theory]
    [InlineData("first-save")]
    [InlineData("before-mark")]
    [InlineData("after-mark")]
    public async Task PersistenceFailureStopsWritesAndRequiresRecoveryRepair(string point)
    {
        using var f = new Fixture(); var repo = await f.Repository();
        f.Store.FailSave = value => { var entry = value["Preview"]?["Items"]?[0]; return point switch { "first-save" => true, "before-mark" => entry?["Marking"]?.GetValue<bool>() == true && entry?["Marked"]?.GetValue<bool>() != true, _ => entry?["Marked"]?.GetValue<bool>() == true }; };
        Assert.Equal(SynologyPhotoFailure.RecoveryUnavailable, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request()))).Failure);
        Assert.Equal(point == "after-mark" ? 1 : 0, f.Writes);
    }
    [Fact]
    public async Task RevocationAfterDurableCheckpointPreventsMark()
    {
        using var f = new Fixture(); var repo = await f.Repository(); f.Store.AfterSave = value => { if (value["Preview"]?["Items"]?[0]?["Marking"]?.GetValue<bool>() == true) f.Manage = false; return Task.CompletedTask; };
        var result = await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request()); Assert.Equal(SynologyPhotoChangeState.Failed, result.Items[0].State); Assert.Equal(0, f.Writes);
    }
    [Fact]
    public async Task PendingPreviewBlocksMetadataAndFolderRename()
    {
        using var f = new Fixture { Problem = "nas-lost" }; var repo = await f.Repository(); await repo.GeneratePreviewsAsync(Guid.NewGuid(), f.Request());
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.PrepareEditAsync(new(SynologyPhotoEditKind.Rating, [f.Photo()]) { Value = 1 }))).Failure);
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Rename, new(f.Space, 3, 1, "/Synthetic")) { Name = "Renamed" }))).Failure);
        Assert.Equal(2, f.Writes);
    }

    private sealed class Fixture : IDsmApiClient, ISynologyPhotoPreviewConverter, IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management" };
        internal readonly MemoryStore Store = new();
        internal readonly List<string> Events = [];
        internal readonly HashSet<long> Queued = [];
        internal readonly TaskCompletionSource EventStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource<bool> ReleaseEvent = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly SynologyPhotoSpace Space;
        internal string Extension = ".jpg", Revision = "synthetic-revision";
        internal string? Problem, QueueProblem, LocalSource;
        internal long Size = 8, ThumbnailUnit = 8;
        internal bool Manage = true, View = true, Download = true, Conditional, Frozen, ConversionFails, LostRestore, HoldEvent;
        internal SynologyPhotoAlbumContext? Album;
        internal SynologyPhotoWriteStatus UploadStatus = SynologyPhotoWriteStatus.Accepted;
        internal int Conversions, Downloads, QueueReads, ItemReads;
        internal Action? AfterConvert;
        internal Action<SynologyPhotosHttpFixture.Request>? BeforeRead;
        internal int Writes => Events.Count(value => value is "set_regenerating" or "regenerate_preview_by_nas" or "restore_from_regenerating" or "upload");
        internal Fixture(SynologyPhotoSpace space = SynologyPhotoSpace.Personal)
        {
            Space = space; Http.Respond = Respond;
            foreach (var prefix in new[] { "SYNO.Foto.", "SYNO.FotoTeam." }) foreach (var suffix in new[] { "RegeneratePreview", "Upload.ConvertedFile" })
                Http.Capabilities[prefix + suffix] = new(prefix + suffix, "entry.cgi", 1, suffix == "RegeneratePreview" ? 1 : 3, "JSON");
        }
        internal SynologyPhoto Photo(long id = 7) => Http.Photo with { Id = Http.Photo.Id with { ItemId = id, Space = Space }, Filename = "synthetic" + Extension, AlbumContext = Album };
        internal SynologyPhotoPreviewGenerationRequest Request(bool resuming = false) => new([Photo()], resuming);
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, this, Http.Capabilities, managementStore: store ?? Store, previewConverter: this); await repo.AccessAsync(); return repo; }
        private JsonObject Queue(long id) => new() { ["unit_id"] = id, ["filename"] = QueueProblem == "filename" ? "wrong.jpg" : "synthetic" + Extension, ["type"] = QueueProblem == "type" ? "video" : "photo" };
        private static HttpResponseMessage Reject() => new(HttpStatusCode.OK) { Content = new StringContent("{\"success\":false,\"error\":{\"code\":105}}", Encoding.UTF8, "application/json") };
        private Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request call, CancellationToken token)
        {
            if (call.Method == "list_regenerating") QueueReads++; if (call.Api.EndsWith("Browse.Item")) ItemReads++; BeforeRead?.Invoke(call);
            JsonObject data;
            if (call.Api.EndsWith("RegeneratePreview"))
            {
                if (call.Method != "list_regenerating") Events.Add(call.Method);
                var id = call.Method is "set_regenerating" or "restore_from_regenerating" ? JsonSerializer.Deserialize<long[]>(call.Values[call.Method == "set_regenerating" ? "item_id" : "unit_id"])!.Single() : call.Method == "regenerate_preview_by_nas" ? long.Parse(call.Values["unit_id"]) : 0;
                if (call.Method == "set_regenerating") { Queued.Add(id); if (Problem == "mark-lost") throw new HttpRequestException("合成标记回执丢失"); data = SynologyPhotosHttpFixture.List(Queue(id)); }
                else if (call.Method == "regenerate_preview_by_nas") { if (Problem == "nas-lost") throw new HttpRequestException("合成转换回执丢失"); if (Problem == "nas-reject") return Task.FromResult(Reject()); data = new(); }
                else if (call.Method == "restore_from_regenerating") { Queued.Remove(id); if (LostRestore) throw new HttpRequestException("合成恢复回执丢失"); data = new(); }
                else { var entries = Queued.Select(Queue).ToList(); if (QueueProblem == "duplicate" && entries.Count > 0) entries.Add(Queue(Queued.First())); data = SynologyPhotosHttpFixture.List(entries.ToArray()); }
            }
            else if (call.Api.EndsWith("Browse.Item"))
            {
                var id = JsonSerializer.Deserialize<long[]>(call.Values["id"])!.Single(); var photo = Http.PhotoJson(); photo["id"] = id; photo["filename"] = "synthetic" + Extension; photo["filesize"] = Size;
                photo["additional"]!["thumbnail"]!["cache_key"] = Revision; photo["additional"]!["thumbnail"]!["unit_id"] = ThumbnailUnit;
                if (Album is { } album) { photo["owner_user_id"] = album.OwnerUserId; photo["additional"]!["provider_user_id"] = album.ProviderUserId; }
                data = SynologyPhotosHttpFixture.List(photo);
            }
            else if (call.Api.EndsWith("Browse.Folder")) data = new() { ["folder"] = new JsonObject { ["id"] = 3, ["name"] = "/Synthetic", ["parent"] = 1, ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = View, ["manage"] = Manage, ["download"] = Download } } } };
            else if (call.Api.EndsWith("Browse.Album")) data = SynologyPhotosHttpFixture.List(new JsonObject { ["id"] = 41, ["owner_user_id"] = 19, ["type"] = Conditional ? "condition" : "normal", ["freeze_album"] = Frozen });
            else throw new InvalidOperationException(call.Api + ":" + call.Method);
            return Task.FromResult(SynologyPhotosHttpFixture.Json(data));
        }
        public Task<ISynologyPhotoPreviewCompletion> SubscribePhotoPreviewAsync(NasProfile profile, DsmSession session, long unitId, CancellationToken cancellationToken = default)
        { Events.Add("subscribe"); if (Problem == "subscribe-failed") throw new SynologyPhotoException(SynologyPhotoFailure.Media); return Task.FromResult<ISynologyPhotoPreviewCompletion>(new Completion(this, unitId)); }
        private sealed class Completion(Fixture owner, long id) : ISynologyPhotoPreviewCompletion
        {
            public async Task<bool> CompletionAsync(CancellationToken cancellationToken = default)
            {
                owner.Events.Add("event"); owner.EventStarted.TrySetResult();
                if (owner.Problem == "event-disconnected") throw new IOException("合成通知断开");
                var result = owner.HoldEvent ? await owner.ReleaseEvent.Task.WaitAsync(cancellationToken) : owner.Problem != "event-false";
                if (result) { owner.Queued.Remove(id); owner.Revision = "new-preview"; } return result;
            }
            public ValueTask DisposeAsync() { owner.Events.Add("dispose"); return ValueTask.CompletedTask; }
        }
        public Task<SynologyPhotoConvertedPreview> ConvertAsync(string source, string mediaType, CancellationToken cancellationToken = default)
        { Events.Add("convert"); Conversions++; LocalSource = source; Assert.Equal(8, new FileInfo(source).Length); AfterConvert?.Invoke(); if (ConversionFails) throw new SynologyPhotoException(SynologyPhotoFailure.Media); return Task.FromResult(new SynologyPhotoConvertedPreview([1], [2], [3])); }
        public Task<SynologyPhotoWriteReceipt> UploadPhotoPreviewAsync(NasProfile profile, DsmSession session, ApiCapability capability, long unitId, SynologyPhotoConvertedPreview preview, CancellationToken cancellationToken = default)
        { Events.Add("upload"); Assert.Equal(new byte[] { 1 }, preview.Large); Assert.Equal(new byte[] { 2 }, preview.Small); Assert.Equal(new byte[] { 3 }, preview.Medium); if (Problem == "upload-lost") return Task.FromResult(new SynologyPhotoWriteReceipt(SynologyPhotoWriteStatus.Unknown)); if (UploadStatus == SynologyPhotoWriteStatus.Accepted) { Queued.Remove(unitId); Revision = "new-preview"; } return Task.FromResult(new SynologyPhotoWriteReceipt(UploadStatus)); }
        public async Task<SynologyPhotoBinaryResult> DownloadPhotoAsync(NasProfile profile, DsmSession session, SynologyPhotoMediaRequest request, string destination, long? expectedBytes, bool archive, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        { Events.Add("download"); Downloads++; Assert.False(archive); Assert.Equal(8, expectedBytes); await File.WriteAllBytesAsync(destination, new byte[8], cancellationToken); return new("image/jpeg", 8); }
        public Task<JsonObject> CallPhotoJsonAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => Http.Api.CallPhotoJsonAsync(profile, session, capability, requiredVersion, method, parameters, cancellationToken);
        public Task<SynologyPhotoWriteReceipt> WritePhotoAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string> parameters, CancellationToken cancellationToken = default) => Http.Api.WritePhotoAsync(profile, session, capability, requiredVersion, method, parameters, cancellationToken);
        public Uri GetBaseUri(NasProfile profile) => Http.Api.GetBaseUri(profile);
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public void Dispose() => Http.Dispose();
    }
}
