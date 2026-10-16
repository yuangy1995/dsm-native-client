using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosPeopleWorkspaceTests
{
    private static SynologyPhotoRecognitionChange Change(SynologyPhotoSpace space = SynologyPhotoSpace.Personal) => new(Guid.NewGuid(), SynologyPhotoRecognitionKind.RenamePerson,
        space, SynologyPhotoChangeState.Completed, null, false, false, false, 1, [1], [new(new(1, "Stale name"), true)], []);
    private static SynologyPhotosTestRepository Repository() => new() { People = Enumerable.Range(1, 151).Select(id => new SynologyPhotoPerson(new(id, $"Synthetic {id}"), true)).ToArray() };
    private static async Task Open(SynologyPhotosWorkspace model) { await model.RefreshAsync(); await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCategoryAsync(SynologyPhotoCategory.People); }
    [Fact]
    public async Task ChangedCategoryRebuildsCompleteOffsetWithoutReloadingPhotos()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model);
        Assert.Equal(100, model.Collections.Count); Assert.True(model.HasMoreCollections); var reads = repo.Calls.Count;
        repo.People = repo.People.Skip(1).ToArray(); await model.ApplyRecognitionChangeAsync(Change());
        Assert.Equal(150, model.Collections.Count); Assert.False(model.HasMoreCollections); Assert.DoesNotContain(model.Collections, person => person.Id == 1);
        await model.LoadNextAsync(); Assert.Equal([0], repo.CategoryOffsets); Assert.Equal(reads, repo.Calls.Count);
    }
    [Fact]
    public async Task FailedRefreshPreservesItemsAndDoesNotUseStaleOffset()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); repo.ReadPeople = _ => throw new HttpRequestException();
        await model.ApplyRecognitionChangeAsync(Change()); Assert.Equal(100, model.Collections.Count); Assert.NotNull(model.ErrorKey);
        repo.ReadPeople = null; await model.LoadNextAsync(); Assert.Equal(151, model.Collections.Count); Assert.Equal([0], repo.CategoryOffsets); Assert.Null(model.ErrorKey);
    }
    [Fact]
    public async Task ViewedPersonUsesFreshNameAndPreservesPhotoWindow()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.OpenCollectionAsync(model.Collections[0]);
        var items = model.Items.ToArray(); var calls = repo.Calls.Count; var month = model.SelectedMonth;
        repo.People = repo.People.Select(person => person.Person.Id == 1 ? person with { Person = person.Person with { Name = "Current name" } } : person).ToArray();
        await model.ApplyRecognitionChangeAsync(Change()); Assert.Equal("Current name", model.CategoryItem!.Name);
        Assert.Equal(items, model.Items); Assert.Equal(calls, repo.Calls.Count); Assert.Equal(month, model.SelectedMonth);
    }
    [Fact]
    public async Task ForeignSourceAndUnconfirmedChangesDoNotReplaceCurrentCategory()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); repo.ReadPeople = _ => throw new InvalidOperationException("不应读取");
        await model.ApplyRecognitionChangeAsync(Change(SynologyPhotoSpace.Shared)); await model.ApplyRecognitionChangeAsync(Change() with { State = SynologyPhotoChangeState.PendingReview, CompletedIds = [] });
        Assert.Equal(100, model.Collections.Count); Assert.Null(model.ErrorKey);
    }
    [Fact]
    public async Task LateCategoryRefreshCannotOverwriteAnotherPage()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model);
        var pending = new TaskCompletionSource<IReadOnlyList<SynologyPhotoPerson>>(TaskCreationOptions.RunContinuationsAsynchronously);
        repo.ReadPeople = _ => pending.Task; var refresh = model.ApplyRecognitionChangeAsync(Change());
        await model.SelectSectionAsync(SynologyPhotosSection.Timeline); pending.SetResult(repo.People); await refresh;
        Assert.Empty(model.Collections); Assert.NotEmpty(model.Items); Assert.Equal(SynologyPhotosSection.Timeline, model.Section);
    }
    [Theory]
    [InlineData(SynologyPhotoRecognitionKind.RemovePersonFaces)][InlineData(SynologyPhotoRecognitionKind.ReassignPersonFaces)]
    public async Task FaceChangesReloadCurrentMembersFromZeroAndKeepMonth(SynologyPhotoRecognitionKind kind)
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.OpenCollectionAsync(model.Collections[0]);
        var month = model.SelectedMonth; repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([repo.Photo(2)], offset, offset + 1, false));
        var change = Change() with { Kind = kind, TargetIds = [1], CompletedIds = [71], RemovedPhotoIds = [1] };
        await model.ApplyRecognitionChangeAsync(change); Assert.Equal(2, Assert.Single(model.Items).Id.ItemId); Assert.Equal(0, repo.Calls.Last().Offset);
        Assert.Equal(month, model.SelectedMonth); Assert.Equal(1, model.CategoryItem!.Id); var calls = repo.Calls.Count;
        await model.ApplyRecognitionChangeAsync(change); Assert.Equal(calls, repo.Calls.Count);
    }
    [Fact]
    public async Task FaceRefreshFailureRetainsVisiblePhotosAndOffersExplicitReload()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.OpenCollectionAsync(model.Collections[0]);
        var original = model.Items.ToArray(); repo.Read = (_, _, _) => throw new HttpRequestException();
        await model.ApplyRecognitionChangeAsync(Change() with { Kind = SynologyPhotoRecognitionKind.RemovePersonFaces, TargetIds = [1], CompletedIds = [71], RemovedPhotoIds = [1] });
        Assert.Equal(original, model.Items); Assert.True(model.NeedsChangesRefresh); Assert.NotNull(model.ErrorKey);
        repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([], offset, offset, false)); await model.LoadNextAsync(); Assert.Empty(model.Items); Assert.False(model.NeedsChangesRefresh);
    }
    [Fact]
    public async Task FaceChangesForOtherPersonDoNotReloadCurrentPhotoWindow()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.OpenCollectionAsync(model.Collections[0]); var calls = repo.Calls.Count;
        await model.ApplyRecognitionChangeAsync(Change() with { Kind = SynologyPhotoRecognitionKind.RemovePersonFaces, TargetIds = [2], CompletedIds = [71], RemovedPhotoIds = [1] });
        Assert.Equal(calls, repo.Calls.Count); Assert.NotEmpty(model.Items);
    }
    [Fact]
    public async Task ReassignmentReloadsDestinationIfUserAlreadyOpenedIt()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.OpenCollectionAsync(model.Collections[1]);
        repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([repo.Photo(2), repo.Photo(3)], offset, offset + 2, false));
        await model.ApplyRecognitionChangeAsync(Change() with { Kind = SynologyPhotoRecognitionKind.ReassignPersonFaces, TargetIds = [1, 2], CompletedIds = [71] });
        Assert.Equal([2L, 3L], model.Items.Select(photo => photo.Id.ItemId)); Assert.Equal(2, model.CategoryItem!.Id); Assert.Equal(0, repo.Calls.Last().Offset);
    }
    [Fact]
    public async Task ManualPartialCompletionRefreshesPersonWithoutNumericCompletionIds()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.OpenCollectionAsync(model.Collections[1]);
        repo.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([repo.Photo(3)], offset, offset + 1, false));
        await model.ApplyRecognitionChangeAsync(Change() with { Kind = SynologyPhotoRecognitionKind.ManualFaces, State = SynologyPhotoChangeState.Failed,
            TargetIds = [1, 2], CompletedIds = [], CompletedFaceChanges = ["new-a"] });
        Assert.Equal(3, Assert.Single(model.Items).Id.ItemId); Assert.Equal(0, repo.Calls.Last().Offset); Assert.Equal(2, model.CategoryItem!.Id);
    }
}
