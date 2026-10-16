using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosSimilarWorkspaceTests
{
    private static SynologyPhotoSimilarDetail Detail(SynologyPhotosTestRepository repo, long top = 1)
    {
        var group = new SynologyPhotoSimilarGroup(11, SynologyPhotoSpace.Personal, top, [1, 2, 3]);
        return new(group, new[] { repo.Photo(1), repo.Photo(2), repo.Photo(3) }.Select(photo => photo with { SimilarGroup = group }).ToArray());
    }
    private static SynologyPhotoRecognitionChange Change(SynologyPhotoRecognitionKind kind = SynologyPhotoRecognitionKind.SimilarUngroup) => new(Guid.NewGuid(), kind,
        SynologyPhotoSpace.Personal, SynologyPhotoChangeState.Completed, null, false, false, false, 1, [11], [], [])
        { TargetIds = [11], SimilarGroups = [new(Guid.NewGuid(), 11, SynologyPhotoChangeState.Completed, null, true)] };
    private static async Task Open(SynologyPhotosWorkspace model) { await model.RefreshAsync(); await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCategoryAsync(SynologyPhotoCategory.Similar); }
    private static SynologyPhotosTestRepository Repository()
    {
        var repo = new SynologyPhotosTestRepository(); var detail = Detail(repo); repo.ReadSimilar = (_, _, _) => Task.FromResult<SynologyPhotoSimilarDetail?>(detail);
        repo.Read = (query, offset, _) => Task.FromResult(new SynologyPhotoPage([detail.Photos[0]], offset, offset + 1, false)); return repo;
    }
    [Fact]
    public async Task SimilarUsesLeafTimelineAndMonthPaging()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model);
        Assert.Empty(repo.CategoryOffsets); Assert.Empty(model.Collections); Assert.IsType<SynologyPhotoQuery.Category>(repo.Calls.Last().Query);
        await model.JumpToMonthAsync(model.Months.Last()); var query = Assert.IsType<SynologyPhotoQuery.Category>(repo.Calls.Last().Query);
        Assert.Equal(SynologyPhotoCategory.Similar, query.Kind); Assert.Equal(model.Months.Last(), model.SelectedMonth);
    }
    [Fact]
    public async Task BestPhotoUpdatesRepresentativeWithoutLosingMonthOrOriginalPreview()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.Preview.OpenAsync(model.Items[0]); var month = model.SelectedMonth;
        repo.ReadSimilar = (_, _, _) => Task.FromResult<SynologyPhotoSimilarDetail?>(Detail(repo, 2));
        await model.ApplyRecognitionChangeAsync(Change(SynologyPhotoRecognitionKind.SimilarTopPick));
        Assert.Equal(2, Assert.Single(model.Items).Id.ItemId); Assert.Equal(1, model.Preview.Photo!.Id.ItemId); Assert.Equal(month, model.SelectedMonth); Assert.True(model.NeedsChangesRefresh);
    }
    [Fact]
    public async Task UngroupKeepsOriginalPreviewAndUndoRestoresOnlyOriginalWindow()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); await model.Preview.OpenAsync(model.Items[0]);
        repo.ReadSimilar = (_, _, _) => Task.FromResult<SynologyPhotoSimilarDetail?>(null); await model.ApplyRecognitionChangeAsync(Change());
        Assert.Empty(model.Items); Assert.NotNull(model.Preview.Photo); Assert.Equal("PhotosSimilarDissolved", model.Preview.SimilarErrorKey);
        repo.ReadSimilar = (_, _, _) => Task.FromResult<SynologyPhotoSimilarDetail?>(Detail(repo)); await model.ApplyRecognitionChangeAsync(Change(SynologyPhotoRecognitionKind.SimilarUndo));
        Assert.Equal(1, Assert.Single(model.Items).Id.ItemId);
        await model.JumpToMonthAsync(model.Months.Last()); repo.Read = (query, offset, _) => Task.FromResult(new SynologyPhotoPage([], offset, offset, false)); await model.ReloadChangedPhotoWindowAsync();
        await model.ApplyRecognitionChangeAsync(Change(SynologyPhotoRecognitionKind.SimilarUndo)); Assert.Empty(model.Items); Assert.False(model.NeedsChangesRefresh);
    }
    [Fact]
    public async Task LateGroupCannotOverwriteAnotherCategory()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model);
        var source = new TaskCompletionSource<SynologyPhotoSimilarDetail?>(TaskCreationOptions.RunContinuationsAsynchronously); repo.ReadSimilar = (_, _, _) => source.Task;
        var apply = model.ApplyRecognitionChangeAsync(Change()); await model.SelectSectionAsync(SynologyPhotosSection.Timeline); source.SetResult(null); await apply;
        Assert.Single(model.Items); Assert.False(model.NeedsChangesRefresh); Assert.Equal(SynologyPhotosSection.Timeline, model.Section);
    }
    [Fact]
    public async Task ReadFailureRetainsOldCardsAndAllowsRetry()
    {
        var repo = Repository(); using var model = new SynologyPhotosWorkspace(repo); await Open(model); var change = Change();
        repo.ReadSimilar = (_, _, _) => throw new HttpRequestException(); await model.ApplyRecognitionChangeAsync(change); Assert.Single(model.Items); Assert.NotNull(model.ErrorKey);
        repo.ReadSimilar = (_, _, _) => Task.FromResult<SynologyPhotoSimilarDetail?>(null); await model.ApplyRecognitionChangeAsync(change); Assert.Empty(model.Items);
    }
    [Fact]
    public async Task GroupFailureDoesNotHideLoadedMedia()
    {
        var repo = Repository(); repo.ReadSimilar = (_, _, _) => throw new HttpRequestException(); using var preview = new SynologyPhotoPreviewModel(repo);
        await preview.OpenAsync(Detail(repo).Photos[0]); Assert.NotNull(preview.ImageBytes); Assert.Null(preview.ErrorKey); Assert.Equal("PhotosSimilarLoadFailed", preview.SimilarErrorKey);
    }
    [Fact]
    public async Task ClosedPreviewDiscardsLateGroupAndAlbumNeverReadsGroup()
    {
        var repo = Repository(); var source = new TaskCompletionSource<SynologyPhotoSimilarDetail?>(TaskCreationOptions.RunContinuationsAsynchronously); var calls = 0;
        repo.ReadSimilar = (_, _, _) => { calls++; return source.Task; }; using var preview = new SynologyPhotoPreviewModel(repo); var opening = preview.OpenAsync(Detail(repo).Photos[0]);
        Assert.NotNull(preview.ImageBytes); preview.Close(); source.SetResult(Detail(repo)); await opening; Assert.Null(preview.SimilarDetail); Assert.Null(preview.Photo);
        await preview.OpenAsync(Detail(repo).Photos[0] with { AlbumContext = new(41, 19, 19) }); Assert.Equal(1, calls); Assert.Null(preview.SimilarDetail);
    }
}
