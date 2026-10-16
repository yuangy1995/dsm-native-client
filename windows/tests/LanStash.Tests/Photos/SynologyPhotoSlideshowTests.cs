using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotoSlideshowTests
{
    private sealed class Clock
    {
        public List<TaskCompletionSource> Waits { get; } = [];
        public Task Delay(CancellationToken token)
        { var source = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); Waits.Add(source); return source.Task.WaitAsync(token); }
    }
    private static SynologyPhotosTestRepository Repository(int count = 3, int pageSize = 2)
    {
        var repository = new SynologyPhotosTestRepository { CanDeleteOriginals = false };
        repository.Read = (query, offset, _) =>
        {
            var items = Enumerable.Range(1, count).Skip(offset).Take(pageSize).Select(id => repository.Photo(id, space: query.Space) with
            { AlbumContext = query is SynologyPhotoQuery.Album album ? new(album.Id, query.Space == SynologyPhotoSpace.Shared ? 0 : 19, 23) : null }).ToArray();
            return Task.FromResult(new SynologyPhotoPage(items, offset, offset + items.Length, offset + items.Length < count));
        };
        return repository;
    }
    private static async Task Until(Func<bool> predicate)
    { for (var index = 0; index < 1000 && !predicate(); index++) await Task.Delay(1); Assert.True(predicate()); }

    [Fact]
    public async Task ImageWaitsForActualDisplayAndEachImageGetsANewDelay()
    {
        var repo = Repository(); using var preview = new SynologyPhotoPreviewModel(repo); var clock = new Clock();
        using var model = new SynologyPhotoSlideshowModel(repo, preview, clock.Delay);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo());
        Assert.True(model.IsLoading); Assert.Empty(clock.Waits); Assert.NotNull(preview.ImageBytes);
        model.MediaPresented(model.MediaGeneration); model.MediaPresented(model.MediaGeneration);
        Assert.Single(clock.Waits); clock.Waits[0].SetResult(); await Until(() => preview.Photo?.Id.ItemId == 2);
        Assert.Single(clock.Waits); model.MediaPresented(model.MediaGeneration); Assert.Equal(2, clock.Waits.Count);
    }
    [Fact]
    public async Task PauseCancelsCountdownAndResumeStartsFreshDelay()
    {
        var repo = Repository(); using var preview = new SynologyPhotoPreviewModel(repo); var clock = new Clock();
        using var model = new SynologyPhotoSlideshowModel(repo, preview, clock.Delay);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo()); model.MediaPresented(model.MediaGeneration);
        await model.ToggleAsync(); clock.Waits[0].SetResult(); await Task.Delay(10);
        Assert.False(model.IsPlaying); Assert.Equal(1, preview.Photo!.Id.ItemId);
        await model.ToggleAsync(); Assert.Equal(2, clock.Waits.Count); clock.Waits[1].SetResult(); await Until(() => preview.Photo?.Id.ItemId == 2);
    }
    [Fact]
    public async Task VideoOnlyAdvancesOnEndedAndHonorsPausedEnd()
    {
        var repo = Repository(); using var preview = new SynologyPhotoPreviewModel(repo); var clock = new Clock();
        using var model = new SynologyPhotoSlideshowModel(repo, preview, clock.Delay);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo(type: "video")); var source = Assert.IsType<SynologyPhotosTestMedia>(preview.MediaSource);
        model.MediaPresented(model.MediaGeneration); Assert.Empty(clock.Waits);
        await model.ToggleAsync(); await model.VideoEndedAsync(model.MediaGeneration); Assert.Equal(1, preview.Photo!.Id.ItemId);
        await model.ToggleAsync(); Assert.Equal(2, preview.Photo!.Id.ItemId); Assert.True(source.Disposed);
    }
    [Fact]
    public async Task LivePhotoStartsWithStillAndDoesNotStartMotionStream()
    {
        var repo = Repository(); repo.Video = (_, _) => throw new InvalidOperationException(); using var preview = new SynologyPhotoPreviewModel(repo); var clock = new Clock();
        using var model = new SynologyPhotoSlideshowModel(repo, preview, clock.Delay);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo(type: "live")); model.MediaPresented(model.MediaGeneration);
        Assert.Single(clock.Waits); Assert.Null(preview.MediaSource); Assert.False(preview.IsPlayingMotion);
    }
    [Fact]
    public async Task PreviousFromFirstReadsAllPagesBeforeWrappingAndNextLoops()
    {
        var repo = Repository(5); using var preview = new SynologyPhotoPreviewModel(repo); using var model = new SynologyPhotoSlideshowModel(repo, preview);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo()); await model.ToggleAsync();
        await model.AdvanceAsync(-1); Assert.Equal(5, preview.Photo!.Id.ItemId); Assert.Equal(new[] { 0, 2, 4 }, repo.Calls.Select(call => call.Offset));
        await model.AdvanceAsync(1); Assert.Equal(1, preview.Photo!.Id.ItemId); Assert.Equal(3, repo.Calls.Count); Assert.False(model.IsPlaying);
    }
    [Fact]
    public async Task NextFetchesOnlyNeededPagesAndLocatesHistoricalStart()
    {
        var repo = Repository(7); using var preview = new SynologyPhotoPreviewModel(repo); using var model = new SynologyPhotoSlideshowModel(repo, preview);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo(4)); await model.AdvanceAsync(1);
        Assert.Equal(5, preview.Photo!.Id.ItemId); Assert.Equal(new[] { 0, 2, 4 }, repo.Calls.Select(call => call.Offset));
        await model.AdvanceAsync(1); Assert.Equal(6, preview.Photo!.Id.ItemId); Assert.Equal(3, repo.Calls.Count);
    }
    [Theory]
    [InlineData("folder")]
    [InlineData("album")]
    [InlineData("filter")]
    [InlineData("search")]
    public async Task IndependentCursorKeepsQuerySortAndSource(string kind)
    {
        var repo = Repository(); SynologyPhotoQuery query = kind switch
        {
            "folder" => new SynologyPhotoQuery.Folder(3, new(SynologyPhotoSortField.Filename, true)),
            "album" => new SynologyPhotoQuery.Album(41),
            "filter" => new SynologyPhotoQuery.Filtered(new() { Rating = 4 }, 0, 99),
            _ => new SynologyPhotoQuery.Search("synthetic", 0, 99)
        }; query = query with { Space = SynologyPhotoSpace.Shared };
        var photo = repo.Photo(space: query.Space) with { AlbumContext = kind == "album" ? new(41, 0, 23) : null };
        using var preview = new SynologyPhotoPreviewModel(repo); using var model = new SynologyPhotoSlideshowModel(repo, preview);
        await model.StartAsync(query, photo); await model.AdvanceAsync(1); Assert.Equal(query, Assert.Single(repo.Calls).Query);
        Assert.Equal(SynologyPhotoSpace.Shared, preview.Photo!.Id.Space); Assert.Null(model.ErrorKey);
    }
    [Fact]
    public async Task WorkspacePreservesMonthSelectionAndUsesCompleteTimeline()
    {
        var repo = Repository(); using var workspace = new SynologyPhotosWorkspace(repo); await workspace.RefreshAsync();
        var completeQuery = repo.Calls[^1].Query;
        await workspace.JumpToMonthAsync(workspace.Months.Last()); var month = workspace.SelectedMonth; var items = workspace.Items.ToArray();
        await workspace.StartSlideshowAsync(); await workspace.Slideshow.AdvanceAsync(1);
        var query = Assert.IsType<SynologyPhotoQuery.Timeline>(repo.Calls[^1].Query); Assert.Equal(completeQuery, query);
        Assert.Equal(month, workspace.SelectedMonth); Assert.Equal(items, workspace.Items);
        workspace.Slideshow.MediaPresented(workspace.Slideshow.MediaGeneration); workspace.Slideshow.Stop();
        Assert.NotNull(workspace.Preview.Photo);
    }
    [Theory]
    [InlineData("offset")]
    [InlineData("next")]
    [InlineData("empty")]
    [InlineData("duplicate")]
    [InlineData("space")]
    [InlineData("profile")]
    [InlineData("album")]
    [InlineData("oversize")]
    [InlineData("missing")]
    public async Task MalformedPagePausesWithoutChangingCurrentPhoto(string kind)
    {
        var repo = Repository(); repo.Read = (_, offset, _) => Task.FromResult(kind switch
        {
            "offset" => new SynologyPhotoPage([repo.Photo()], 1, 1, false),
            "next" => new SynologyPhotoPage([repo.Photo()], 0, 5, false),
            "empty" => new SynologyPhotoPage([], 0, 0, true),
            "duplicate" => new SynologyPhotoPage([repo.Photo(), repo.Photo()], 0, 2, false),
            "space" => new SynologyPhotoPage([repo.Photo(space: SynologyPhotoSpace.Shared)], 0, 1, false),
            "profile" => new SynologyPhotoPage([repo.Photo() with { Id = new(Guid.NewGuid(), SynologyPhotoSpace.Personal, 1) }], 0, 1, false),
            "album" => new SynologyPhotoPage([repo.Photo() with { AlbumContext = new(41, 19, 23) }], 0, 1, false),
            "oversize" => new SynologyPhotoPage(Enumerable.Range(1, 101).Select(id => repo.Photo(id)).ToArray(), 0, 101, false),
            _ => new SynologyPhotoPage([repo.Photo(7)], 0, 1, false)
        });
        using var preview = new SynologyPhotoPreviewModel(repo); using var model = new SynologyPhotoSlideshowModel(repo, preview);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo()); await model.AdvanceAsync(1);
        Assert.False(model.IsPlaying); Assert.Equal("PhotosSlideshowFailed", model.ErrorKey); Assert.Equal(1, preview.Photo!.Id.ItemId);
    }
    [Fact]
    public async Task CrossPageDuplicateIsRejectedAndRetryKeepsOriginalCursor()
    {
        var repo = Repository(); var valid = repo.Read!; repo.Read = (query, offset, token) => offset == 0 ? valid(query, offset, token) : Task.FromResult(new SynologyPhotoPage([repo.Photo(2)], 2, 3, false));
        using var preview = new SynologyPhotoPreviewModel(repo); using var model = new SynologyPhotoSlideshowModel(repo, preview);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo(2)); await model.AdvanceAsync(1); Assert.NotNull(model.ErrorKey);
        repo.Read = valid; await model.ToggleAsync(); Assert.Equal(3, preview.Photo!.Id.ItemId); Assert.Null(model.ErrorKey); Assert.Equal(new[] { 0, 2, 2 }, repo.Calls.Select(call => call.Offset));
    }
    [Fact]
    public async Task AlbumOwnerChangeCannotLocateAnotherContributorsPhoto()
    {
        var repo = Repository(); using var preview = new SynologyPhotoPreviewModel(repo); using var model = new SynologyPhotoSlideshowModel(repo, preview);
        await model.StartAsync(new SynologyPhotoQuery.Album(41), repo.Photo() with { AlbumContext = new(41, 44, 44) });
        await model.AdvanceAsync(1); Assert.NotNull(model.ErrorKey); Assert.Equal(44, preview.Photo!.AlbumContext!.OwnerUserId);
    }
    [Fact]
    public async Task CompleteSimilarGroupDoesNotReadOtherGroups()
    {
        var repo = Repository(); var group = new SynologyPhotoSimilarGroup(11, SynologyPhotoSpace.Personal, 1, [1, 3]);
        var detail = new SynologyPhotoSimilarDetail(group, new[] { repo.Photo(), repo.Photo(3) }.Select(photo => photo with { SimilarGroup = group }).ToArray());
        repo.ReadSimilar = (_, _, _) => Task.FromResult<SynologyPhotoSimilarDetail?>(detail); repo.Read = (_, _, _) => throw new InvalidOperationException();
        using var preview = new SynologyPhotoPreviewModel(repo); using var model = new SynologyPhotoSlideshowModel(repo, preview);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), detail.Photos[0]); await model.AdvanceAsync(1); Assert.Equal(3, preview.Photo!.Id.ItemId);
        await model.AdvanceAsync(1); Assert.Equal(1, preview.Photo!.Id.ItemId); Assert.Empty(repo.Calls);
    }
    [Fact]
    public async Task FailedInitialSimilarReadCanRetryWithoutFallingBackToTimeline()
    {
        var repo = Repository(); var group = new SynologyPhotoSimilarGroup(11, SynologyPhotoSpace.Personal, 1, [1, 2]);
        var photos = new[] { repo.Photo(), repo.Photo(2) }.Select(photo => photo with { SimilarGroup = group }).ToArray();
        repo.ReadSimilar = (_, _, _) => throw new HttpRequestException(); using var preview = new SynologyPhotoPreviewModel(repo); using var model = new SynologyPhotoSlideshowModel(repo, preview);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), photos[0]); Assert.NotNull(model.ErrorKey); Assert.Null(preview.Photo);
        repo.ReadSimilar = (_, _, _) => Task.FromResult<SynologyPhotoSimilarDetail?>(new(group, photos)); await model.ToggleAsync(); await model.AdvanceAsync(1);
        Assert.Equal(2, preview.Photo!.Id.ItemId); Assert.Empty(repo.Calls);
    }
    [Fact]
    public async Task FailedImageReadPausesAndRetryReopensOnlyCurrentPhoto()
    {
        var repo = Repository(); repo.Thumbnail = (_, _) => throw new HttpRequestException(); using var preview = new SynologyPhotoPreviewModel(repo); using var model = new SynologyPhotoSlideshowModel(repo, preview);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo()); Assert.NotNull(model.ErrorKey); Assert.False(model.IsPlaying);
        repo.Thumbnail = (_, _) => Task.FromResult(new byte[] { 1 }); await model.ToggleAsync(); model.MediaPresented(model.MediaGeneration);
        Assert.Null(model.ErrorKey); Assert.True(model.IsPlaying); Assert.Empty(repo.Calls);
    }
    [Fact]
    public async Task StopDiscardsLatePageAndStaleMediaEvents()
    {
        var repo = Repository(); var source = new TaskCompletionSource<SynologyPhotoPage>(TaskCreationOptions.RunContinuationsAsynchronously); repo.Read = (_, _, _) => source.Task;
        using var preview = new SynologyPhotoPreviewModel(repo); var clock = new Clock(); using var model = new SynologyPhotoSlideshowModel(repo, preview, clock.Delay);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo()); var generation = model.MediaGeneration; model.MediaPresented(generation);
        var move = model.AdvanceAsync(1); model.Stop(); source.SetResult(new([repo.Photo(), repo.Photo(2)], 0, 2, false)); await move;
        model.MediaPresented(generation); await model.VideoEndedAsync(generation); model.PlaybackFailed(generation);
        Assert.False(model.IsPresented); Assert.Null(model.ErrorKey); Assert.Empty(model.Photos); Assert.Equal(1, preview.Photo!.Id.ItemId);
    }
    [Fact]
    public async Task StopDisposesLateVideoAndWorkspaceSuspendClosesPreview()
    {
        var repo = Repository(); var source = new TaskCompletionSource<IReadOnlyMediaSource>(TaskCreationOptions.RunContinuationsAsynchronously); repo.Video = (_, _) => source.Task;
        using var workspace = new SynologyPhotosWorkspace(repo); workspace.Items.Add(repo.Photo(type: "video"));
        var opening = workspace.StartSlideshowAsync(); workspace.Suspend(); var media = new SynologyPhotosTestMedia(); source.SetResult(media); await opening;
        Assert.True(media.Disposed); Assert.Null(workspace.Preview.Photo); Assert.False(workspace.Slideshow.IsPresented);
    }
    [Fact]
    public async Task PauseDuringPageReadRejectsItsLateResultAndDoesNotAdvance()
    {
        var repo = Repository(); var source = new TaskCompletionSource<SynologyPhotoPage>(TaskCreationOptions.RunContinuationsAsynchronously); repo.Read = (_, _, _) => source.Task;
        using var preview = new SynologyPhotoPreviewModel(repo); using var model = new SynologyPhotoSlideshowModel(repo, preview);
        await model.StartAsync(new SynologyPhotoQuery.Recent(), repo.Photo()); model.MediaPresented(model.MediaGeneration);
        var moving = model.AdvanceAsync(1); await model.ToggleAsync(); source.SetResult(new([repo.Photo(), repo.Photo(2)], 0, 2, false)); await moving;
        Assert.Empty(model.Photos); Assert.Equal(1, preview.Photo!.Id.ItemId); Assert.False(model.IsPlaying); Assert.False(model.IsLoading);
    }
}
