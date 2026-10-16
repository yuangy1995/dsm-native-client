using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed partial class SynologyPhotosManagementTests
{
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task BackgroundClearPersistsOriginalPartialResultBeforeDiscardingTaskEvidence(bool cold)
    {
        using var f = new FileFixture { StatusMode = "over-count" }; var repo = await f.Repository();
        var command = f.Command(SynologyPhotoFileAction.Copy, folders: true);
        var file = await repo.ChangeFilesAsync(Guid.NewGuid(), command); Assert.Equal(SynologyPhotoFileState.PendingReview, file.State);
        if (cold) repo = await f.Repository(f.Store.Clone());
        var source = f.Http.Respond!; var row = SynologyPhotosBackgroundTasksTests.Row(); row["total"] = 12; var controls = 0; var cleared = false;
        f.Http.Respond = async (request, token) =>
        {
            if (request.Method == "list_user_task") return SynologyPhotosHttpFixture.Json(cleared ? SynologyPhotosHttpFixture.List() : SynologyPhotosHttpFixture.List((JsonObject)row.DeepClone()));
            if (request.Method == "abort_task") { controls++; row["status"] = "done"; f.StatusMode = "incomplete"; return SynologyPhotosHttpFixture.Json(new()); }
            if (request.Method == "clear_completed_task")
            {
                var original = Assert.Single(await repo.FileChangesAsync()); Assert.Equal(SynologyPhotoFileState.Partial, original.State); Assert.Equal(11, original.Counts!.Completion);
                controls++; cleared = true; return SynologyPhotosHttpFixture.Json(new());
            }
            return await source(request, token);
        };
        var task = Assert.Single(await repo.BackgroundTasksAsync());
        var stop = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Stop, [task]), true); Assert.Equal(SynologyPhotoChangeState.Completed, stop.State);
        Assert.Equal(SynologyPhotoFileState.PendingReview, Assert.Single(await repo.FileChangesAsync()).State);
        var done = Assert.Single(await repo.BackgroundTasksAsync());
        var clear = await repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Clear, [done]), true);
        Assert.Equal(SynologyPhotoChangeState.Completed, clear.State); Assert.Equal(2, controls); Assert.Single(f.Writes);
        Assert.Equal(SynologyPhotoFileState.Partial, (await repo.ReviewFileChangeAsync(file.Id)).State);
    }
    [Fact]
    public async Task OriginalUnresolvedTaskPreventsClearWithoutBlockingReadOrStop()
    {
        using var f = new FileFixture { StatusMode = "over-count" }; var repo = await f.Repository();
        var file = await repo.ChangeFilesAsync(Guid.NewGuid(), f.Command(SynologyPhotoFileAction.Copy, folders: true));
        var source = f.Http.Respond!; var row = SynologyPhotosBackgroundTasksTests.Row(status: "done"); row["total"] = 12;
        f.Http.Respond = (request, token) => request.Method == "list_user_task" ? Task.FromResult(SynologyPhotosHttpFixture.Json(SynologyPhotosHttpFixture.List((JsonObject)row.DeepClone()))) : source(request, token);
        var task = Assert.Single(await repo.BackgroundTasksAsync());
        var error = await Assert.ThrowsAsync<SynologyPhotoException>(() => repo.ControlBackgroundTasksAsync(Guid.NewGuid(), new(SynologyPhotoBackgroundAction.Clear, [task]), true));
        Assert.Equal(SynologyPhotoFailure.UploadBusy, error.Failure); Assert.Equal(SynologyPhotoFileState.PendingReview, (await repo.ReviewFileChangeAsync(file.Id)).State);
        Assert.DoesNotContain(f.Http.Requests, request => request.Method == "clear_completed_task");
    }
}
