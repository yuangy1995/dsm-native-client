using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosFileWorkspaceTests
{
    private static SynologyPhotoFileChange Change(SynologyPhotoFileAction action, SynologyPhoto photo, IReadOnlyList<SynologyPhotoFolder>? folders = null) =>
        new(Guid.NewGuid(), new(action, photo.Id.Space, [photo], folders ?? [])
        { Destination = action == SynologyPhotoFileAction.Delete ? null : new(photo.Id.Space, 9, 1, "/Destination") }, SynologyPhotoFileState.Completed, null, null, false, false);
    [Fact]
    public async Task DeleteAdjustsRawOffsetAndRejectsInflightOldPageWithoutResettingMonth()
    {
        var repo = new SynologyPhotosTestRepository(); var delayed = new TaskCompletionSource<SynologyPhotoPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repo.Read = (_, offset, _) => offset == 0 ? Task.FromResult(new SynologyPhotoPage(Enumerable.Range(1, 100).Select(id => repo.Photo(id)).ToArray(), 0, 100, true)) : delayed.Task;
        using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync(); var month = model.Months.Last(); await model.JumpToMonthAsync(month);
        var photo = model.Items[0]; var next = model.LoadNextAsync(); var result = Change(SynologyPhotoFileAction.Delete, photo); await model.ApplyFileChangeAsync(result);
        delayed.SetResult(new([repo.Photo(101)], 100, 101, false)); await next;
        Assert.Equal(99, model.Items.Count); Assert.DoesNotContain(model.Items, item => item.Id.ItemId == 101); Assert.Equal(month, model.SelectedMonth);
        repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([repo.Photo(101)], offset, offset + 1, false));
        await model.ApplyFileChangeAsync(result); await model.LoadNextAsync(); Assert.Equal(99, repo.Calls.Last().Offset);
        Assert.Equal(100, model.Items.Count); Assert.Equal(month, model.SelectedMonth);
    }
    [Fact]
    public async Task RemovingPhotoAddedFromPreviousMonthDoesNotReduceCurrentPageOffset()
    {
        var repo = new SynologyPhotosTestRepository();
        repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage(Enumerable.Range(1, 100).Select(id => repo.Photo(id)).ToArray(), offset, offset + 100, true));
        using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync(); await model.JumpToMonthAsync(model.Months.Last());
        repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([repo.Photo(200)], offset, offset + 1, false));
        await model.LoadPreviousAsync(); var previousPhoto = model.Items.First(item => item.Id.ItemId == 200);
        await model.ApplyFileChangeAsync(Change(SynologyPhotoFileAction.Delete, previousPhoto));
        repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([repo.Photo(300)], offset, offset + 1, false));
        await model.LoadNextAsync(); Assert.Equal(100, repo.Calls.Last().Offset);
    }
    [Fact]
    public async Task SameSourceTimelineMoveKeepsOriginalPhotoAndMonthWithUpdatedFolder()
    {
        var repo = new SynologyPhotosTestRepository(); using var model = new SynologyPhotosWorkspace(repo); await model.RefreshAsync();
        var month = model.Months.Last(); await model.JumpToMonthAsync(month); var photo = Assert.Single(model.Items); var count = repo.Calls.Count;
        await model.ApplyFileChangeAsync(Change(SynologyPhotoFileAction.Move, photo));
        Assert.Equal(photo.Id, Assert.Single(model.Items).Id); Assert.Equal(9, model.Items[0].FolderId); Assert.Equal(month, model.SelectedMonth); Assert.Equal(count, repo.Calls.Count);
    }
    [Fact]
    public async Task PartialMixedResultDoesNotGuessWhichCardsWereRemoved()
    {
        var repo = FolderRepository(); using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Folders);
        var photo = model.Items[0]; var folder = new SynologyPhotoFolder(SynologyPhotoSpace.Personal, 3, 1, "/Source");
        var result = Change(SynologyPhotoFileAction.Delete, photo, [folder]) with { State = SynologyPhotoFileState.Partial, Counts = new(12, 12, 1, 0, 0) };
        await model.ApplyFileChangeAsync(result); Assert.Single(model.Items); Assert.Single(model.Collections);
    }
    [Theory]
    [InlineData(SynologyPhotoFileAction.Move)]
    [InlineData(SynologyPhotoFileAction.Delete)]
    public async Task CompletingFolderOperationWhileInsideReturnsOriginalSurvivingParent(SynologyPhotoFileAction action)
    {
        var repo = FolderRepository(); using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Folders);
        var source = model.Collections[0]; await model.OpenCollectionAsync(source); var photo = model.Items[0];
        repo.ReadFolders = (_, _, _, _) => Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>([]);
        var result = Change(action, photo, [new(source.Space, source.Id, source.ParentId!.Value, source.Path!)]);
        await model.ApplyFileChangeAsync(result); Assert.Equal(SynologyPhotosSection.Folders, model.Section); Assert.Equal(1, Assert.Single(model.FolderHistory).Id);
        Assert.Equal(1, Assert.IsType<SynologyPhotoQuery.Folder>(repo.Calls.Last().Query).Id); Assert.Empty(model.Collections);
    }
    [Fact]
    public async Task CompletingFolderDeleteCannotRemoveSameNumericAlbumOrOtherSourceFolder()
    {
        var repo = FolderRepository(); repo.Spaces = [SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared]; repo.Albums = [new(3, "synthetic-album")];
        using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Albums);
        var result = Change(SynologyPhotoFileAction.Delete, repo.Photo(), [new(SynologyPhotoSpace.Personal, 3, 1, "/Source")]);
        await model.ApplyFileChangeAsync(result); Assert.Equal("synthetic-album", Assert.Single(model.Collections).Name);
        await model.SelectSectionAsync(SynologyPhotosSection.Folders); await model.SelectSpaceAsync(SynologyPhotoSpace.Shared);
        await model.ApplyFileChangeAsync(result with { Id = Guid.NewGuid() }); Assert.Single(model.Collections); Assert.Equal(SynologyPhotoSpace.Shared, model.Collections[0].Space);
    }
    [Fact]
    public async Task CopyKeepsSourceAndDestinationViewRefreshCanRetryReadFailure()
    {
        var repo = FolderRepository(); using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Folders);
        var result = Change(SynologyPhotoFileAction.Copy, model.Items[0]); var count = repo.Calls.Count;
        await model.ApplyFileChangeAsync(result); Assert.Single(model.Items); Assert.Equal(count, repo.Calls.Count);
        result = result with { Id = Guid.NewGuid(), Command = result.Command with { Destination = new(SynologyPhotoSpace.Personal, 1, 0, "/") } };
        var read = repo.ReadFolders; repo.ReadFolders = (_, _, _, _) => throw new IOException();
        await model.ApplyFileChangeAsync(result); Assert.True(model.NeedsChangesRefresh); Assert.Single(model.Collections);
        repo.ReadFolders = read; await model.ApplyFileChangeAsync(result); Assert.False(model.NeedsChangesRefresh); Assert.Single(model.Collections);
    }
    private static SynologyPhotosTestRepository FolderRepository() => new()
    {
        ReadFolder = (id, space) => Task.FromResult(new SynologyPhotoFolder(space, id, id == 1 ? 0 : 1, id == 1 ? "/" : "/Source")),
        ReadFolders = (id, offset, _, space) => Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(id == 1 && offset == 0 ? [new(3, "Source", 1) { Space = space, Path = "/Source" }] : []),
    };
}
