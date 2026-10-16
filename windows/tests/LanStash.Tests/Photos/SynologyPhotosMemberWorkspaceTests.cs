using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosMemberWorkspaceTests
{
    private static SynologyPhotoSettingsChange Result(SynologyPhotosTestRepository repo, SynologyPhotoChangeState state = SynologyPhotoChangeState.Completed, SynologyPhotoSharedRole role = SynologyPhotoSharedRole.Entry) =>
        new(Guid.NewGuid(), null, state, false) { HasMemberChanges = true, SharedResult = new(repo.ProfileId, 19, true, true, role, false, false, false, false, false, false, false, false) };
    [Fact]
    public async Task PersonalHistoryPreviewAndPhotosRemainUntouched()
    {
        var repo = new SynologyPhotosTestRepository(); using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync(); await model.JumpToMonthAsync(new(2026,8));
        var photos = model.Items.ToArray(); var month = model.SelectedMonth; var calls = repo.Calls.Count; await model.Preview.OpenAsync(photos[0]);
        model.BeginSharedMemberChange(); await model.ApplySettingsChangeAsync(Result(repo));
        Assert.Equal(photos, model.Items); Assert.Equal(month, model.SelectedMonth); Assert.Equal(calls, repo.Calls.Count); Assert.NotNull(model.Preview.Photo);
    }
    [Theory]
    [InlineData(SynologyPhotoChangeState.Completed)][InlineData(SynologyPhotoChangeState.Failed)]
    public async Task SharedWindowClearsImmediatelyAndReloadsSameHistoricalQuery(SynologyPhotoChangeState state)
    {
        var repo = new SynologyPhotosTestRepository { Spaces = [SynologyPhotoSpace.Shared], CanManageSharedSpace = true };
        using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync(); await model.JumpToMonthAsync(new(2026,8)); await model.Preview.OpenAsync(model.Items[0]);
        var query = repo.Calls[^1].Query; var month = model.SelectedMonth; model.BeginSharedMemberChange(); Assert.Empty(model.Items); Assert.Null(model.Preview.Photo); Assert.True(model.NeedsChangesRefresh);
        await model.ApplySettingsChangeAsync(Result(repo, state)); Assert.NotEmpty(model.Items); Assert.Equal(query, repo.Calls[^1].Query); Assert.Equal(month, model.SelectedMonth); Assert.False(model.CanManageSharedSpace);
    }
    [Fact]
    public async Task LostSharedAccessExitsOldSourceWithoutGuessingGroupMembership()
    {
        var repo = new SynologyPhotosTestRepository { Spaces = [SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared], CanManageSharedSpace = true }; using var model = new SynologyPhotosWorkspace(repo);
        await model.RefreshAsync(); await model.SelectSpaceAsync(SynologyPhotoSpace.Shared); model.BeginSharedMemberChange(); repo.Spaces = [SynologyPhotoSpace.Personal]; repo.CanManageSharedSpace = false;
        await model.ApplySettingsChangeAsync(Result(repo, role: SynologyPhotoSharedRole.None));
        Assert.Equal(SynologyPhotoSpace.Personal, model.SelectedSpace); Assert.All(model.Items, x => Assert.Equal(SynologyPhotoSpace.Personal, x.Id.Space)); Assert.False(model.CanManageSharedSpace);
    }
    [Fact]
    public async Task LateOldPagingCannotReturnAfterPermissionChange()
    {
        var repo = new SynologyPhotosTestRepository { Spaces = [SynologyPhotoSpace.Shared] }; var gate = new TaskCompletionSource<SynologyPhotoPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repo.Read = (query, offset, _) => offset == 0 ? Task.FromResult(new SynologyPhotoPage(Enumerable.Range(1,100).Select(id => repo.Photo(id, space: query.Space)).ToArray(),0,100,true)) : gate.Task;
        using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync(); var late = model.LoadNextAsync(); model.BeginSharedMemberChange();
        repo.Read = (query, offset, _) => Task.FromResult(new SynologyPhotoPage([repo.Photo(5, space: query.Space)], 0,1,false));
        await model.ApplySettingsChangeAsync(Result(repo)); gate.SetResult(new([repo.Photo(999, space: SynologyPhotoSpace.Shared)],100,101,false)); await late;
        Assert.Equal(5, Assert.Single(model.Items).Id.ItemId);
    }
    [Fact]
    public async Task PendingOrForeignResultCannotRestoreOldPhotosAndCompletedIsAppliedOnce()
    {
        var repo = new SynologyPhotosTestRepository { Spaces = [SynologyPhotoSpace.Shared] }; using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync(); model.BeginSharedMemberChange();
        var result = Result(repo); await model.ApplySettingsChangeAsync(result with { SharedResult = result.SharedResult! with { ProfileId = Guid.NewGuid() } }); Assert.Empty(model.Items);
        await model.ApplySettingsChangeAsync(result with { State = SynologyPhotoChangeState.PendingReview, SharedResult = null }); Assert.Empty(model.Items);
        await model.ApplySettingsChangeAsync(result); Assert.NotEmpty(model.Items); var calls = repo.Calls.Count;
        await model.ApplySettingsChangeAsync(result); Assert.Equal(calls, repo.Calls.Count);
    }
    [Fact]
    public async Task FailedRefreshKeepsOldPhotosClearedAndAllowsManualRetry()
    {
        var repo = new SynologyPhotosTestRepository { Spaces = [SynologyPhotoSpace.Shared] }; using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync(); model.BeginSharedMemberChange();
        repo.Read = (_,_,_) => throw new IOException(); await model.ApplySettingsChangeAsync(Result(repo)); Assert.Empty(model.Items); Assert.True(model.NeedsChangesRefresh); Assert.NotNull(model.ErrorKey);
        repo.Read = null; await model.LoadNextAsync(); Assert.NotEmpty(model.Items); Assert.False(model.NeedsChangesRefresh);
    }
}
