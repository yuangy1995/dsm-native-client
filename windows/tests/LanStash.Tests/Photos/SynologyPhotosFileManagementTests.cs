using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed partial class SynologyPhotosManagementTests
{
    [Theory]
    [InlineData(SynologyPhotoFileAction.Copy, false, false)]
    [InlineData(SynologyPhotoFileAction.Move, false, false)]
    [InlineData(SynologyPhotoFileAction.Delete, false, false)]
    [InlineData(SynologyPhotoFileAction.Copy, true, false)]
    [InlineData(SynologyPhotoFileAction.Move, true, false)]
    [InlineData(SynologyPhotoFileAction.Delete, true, false)]
    [InlineData(SynologyPhotoFileAction.Copy, false, true)]
    [InlineData(SynologyPhotoFileAction.Move, false, true)]
    [InlineData(SynologyPhotoFileAction.Delete, false, true)]
    [InlineData(SynologyPhotoFileAction.Copy, true, true)]
    [InlineData(SynologyPhotoFileAction.Move, true, true)]
    [InlineData(SynologyPhotoFileAction.Delete, true, true)]
    public async Task FileCommandsUseSourceApiExactArraysAndSingleAcceptedTask(SynologyPhotoFileAction action, bool shared, bool folders)
    {
        using var test = new FileFixture(); var repo = await test.Repository(); var command = test.Command(action, shared, folders);
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), command); Assert.Equal(SynologyPhotoFileState.Completed, result.State);
        var write = Assert.Single(test.Writes); Assert.Equal(shared ? "SYNO.FotoTeam.BackgroundTask.File" : "SYNO.Foto.BackgroundTask.File", write.Api);
        Assert.Equal(HttpMethod.Post, write.HttpMethod); Assert.Equal(1, write.Version); Assert.Equal("[7]", write.Values["item_id"]); Assert.Equal(folders ? "[4]" : "[]", write.Values["folder_id"]);
        if (action != SynologyPhotoFileAction.Delete) { Assert.Equal("9", write.Values["target_folder_id"]); Assert.Equal("\"skip\"", write.Values["action"]); }
        if (action == SynologyPhotoFileAction.Move)
        {
            var extra = JsonNode.Parse(JsonSerializer.Deserialize<string>(write.Values["extra_info"])!)!;
            Assert.Equal(2, extra["version"]!.GetValue<int>()); Assert.Equal(shared ? "shared_space" : "personal_space", extra["source_library"]!.GetValue<string>());
            Assert.Equal(folders ? "[3]" : null, extra["source_folder_ids"]?.ToJsonString());
        }
        else Assert.False(write.Values.ContainsKey("extra_info"));
        Assert.All(test.Http.Requests.Where(request => request.Method == "get_status"), request =>
        { Assert.Equal("SYNO.Foto.BackgroundTask.Info", request.Api); Assert.Equal("[91]", request.Values["id"]); });
        Assert.DoesNotContain(test.Http.Requests, request => request.Api.EndsWith("Browse.Item", StringComparison.Ordinal) && request.Values.ContainsKey("additional"));
        var cold = await test.Repository(test.Store.Clone()); await cold.ContinueFileChangeAsync(result.Id); await cold.ChangeFilesAsync(result.Id, command); Assert.Single(test.Writes);
        Assert.Equal(folders ? 12 : 1, result.Counts!.Total);
        var record = Encoding.UTF8.GetString(Assert.Single(test.Store.Records).Value);
        Assert.DoesNotContain("synthetic-sid", record); Assert.DoesNotContain("synthetic-token", record); Assert.DoesNotContain("nas.invalid", record);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task CrossSourceCopyUsesExactKnownTaskToFillMissingTargetReceipt(bool fromShared)
    {
        using var test = new FileFixture { OmitTargetReceipt = true }; var repo = await test.Repository(); var command = test.Command(SynologyPhotoFileAction.Copy, fromShared, false, cross: true);
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), command); Assert.Equal(SynologyPhotoFileState.Completed, result.State);
        Assert.Single(test.Http.Requests, request => request.Method == "list_user_task"); Assert.Single(test.Writes);
        Assert.DoesNotContain(test.Http.Requests, request => request.Api == "SYNO.FotoTeam.BackgroundTask.Info");
    }
    [Theory]
    [InlineData(SynologyPhotoFileAction.Copy)]
    [InlineData(SynologyPhotoFileAction.Move)]
    [InlineData(SynologyPhotoFileAction.Delete)]
    public async Task LostFileReceiptCannotClaimChangedObjectsAndColdContinueNeverWrites(SynologyPhotoFileAction action)
    {
        using var test = new FileFixture { Drop = true }; var repo = await test.Repository(); var command = test.Command(action, false, true);
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), command); var cold = await test.Repository(test.Store.Clone());
        result = await cold.ContinueFileChangeAsync(result.Id); Assert.Equal(SynologyPhotoFileState.PendingReview, result.State);
        Assert.Equal(SynologyPhotoFileState.PendingReview, (await cold.CancelFileChangeAsync(result.Id)).State); Assert.Single(test.Writes);
        Assert.DoesNotContain(test.Http.Requests, request => request.Method is "get_status" or "list_user_task");
    }
    [Theory]
    [InlineData("wrong-id")]
    [InlineData("duplicate")]
    [InlineData("negative")]
    [InlineData("over-count")]
    [InlineData("unexpected-overwrite")]
    [InlineData("missing-overwrite")]
    public async Task InvalidFileStatusRetainsUnknownAndDoesNotRepeat(string mode)
    {
        using var test = new FileFixture { StatusMode = mode }; var repo = await test.Repository();
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), test.Command(SynologyPhotoFileAction.Copy, false, true));
        Assert.Equal(SynologyPhotoFileState.PendingReview, result.State); await repo.ContinueFileChangeAsync(result.Id); Assert.Single(test.Writes);
        test.StatusMode = null; Assert.Equal(SynologyPhotoFileState.Completed, (await repo.ReviewFileChangeAsync(result.Id)).State);
    }
    [Theory]
    [InlineData("error")]
    [InlineData("skip")]
    [InlineData("incomplete")]
    public async Task PartialFileTaskKeepsRealCountsAndDoesNotInferPerFolderSuccess(string mode)
    {
        using var test = new FileFixture { StatusMode = mode }; var repo = await test.Repository();
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), test.Command(SynologyPhotoFileAction.Delete, false, true));
        Assert.Equal(SynologyPhotoFileState.Partial, result.State); Assert.False(result.CanContinue); Assert.NotNull(result.Counts);
        Assert.Equal(mode == "incomplete" ? 11 : 12, result.Counts.Completion); Assert.Equal(mode == "error" ? 11 : result.Counts.Completion, result.Counts.Succeeded);
        await repo.ContinueFileChangeAsync(result.Id); Assert.Single(test.Writes);
        Assert.DoesNotContain(test.Http.Requests, request => request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal) && request.Method == "list");
    }
    [Theory]
    [InlineData("retained")]
    [InlineData("duplicate-page")]
    [InlineData("wrong-parent")]
    public async Task FolderDeletionNeedsFullValidParentListingAndAbsentOriginals(string mode)
    {
        using var test = new FileFixture { ListingMode = mode }; var repo = await test.Repository();
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), test.Command(SynologyPhotoFileAction.Delete, false, true));
        Assert.Equal(SynologyPhotoFileState.PendingReview, result.State);
        test.ListingMode = null; Assert.Equal(SynologyPhotoFileState.Completed, (await repo.ReviewFileChangeAsync(result.Id)).State); Assert.Single(test.Writes);
        Assert.Contains(test.Http.Requests, request => request.Method == "list" && request.Values.GetValueOrDefault("offset") == "100");
    }
    [Fact]
    public async Task SingleDeletePreservesObservedStatusWithoutOverwriteButRequiresAbsenceAndParentAccess()
    {
        using var test = new FileFixture { OmitDeleteOverwrite = true, Apply = false }; var repo = await test.Repository(); var command = test.Command(SynologyPhotoFileAction.Delete);
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), command); Assert.Equal(SynologyPhotoFileState.PendingReview, result.State);
        test.Applied = true; test.View = false; Assert.Equal(SynologyPhotoFileState.PendingReview, (await repo.ReviewFileChangeAsync(result.Id)).State);
        test.View = true; Assert.Equal(SynologyPhotoFileState.Completed, (await repo.ReviewFileChangeAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task FileSafetyIsSpecificAndDoesNotDisableOrdinaryCopy()
    {
        using var test = new FileFixture(); var repo = await test.Repository(safety: new());
        var delete = test.Command(SynologyPhotoFileAction.Delete, false, true);
        Assert.Equal(SynologyPhotoFailure.DeletionUnverified, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ChangeFilesAsync(Guid.NewGuid(), delete))).Failure);
        var move = test.Command(SynologyPhotoFileAction.Move, false, false, cross: true);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ChangeFilesAsync(Guid.NewGuid(), move));
        var copy = test.Command(SynologyPhotoFileAction.Copy);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ChangeFilesAsync(Guid.NewGuid(), copy with { Duplicate = SynologyPhotoFileDuplicate.Overwrite }));
        Assert.Empty(test.Writes); Assert.Equal(SynologyPhotoFileState.Completed, (await repo.ChangeFilesAsync(Guid.NewGuid(), copy)).State);
    }
    [Fact]
    public async Task InvalidMixedSelectionAndDestinationNeverSubmit()
    {
        using var test = new FileFixture(); var repo = await test.Repository(); var command = test.Command(SynologyPhotoFileAction.Move, false, true);
        var invalid = new[] { command with { Folders = [new(command.Space, 1, 0, "/")] },
            command with { Folders = [command.Folders[0], command.Folders[0]] }, command with { Photos = [command.Photos[0] with { FolderId = 1 }] },
            command with { Photos = [command.Photos[0] with { AlbumContext = new(8, 19, 19) }] },
            command with { Destination = new(command.Space, 3, 1, "/Source") }, command with { Destination = command.Folders[0] },
            command with { Destination = new(command.Space, 5, 4, "/Source/Child/Subfolder") },
            test.Command(SynologyPhotoFileAction.Move, true, false, cross: true) };
        foreach (var item in invalid) await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ChangeFilesAsync(Guid.NewGuid(), item));
        Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task SharedCopyAllowsViewDownloadButMoveRequiresManagementAndAlbumContributorIsNotOwner()
    {
        using var test = new FileFixture { Manage = false }; test.Http.TeamPermission = "entry"; var repo = await test.Repository();
        var move = test.Command(SynologyPhotoFileAction.Move, true);
        Assert.Equal(SynologyPhotoFailure.Permission, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ChangeFilesAsync(Guid.NewGuid(), move))).Failure);
        var copy = test.Command(SynologyPhotoFileAction.Copy, true); Assert.Equal(SynologyPhotoFileState.Completed, (await repo.ChangeFilesAsync(Guid.NewGuid(), copy)).State);
        var personal = test.Command(SynologyPhotoFileAction.Copy) with { Photos = [test.Http.Photo with { AlbumContext = new(8, 29, 19) }] };
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ChangeFilesAsync(Guid.NewGuid(), personal)); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task KnownFileRejectionRequiresExplicitContinueAndCannotReplaceOriginalCommand()
    {
        using var test = new FileFixture { Reject = true }; var repo = await test.Repository(); var command = test.Command(SynologyPhotoFileAction.Copy);
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), command); Assert.Equal(SynologyPhotoFileState.Failed, result.State);
        test.Reject = false; var cold = await test.Repository(test.Store.Clone()); await cold.ChangeFilesAsync(result.Id, command); Assert.Single(test.Writes);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cold.ChangeFilesAsync(result.Id, command with { Action = SynologyPhotoFileAction.Move }));
        Assert.Equal(SynologyPhotoFileState.Completed, (await cold.ContinueFileChangeAsync(result.Id)).State); Assert.Equal(2, test.Writes.Count);
    }
    [Fact]
    public async Task FileCheckpointFailurePreventsWriteAndColdRestoreNeverReplaysSubmitting()
    {
        using var test = new FileFixture(); var repo = await test.Repository(); var command = test.Command(SynologyPhotoFileAction.Copy);
        test.Store.OnSave = count => count == 2 ? Task.FromException(new IOException()) : Task.CompletedTask;
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ChangeFilesAsync(Guid.NewGuid(), command)); Assert.Empty(test.Writes);
        var cold = await test.Repository(test.Store.Clone()); var result = Assert.Single(await cold.FileChangesAsync());
        Assert.Equal(SynologyPhotoFileState.PendingReview, result.State); await cold.ContinueFileChangeAsync(result.Id); Assert.Empty(test.Writes);
        test.Http.UserId = 29; var other = await test.Repository(test.Store.Clone()); Assert.Empty(await other.FileChangesAsync());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => other.ReviewFileChangeAsync(result.Id));
    }
    [Fact]
    public async Task PendingFileChangeBlocksMetadataFolderRenameAndDuplicateNewOperation()
    {
        using var test = new FileFixture { Drop = true }; var repo = await test.Repository(); var command = test.Command(SynologyPhotoFileAction.Copy, false, true);
        await repo.ChangeFilesAsync(Guid.NewGuid(), command);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ChangeFilesAsync(Guid.NewGuid(), command));
        var photo = test.Http.Photo with { Rating = 1 };
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditAsync(Guid.NewGuid(), new(SynologyPhotoEditKind.Rating, [photo]) { Value = 2 }))).Failure);
        var folder = new SynologyPhotoFolder(SynologyPhotoSpace.Personal, 3, 1, "/Source");
        Assert.Equal(SynologyPhotoFailure.UploadBusy, (await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.EditFolderAsync(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Rename, folder) { Name = "Changed" }))).Failure);
        Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FreshFilePreflightRejectsRevokedPermissionOrChangedOriginalAfterCheckpoint(bool changed)
    {
        using var test = new FileFixture(); var repo = await test.Repository(); var command = test.Command(SynologyPhotoFileAction.Copy);
        test.Store.OnSave = count => { if (count == 1) { if (changed) test.ChangedPhoto = true; else test.Manage = false; } return Task.CompletedTask; };
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), command); Assert.Equal(SynologyPhotoFileState.Failed, result.State);
        Assert.Equal(changed ? SynologyPhotoFailure.TargetChanged : SynologyPhotoFailure.Permission, result.Failure); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task CancellationBeforeSubmissionLeavesOnlyExplicitlyCancellableReadyTask()
    {
        using var test = new FileFixture(); var repo = await test.Repository(); using var source = new CancellationTokenSource();
        test.Store.OnSave = count => { if (count == 1) source.Cancel(); return Task.CompletedTask; };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => repo.ChangeFilesAsync(Guid.NewGuid(), test.Command(SynologyPhotoFileAction.Copy), source.Token));
        var result = Assert.Single(await repo.FileChangesAsync()); Assert.Equal(SynologyPhotoFileState.Ready, result.State);
        Assert.Equal(SynologyPhotoFileState.Cancelled, (await repo.CancelFileChangeAsync(result.Id)).State); Assert.Empty(test.Writes);
    }
    [Fact]
    public async Task ConcurrentClicksAndChangedAccountCannotPublishLateFileSuccess()
    {
        using var test = new FileFixture(); var repo = await test.Repository(); var command = test.Command(SynologyPhotoFileAction.Copy); var id = Guid.NewGuid();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        test.BeforeWrite = async () => { entered.SetResult(); await release.Task; };
        var first = repo.ChangeFilesAsync(id, command); await entered.Task;
        var second = await repo.ChangeFilesAsync(id, command); Assert.True(second.Running); Assert.Equal(SynologyPhotoFileState.Submitting, second.State);
        test.Http.UserId = 29; await repo.AccessAsync(); release.SetResult();
        Assert.Equal(SynologyPhotoFileState.PendingReview, (await first).State); Assert.Single(test.Writes); Assert.Empty(await repo.FileChangesAsync());
        await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ReviewFileChangeAsync(id));
    }
    [Theory]
    [InlineData("target")]
    [InlineData("owner")]
    [InlineData("total")]
    [InlineData("task")]
    public async Task CrossSourceReceiptFallbackMustMatchKnownTaskTargetOwnerAndTotal(string mismatch)
    {
        using var test = new FileFixture { OmitTargetReceipt = true, MetadataMismatch = mismatch }; var repo = await test.Repository();
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), test.Command(SynologyPhotoFileAction.Copy, false, false, cross: true));
        Assert.Equal(SynologyPhotoFileState.PendingReview, result.State); Assert.DoesNotContain(test.Http.Requests, request => request.Method == "get_status");
        test.MetadataMismatch = null; Assert.Equal(SynologyPhotoFileState.Completed, (await repo.ReviewFileChangeAsync(result.Id)).State); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task CrossSourceSameNumericFolderIdDoesNotBecomeSelfDestination()
    {
        using var test = new FileFixture(); var repo = await test.Repository();
        var command = test.Command(SynologyPhotoFileAction.Copy, false, false, cross: true) with { Destination = new(SynologyPhotoSpace.Shared, 3, 1, "/Source") };
        test.SetCommand(command); Assert.Equal(SynologyPhotoFileState.Completed, (await repo.ChangeFilesAsync(Guid.NewGuid(), command)).State); Assert.Single(test.Writes);
    }
    [Theory]
    [InlineData("target")]
    [InlineData("owner")]
    [InlineData("total")]
    public async Task ExplicitlyContradictoryReceiptCannotBecomeSuccessFromLaterGenericStatus(string mismatch)
    {
        using var test = new FileFixture { MetadataMismatch = mismatch }; var repo = await test.Repository();
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), test.Command(SynologyPhotoFileAction.Copy));
        Assert.Equal(SynologyPhotoFileState.PendingReview, result.State); test.MetadataMismatch = null;
        var cold = await test.Repository(test.Store.Clone()); Assert.Equal(SynologyPhotoFileState.PendingReview, (await cold.ContinueFileChangeAsync(result.Id)).State);
        Assert.DoesNotContain(test.Http.Requests, request => request.Method == "get_status"); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task FolderDeletionWithoutReportedTotalUsesTaskAndAbsenceWithoutInventingCount()
    {
        using var test = new FileFixture { OmitTotal = true }; var repo = await test.Repository();
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), test.Command(SynologyPhotoFileAction.Delete, false, true));
        Assert.Equal(SynologyPhotoFileState.Completed, result.State); Assert.Null(result.Counts); Assert.Single(test.Writes);
    }
    [Fact]
    public async Task Error117KeepsUnknownAndCannotBeExplicitlyResubmitted()
    {
        using var test = new FileFixture { Reject = true, RejectionCode = 117 }; var repo = await test.Repository();
        var result = await repo.ChangeFilesAsync(Guid.NewGuid(), test.Command(SynologyPhotoFileAction.Copy));
        Assert.Equal(SynologyPhotoFileState.PendingReview, result.State); Assert.False(result.CanContinue);
        await repo.ContinueFileChangeAsync(result.Id); Assert.Single(test.Writes);
    }
    private sealed class FileFixture : IDisposable
    {
        internal readonly SynologyPhotosHttpFixture Http = new() { TeamEnabled = true, TeamPermission = "management" };
        internal readonly MemoryStore Store = new();
        internal readonly List<SynologyPhotosHttpFixture.Request> Writes = [];
        internal bool Drop, Reject, OmitTargetReceipt, OmitDeleteOverwrite, OmitTotal, ChangedPhoto, Applied, Apply = true, View = true, Manage = true;
        internal int RejectionCode = 105;
        internal Func<Task>? BeforeWrite;
        internal string? StatusMode, ListingMode, MetadataMismatch;
        private SynologyPhotoFileCommand? _command;
        internal FileFixture() { Http.Respond = Respond; }
        internal async Task<SynologyPhotosRepository> Repository(MemoryStore? store = null, SynologyPhotoFileSafety? safety = null)
        { var repo = new SynologyPhotosRepository(Http.Profile, Http.Session, Http.Api, Http.Capabilities, deletionEnabled: true, managementStore: store ?? Store, fileSafety: safety ?? new(true, true, true)); await repo.AccessAsync(); return repo; }
        internal SynologyPhotoFileCommand Command(SynologyPhotoFileAction action, bool shared = false, bool folders = false, bool cross = false)
        {
            var source = shared ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal; var target = cross ? shared ? SynologyPhotoSpace.Personal : SynologyPhotoSpace.Shared : source;
            _command = new(action, source, [Http.Photo with { Id = Http.Photo.Id with { Space = source } }], folders ? [new(source, 4, 3, "/Source/Child")] : [])
            { Destination = action == SynologyPhotoFileAction.Delete ? null : new(target, 9, 1, "/Destination") };
            return _command;
        }
        private long Total => _command!.Folders.Count > 0 ? 12 : 1;
        internal void SetCommand(SynologyPhotoFileCommand command) => _command = command;
        private JsonObject TaskInfo(bool full) => new() { ["id"] = full && MetadataMismatch == "task" ? 92 : 91, ["total"] = OmitTotal ? null : full && MetadataMismatch == "total" ? Total + 1 : Total,
            ["target_folder"] = full && _command!.Destination is { } target ? new JsonObject { ["id"] = MetadataMismatch == "target" ? 99 : target.Id,
                ["owner_user_id"] = MetadataMismatch == "owner" ? 99 : target.Space == SynologyPhotoSpace.Shared ? 0 : Http.UserId } : null };
        private JsonObject Folder(long id)
        {
            var moved = Applied && _command?.Action == SynologyPhotoFileAction.Move;
            return new() { ["id"] = id, ["parent"] = id == 1 ? 0 : id == 4 ? moved ? 9 : 3 : 1,
                ["name"] = id == 1 ? "/" : id == 3 ? "/Source" : id == 4 ? moved ? "/Destination/Child" : "/Source/Child" : "/Destination",
                ["additional"] = new JsonObject { ["access_permission"] = new JsonObject { ["view"] = View, ["manage"] = id == 9 || Manage, ["upload"] = true, ["download"] = true } } };
        }
        private async Task<HttpResponseMessage> Respond(SynologyPhotosHttpFixture.Request request, CancellationToken token)
        {
            JsonObject data;
            if (request.Api.EndsWith("BackgroundTask.File", StringComparison.Ordinal))
            {
                Writes.Add(request);
                if (BeforeWrite is not null) await BeforeWrite();
                if (Reject) return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent($"{{\"success\":false,\"error\":{{\"code\":{RejectionCode}}}}}", Encoding.UTF8, "application/json") };
                Applied = Apply; if (Drop) throw new IOException(); data = new() { ["task_info"] = TaskInfo(!OmitTargetReceipt) };
            }
            else if (request.Method == "list_user_task") data = SynologyPhotosHttpFixture.List(TaskInfo(true));
            else if (request.Method == "get_status")
            {
                var status = new JsonObject { ["id"] = StatusMode == "wrong-id" ? 92 : 91, ["status"] = "done", ["total"] = Total,
                    ["completion"] = StatusMode == "negative" ? -1 : StatusMode == "over-count" ? Total + 1 : StatusMode == "incomplete" ? Total - 1 : Total,
                    ["error"] = StatusMode == "error" ? 1 : 0, ["skip"] = StatusMode == "skip" ? 1 : 0, ["overwrite"] = StatusMode == "unexpected-overwrite" ? 1 : 0 };
                if (StatusMode == "missing-overwrite" || OmitDeleteOverwrite) status.Remove("overwrite");
                if (OmitTotal) status.Remove("total");
                data = StatusMode == "duplicate" ? SynologyPhotosHttpFixture.List(status, (JsonObject)status.DeepClone()) : SynologyPhotosHttpFixture.List(status);
            }
            else if (request.Api.EndsWith("Browse.Item", StringComparison.Ordinal))
            {
                var photo = Http.PhotoJson(); photo["additional"] = new JsonObject { ["exif"] = "deliberately-not-a-detail-object" };
                if (ChangedPhoto) photo["filesize"] = 9;
                if (Applied && _command?.Action == SynologyPhotoFileAction.Move) photo["folder_id"] = 9;
                data = Applied && _command?.Action == SynologyPhotoFileAction.Delete ? SynologyPhotosHttpFixture.List() : SynologyPhotosHttpFixture.List(photo);
            }
            else if (request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal) && request.Method == "list")
            {
                var offset = int.Parse(request.Values["offset"]);
                var list = offset == 0 || ListingMode == "duplicate-page" ? Enumerable.Range(100, 100).Select(id => new JsonObject { ["id"] = id, ["parent"] = ListingMode == "wrong-parent" ? 2 : 3, ["name"] = $"/Source/item{id}" }).ToArray() :
                    ListingMode == "retained" ? [Folder(4)] : Array.Empty<JsonObject>();
                data = SynologyPhotosHttpFixture.List(list);
            }
            else if (request.Api.EndsWith("Browse.Folder", StringComparison.Ordinal)) data = new() { ["folder"] = Folder(long.Parse(request.Values["id"])) };
            else throw new InvalidOperationException(request.Api);
            return SynologyPhotosHttpFixture.Json(data);
        }
        public void Dispose() => Http.Dispose();
    }
}
