using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosPreviewWorkspaceTests
{
    [Fact]
    public async Task CompletedPreviewsRefreshActualRevisionWithoutReloadingMonthOrLosingDetails()
    {
        var repo = new SynologyPhotosTestRepository(); using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync(); await model.JumpToMonthAsync(new(2026, 8));
        var original = model.Items[0]; model.Items[0] = original with { Rating = 4, Description = "Current description" };
        repo.Detail = (photo, _) => Task.FromResult(photo with { Thumbnail = new(101, "latest-preview") }); await model.Preview.OpenAsync(original);
        var reads = repo.Calls.Count; var month = model.SelectedMonth; var result = Result(original);
        Assert.True(await model.ApplyPreviewGenerationAsync(result)); Assert.Equal(month, model.SelectedMonth); Assert.Equal(reads, repo.Calls.Count);
        Assert.Equal("latest-preview", model.Items[0].Thumbnail!.Revision); Assert.Equal(4, model.Items[0].Rating); Assert.Equal("Current description", model.Items[0].Description);
        Assert.Equal("latest-preview", model.Preview.Photo!.Thumbnail!.Revision); Assert.False(await model.ApplyPreviewGenerationAsync(result));
    }
    [Fact]
    public async Task NavigationWhileRefreshingIgnoresOldResult()
    {
        var repo = new SynologyPhotosTestRepository { Spaces = [SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared] }; using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync();
        var original = model.Items[0]; var gate = new TaskCompletionSource<SynologyPhoto>(TaskCreationOptions.RunContinuationsAsynchronously); repo.Detail = (_, _) => gate.Task;
        var applying = model.ApplyPreviewGenerationAsync(Result(original)); await model.SelectSpaceAsync(SynologyPhotoSpace.Shared); gate.SetResult(original with { Thumbnail = new(101, "late") });
        Assert.False(await applying); Assert.All(model.Items, photo => Assert.Equal(SynologyPhotoSpace.Shared, photo.Id.Space)); Assert.Null(model.Preview.Photo);
    }
    [Fact]
    public async Task NewOriginalIdentityCannotBeReplacedByHistory()
    {
        var repo = new SynologyPhotosTestRepository(); using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync(); var photo = model.Items[0];
        repo.Detail = (value, _) => Task.FromResult(value with { SizeBytes = value.SizeBytes + 1, Thumbnail = new(101, "other") });
        Assert.False(await model.ApplyPreviewGenerationAsync(Result(photo))); Assert.Equal(photo, model.Items[0]);
    }
    [Fact]
    public async Task PendingTaskNeverTriggersPreviewRefresh()
    {
        var repo = new SynologyPhotosTestRepository(); using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync();
        repo.Detail = (_, _) => throw new InvalidOperationException("未知任务不应刷新预览"); var original = model.Items[0];
        Assert.False(await model.ApplyPreviewGenerationAsync(new(Guid.NewGuid(), false, [new(original, SynologyPhotoChangeState.PendingReview)], false, false)));
    }
    private static SynologyPhotoPreviewGeneration Result(SynologyPhoto photo) => new(Guid.NewGuid(), false,
        [new(photo, SynologyPhotoChangeState.Completed, photo with { Thumbnail = new(101, "old-task-preview") })], false, false);
}
