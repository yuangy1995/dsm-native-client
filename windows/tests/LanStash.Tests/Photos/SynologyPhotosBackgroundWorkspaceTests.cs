using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosBackgroundWorkspaceTests
{
    private static SynologyPhotosTestRepository Repository() => new()
    {
        Spaces = [SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared],
        ReadFolder = (id, space) => Task.FromResult(new SynologyPhotoFolder(space, id, id == 1 ? 0 : 1, id == 1 ? "/" : "/synthetic")),
        ReadTaskLocation = (task, _) => Task.FromResult<IReadOnlyList<SynologyPhotoFolder>>([new(task.TargetSpace!.Value, 1, 0, "/"), new(task.TargetSpace.Value, 9, 1, "/synthetic")])
    };
    private static SynologyPhotoBackgroundTask CreateTask(SynologyPhotosTestRepository repo, SynologyPhotoSpace space) => new(repo.ProfileId, 19, 91, "copy", SynologyPhotoBackgroundStatus.Done, 1, 1, 0, 0, 0, 1, 9, space == SynologyPhotoSpace.Shared ? 0 : 19);
    [Theory]
    [InlineData(SynologyPhotoSpace.Personal)][InlineData(SynologyPhotoSpace.Shared)]
    public async System.Threading.Tasks.Task TaskNavigationUsesVerifiedSourceAndFullBreadcrumb(SynologyPhotoSpace space)
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await model.LoadIfNeededAsync();
        await model.OpenBackgroundTaskLocationAsync(CreateTask(repo, space));
        Assert.Equal(space, model.SelectedSpace); Assert.Equal(SynologyPhotosSection.Folders, model.Section); Assert.Equal(new long[] { 1, 9 }, model.FolderHistory.Select(value => value.Id));
        Assert.Equal(9, Assert.IsType<SynologyPhotoQuery.Folder>(repo.Calls.Last().Query).Id);
    }
    [Theory]
    [InlineData(false)][InlineData(true)]
    public async System.Threading.Tasks.Task LateTaskLocationCannotReplaceNavigationOrDisposedWorkspace(bool dispose)
    {
        var repo = Repository(); var source = repo.ReadTaskLocation!; var wait = new TaskCompletionSource<IReadOnlyList<SynologyPhotoFolder>>(TaskCreationOptions.RunContinuationsAsynchronously);
        repo.ReadTaskLocation = (_, _) => wait.Task; using var model = new SynologyPhotosWorkspace(repo); await model.LoadIfNeededAsync();
        var task = CreateTask(repo, SynologyPhotoSpace.Shared); var opening = model.OpenBackgroundTaskLocationAsync(task);
        if (dispose) model.Dispose(); else await model.SelectSectionAsync(SynologyPhotosSection.Albums);
        wait.SetResult(await source(task, default)); await opening; Assert.Equal(SynologyPhotoSpace.Personal, model.SelectedSpace);
        if (!dispose) Assert.Equal(SynologyPhotosSection.Albums, model.Section);
    }
    [Fact]
    public async System.Threading.Tasks.Task PermissionFailureKeepsCurrentMonthAndSelection()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await model.LoadIfNeededAsync(); var month = model.SelectedMonth; var photos = model.Items.ToArray();
        repo.ReadTaskLocation = (_, _) => throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        await Assert.ThrowsAsync<SynologyPhotoException>(() => model.OpenBackgroundTaskLocationAsync(CreateTask(repo, SynologyPhotoSpace.Shared)));
        Assert.Equal(month, model.SelectedMonth); Assert.Equal(photos, model.Items); Assert.Equal(SynologyPhotosSection.Timeline, model.Section);
    }
}
