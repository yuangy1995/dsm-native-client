using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosConceptWorkspaceTests
{
    private static SynologyPhotosTestRepository Repository() => new() { Concepts = Enumerable.Range(1, 151).Select(id => new SynologyPhotoConcept(new(id, $"Synthetic {id}", Count: 3), true, 2)).ToArray() };
    private static SynologyPhotoRecognitionChange Change(SynologyPhotoRecognitionKind kind = SynologyPhotoRecognitionKind.ShowConcepts) =>
        new(Guid.NewGuid(), kind, SynologyPhotoSpace.Personal, SynologyPhotoChangeState.Completed, null, false, false, false, 1, [1], [], []) { TargetIds = [1] };
    private static async Task Open(SynologyPhotosWorkspace model) { await model.RefreshAsync(); await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCategoryAsync(SynologyPhotoCategory.Subjects); }
    [Fact]
    public async Task DisplayRefreshReadsFullListAndAppliesActualThreshold()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); Assert.Equal(100, model.Collections.Count);
        repo.Concepts = repo.Concepts.Select(value => value.Concept.Id == 1 ? value with { Visible = false } : value.Concept.Id == 2 ? value with { Concept = value.Concept with { Count = 1 } } : value).ToArray();
        await model.ApplyRecognitionChangeAsync(Change()); Assert.Equal(149, model.Collections.Count); Assert.False(model.HasMoreCollections);
        Assert.DoesNotContain(model.Collections, value => value.Id is 1 or 2); await model.LoadNextAsync(); Assert.Equal([0], repo.CategoryOffsets);
    }
    [Fact]
    public async Task FailedListRefreshPreservesOldPageAndRetriesFromCompleteList()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); repo.ReadConcepts = _ => throw new HttpRequestException();
        await model.ApplyRecognitionChangeAsync(Change()); Assert.Equal(100, model.Collections.Count); Assert.NotNull(model.ErrorKey);
        repo.ReadConcepts = null; await model.LoadNextAsync(); Assert.Equal(151, model.Collections.Count); Assert.Null(model.ErrorKey); Assert.Equal([0], repo.CategoryOffsets);
    }
    [Fact]
    public async Task LateListCannotOverwriteAnotherPage()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model);
        var pending = new TaskCompletionSource<IReadOnlyList<SynologyPhotoConcept>>(TaskCreationOptions.RunContinuationsAsynchronously); repo.ReadConcepts = _ => pending.Task;
        var loading = model.ApplyRecognitionChangeAsync(Change()); await model.SelectSectionAsync(SynologyPhotosSection.Timeline); pending.SetResult(repo.Concepts); await loading;
        Assert.Empty(model.Collections); Assert.Equal(SynologyPhotosSection.Timeline, model.Section);
    }
    [Fact]
    public async Task CoverKeepsCurrentPhotoWindowAndMonth()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.OpenCollectionAsync(model.Collections[0]); var month = model.SelectedMonth; var photos = model.Items.ToArray(); var calls = repo.Calls.Count;
        repo.Concepts = repo.Concepts.Select(value => value.Concept.Id == 1 ? value with { Concept = value.Concept with { Thumbnail = new(99, "new") } } : value).ToArray();
        await model.ApplyRecognitionChangeAsync(Change(SynologyPhotoRecognitionKind.SetConceptCover)); Assert.Equal(99, model.CategoryItem!.Thumbnail!.UnitId);
        Assert.Equal(month, model.SelectedMonth); Assert.Equal(photos, model.Items); Assert.Equal(calls, repo.Calls.Count);
    }
    [Fact]
    public async Task RemovalClosesOnlyRemovedPreviewAndDoesNotDeleteOriginalGlobally()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.OpenCollectionAsync(model.Collections[0]); await model.Preview.OpenAsync(model.Items[0]); var removed = model.Preview.Photo!.Id.ItemId;
        var month = model.SelectedMonth; repo.Read = (query, offset, _) => Task.FromResult(new SynologyPhotoPage(query is SynologyPhotoQuery.Category ? [repo.Photo(2)] : [repo.Photo((int)removed)], offset, offset + 1, false));
        repo.Concepts = repo.Concepts.Select(value => value.Concept.Id == 1 ? value with { Concept = value.Concept with { Count = 1 } } : value).ToArray();
        var change = Change(SynologyPhotoRecognitionKind.RemoveConceptPhotos) with { RemovedPhotoIds = [removed] };
        await model.ApplyRecognitionChangeAsync(change); Assert.Null(model.Preview.Photo); Assert.Equal(2, Assert.Single(model.Items).Id.ItemId); Assert.Equal(month, model.SelectedMonth); Assert.Equal(1, model.CategoryItem!.Id);
        var reads = repo.Calls.Count; await model.ApplyRecognitionChangeAsync(change); Assert.Equal(reads, repo.Calls.Count);
        await model.SelectSectionAsync(SynologyPhotosSection.Timeline); Assert.Equal(removed, Assert.Single(model.Items).Id.ItemId);
    }
    [Fact]
    public async Task IndependentThemeAndSourceDoNotRefreshCurrentPhotos()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.OpenCollectionAsync(model.Collections[0]); var reads = repo.Calls.Count;
        repo.ReadConcepts = _ => throw new InvalidOperationException("不应读取");
        await model.ApplyRecognitionChangeAsync(Change(SynologyPhotoRecognitionKind.RemoveConceptPhotos) with { TargetIds = [2] });
        await model.ApplyRecognitionChangeAsync(Change() with { Space = SynologyPhotoSpace.Shared }); await model.ApplyRecognitionChangeAsync(Change() with { CompletedIds = [] });
        Assert.Equal(reads, repo.Calls.Count); Assert.Null(model.ErrorKey);
    }
}
