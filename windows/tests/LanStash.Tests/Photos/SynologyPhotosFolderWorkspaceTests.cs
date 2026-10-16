using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosFolderWorkspaceTests
{
    private static SynologyPhotosTestRepository Repository() => new()
    {
        ReadFolder = (id, space) => Task.FromResult(new SynologyPhotoFolder(space, id, id == 1 ? 0 : 1, id == 1 ? "/" : "/synthetic") { Sort = new(SynologyPhotoSortField.Filename, true) }),
        ReadFolders = (id, offset, _, space) => Task.FromResult<IReadOnlyList<SynologyPhotoCollection>>(id == 1 && offset == 0 ? [new(3, "synthetic", 1) { Space = space, Path = "/synthetic" }] : []),
    };
    [Fact]
    public async Task FolderOpenReadsSavedSortAndBothListsUseSameDirection()
    {
        var repo = Repository(); var directions = new List<bool>(); var source = repo.ReadFolders!;
        repo.ReadFolders = (id, offset, descending, space) => { directions.Add(descending); return source(id, offset, descending, space); };
        using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Folders);
        var query = Assert.IsType<SynologyPhotoQuery.Folder>(repo.Calls.Last().Query);
        Assert.Equal(new(SynologyPhotoSortField.Filename, true), query.Sort); Assert.All(directions, Assert.True);
    }
    [Fact]
    public async Task RenameUpdatesOriginalBreadcrumbWithoutReloadingPhotos()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Folders);
        await model.OpenCollectionAsync(model.Collections[0]); var count = repo.Calls.Count; var photo = model.Items[0];
        var folder = await repo.FolderAsync(3, SynologyPhotoSpace.Personal);
        await model.ApplyFolderChangeAsync(new(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Rename, folder) { Name = "renamed" }, SynologyPhotoChangeState.Completed,
            folder with { Path = "/renamed" }, null, false, false));
        Assert.Equal("renamed", model.FolderHistory.Last().Name); Assert.Equal("/renamed", model.FolderHistory.Last().Path);
        Assert.Equal(count, repo.Calls.Count); Assert.Same(photo, model.Items[0]);
    }
    [Fact]
    public async Task SortSaveReloadsSameFolderAndInvalidatesOldPaging()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Folders);
        await model.OpenCollectionAsync(model.Collections[0]); var folder = await repo.FolderAsync(3, SynologyPhotoSpace.Personal); var sort = new SynologyPhotoSort(SynologyPhotoSortField.FileSize);
        var result = new SynologyPhotoFolderChange(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Sort, folder) { Sort = sort }, SynologyPhotoChangeState.Completed,
            folder with { Sort = sort }, null, false, false);
        await model.ApplyFolderChangeAsync(result);
        var query = Assert.IsType<SynologyPhotoQuery.Folder>(repo.Calls.Last().Query); Assert.Equal(3, query.Id); Assert.Equal(sort, query.Sort);
        Assert.Equal(0, repo.Calls.Last().Offset); Assert.Equal(3, model.FolderHistory.Last().Id); Assert.Single(model.Items);
    }
    [Fact]
    public async Task LateFolderResultCannotRenameAnotherSourceWithSameId()
    {
        var repo = Repository(); repo.Spaces = [SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared];
        using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Folders);
        var folder = await repo.FolderAsync(3, SynologyPhotoSpace.Personal); await model.SelectSpaceAsync(SynologyPhotoSpace.Shared);
        await model.ApplyFolderChangeAsync(new(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Rename, folder) { Name = "renamed" }, SynologyPhotoChangeState.Completed,
            folder with { Path = "/renamed" }, null, false, false));
        Assert.Equal("synthetic", Assert.Single(model.Collections).Name); Assert.Equal(SynologyPhotoSpace.Shared, model.SelectedSpace);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedFolderRefreshKeepsExistingContentsAndRetriesSavedSort(bool fromHistory)
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await model.SelectSectionAsync(SynologyPhotosSection.Folders);
        var folder = await repo.FolderAsync(1, SynologyPhotoSpace.Personal); var sort = new SynologyPhotoSort(SynologyPhotoSortField.FileSize);
        var source = repo.ReadFolders!; repo.ReadFolders = (_, _, _, _) => throw new IOException();
        var result = new SynologyPhotoFolderChange(Guid.NewGuid(), new(SynologyPhotoFolderEditKind.Sort, folder) { Sort = sort }, SynologyPhotoChangeState.Completed,
            folder with { Sort = sort }, null, false, false);
        await model.ApplyFolderChangeAsync(result);
        Assert.True(model.NeedsChangesRefresh); Assert.Single(model.Collections); Assert.Single(model.Items);
        Assert.Equal("PhotosFolderReloadFailed", model.ErrorKey); repo.ReadFolders = source;
        if (fromHistory) await model.ApplyFolderChangeAsync(result); else await model.LoadNextAsync();
        Assert.False(model.NeedsChangesRefresh); Assert.Equal(sort, Assert.IsType<SynologyPhotoQuery.Folder>(repo.Calls.Last().Query).Sort);
    }
}
