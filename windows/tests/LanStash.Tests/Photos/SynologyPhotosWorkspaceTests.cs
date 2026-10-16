using LanStash.App.Features.Photos.Synology;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosWorkspaceTests
{
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ConditionSourcesRequireCurrentSharedManagementRole(bool personal)
    {
        var repository = new SynologyPhotosTestRepository { Spaces = personal ? [SynologyPhotoSpace.Personal, SynologyPhotoSpace.Shared] : [SynologyPhotoSpace.Shared], CanManageSharedSpace = true };
        using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync(); Assert.Contains(SynologyPhotoSpace.Shared, model.ConditionSpaces);
        repository.CanManageSharedSpace = false; await model.RefreshAsync();
        Assert.DoesNotContain(SynologyPhotoSpace.Shared, model.ConditionSpaces);
        Assert.Equal(personal, model.ConditionSpaces.Contains(SynologyPhotoSpace.Personal));
        Assert.Contains(SynologyPhotoSpace.Shared, model.Spaces);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ConfirmedMetadataOnlyUpdatesMatchingOriginalAlbumContext(bool differentAlbum)
    {
        var repository = new SynologyPhotosTestRepository(); using var model = new SynologyPhotosWorkspace(repository);
        var original = repository.Photo() with { AlbumContext = new(41, 19, 19) };
        var displayed = differentAlbum ? original with { AlbumContext = new(42, 19, 19) } : original;
        model.Items.Add(displayed);
        var changed = original with { Rating = 5, TakenAt = original.TakenAt.AddHours(1) };
        await model.ApplyConfirmedChangesAsync(Guid.NewGuid(), [new(original, SynologyPhotoChangeState.Completed, changed)]);
        Assert.Equal(differentAlbum ? displayed : changed, Assert.Single(model.Items));
    }
    [Fact]
    public async Task UnknownMetadataDoesNotReplaceVisiblePhoto()
    {
        var repository = new SynologyPhotosTestRepository(); using var model = new SynologyPhotosWorkspace(repository);
        var original = repository.Photo(); model.Items.Add(original);
        await model.ApplyConfirmedChangesAsync(Guid.NewGuid(), [new(original, SynologyPhotoChangeState.PendingReview, original with { Rating = 5 })]);
        Assert.Equal(original, Assert.Single(model.Items));
    }
    [Fact]
    public async Task AccessWithoutPersonalSpaceDoesNotRequestAFileStationFallback()
    {
        var repository = new SynologyPhotosTestRepository { Spaces = [] };
        using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync();
        Assert.True(model.HasLoaded); Assert.Empty(model.Items); Assert.Empty(repository.Calls);
        Assert.Equal(SynologyPhotosSection.Albums, model.Section); Assert.Equal(1, repository.AlbumCalls);
    }

    [Fact]
    public async Task MetadataReloadPreservesHistoricalMonthAndRebuildsRawOffset()
    {
        var repository = new SynologyPhotosTestRepository(); using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync(); await model.JumpToMonthAsync(new(2026, 8));
        var original = model.Items[0]; var end = Assert.IsType<SynologyPhotoQuery.Timeline>(repository.Calls[^1].Query).End;
        repository.Read = (_, offset, _) => Task.FromResult(offset == 0
            ? new SynologyPhotoPage(Enumerable.Range(1, 100).Select(id => repository.Photo(id) with { Rating = 5 }).ToArray(), 0, 100, true)
            : new SynologyPhotoPage([repository.Photo(101)], 100, 101, false));
        await model.ApplyConfirmedChangesAsync(Guid.NewGuid(), [new(original, SynologyPhotoChangeState.Completed, original with { Rating = 5 })]);
        Assert.Equal(new SynologyPhotoMonth(2026, 8), model.SelectedMonth); Assert.Equal(end, Assert.IsType<SynologyPhotoQuery.Timeline>(repository.Calls[^1].Query).End);
        await model.LoadNextAsync(); Assert.Equal(100, repository.Calls[^1].Offset); Assert.Equal(101, model.Items.Count);
    }
    [Fact]
    public async Task MetadataReloadInvalidatesOldPagingResponseWithoutLosingCurrentSelectionScope()
    {
        var repository = new SynologyPhotosTestRepository(); var delayed = new TaskCompletionSource<SynologyPhotoPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var hold = true;
        repository.Read = (_, offset, _) => offset == 100 && hold ? delayed.Task : Task.FromResult(offset == 0
            ? new SynologyPhotoPage(Enumerable.Range(1, 100).Select(id => repository.Photo(id)).ToArray(), 0, 100, true)
            : new SynologyPhotoPage([repository.Photo(222)], 100, 101, false));
        using var model = new SynologyPhotosWorkspace(repository); await model.RefreshAsync(); var original = model.Items[0];
        var oldPage = model.LoadNextAsync();
        await model.ApplyConfirmedChangesAsync(Guid.NewGuid(), [new(original, SynologyPhotoChangeState.Completed, original with { Rating = 5 })]);
        delayed.SetResult(new([repository.Photo(101)], 100, 101, false)); await oldPage;
        Assert.DoesNotContain(model.Items, photo => photo.Id.ItemId == 101); Assert.Equal(100, model.Items.Count);
        hold = false; await model.LoadNextAsync(); Assert.Equal(100, repository.Calls[^1].Offset); Assert.Contains(model.Items, photo => photo.Id.ItemId == 222);
    }
    [Fact]
    public async Task SavedChangeSurvivesReloadFailureAndExplicitRetryKeepsMonth()
    {
        var repository = new SynologyPhotosTestRepository(); using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync(); await model.JumpToMonthAsync(new(2026, 8)); var original = model.Items[0]; var id = Guid.NewGuid();
        var changes = new[] { new SynologyPhotoChangeItem(original, SynologyPhotoChangeState.Completed, original with { Rating = 5 }) };
        repository.Read = (_, _, _) => Task.FromException<SynologyPhotoPage>(new IOException());
        await model.ApplyConfirmedChangesAsync(id, changes); Assert.True(model.NeedsChangesRefresh); Assert.Equal(5, model.Items[0].Rating);
        var count = repository.Calls.Count; await model.LoadNextAsync(automatic: true); Assert.Equal(count, repository.Calls.Count);
        repository.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([original with { Rating = 5 }], offset, offset + 1, false));
        await model.ReloadChangedPhotoWindowAsync(); Assert.False(model.NeedsChangesRefresh); Assert.Null(model.ErrorKey); Assert.Equal(new SynologyPhotoMonth(2026, 8), model.SelectedMonth);
        count = repository.Calls.Count; await model.ApplyConfirmedChangesAsync(id, changes); Assert.Equal(count, repository.Calls.Count);
    }
    [Fact]
    public async Task NavigatingDuringMetadataReloadDiscardsLateOldResults()
    {
        var repository = new SynologyPhotosTestRepository(); using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync(); var original = model.Items[0]; var delayed = new TaskCompletionSource<SynologyPhotoPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Read = (query, offset, _) => query is SynologyPhotoQuery.Search ? Task.FromResult(new SynologyPhotoPage([repository.Photo(9)], offset, offset + 1, false)) : delayed.Task;
        var applying = model.ApplyConfirmedChangesAsync(Guid.NewGuid(), [new(original, SynologyPhotoChangeState.Completed, original with { Rating = 5 })]);
        await model.SearchAsync("new"); delayed.SetResult(new([repository.Photo(2)], 0, 1, false)); await applying;
        Assert.Equal("new", model.SearchText); Assert.Equal(9, Assert.Single(model.Items).Id.ItemId); Assert.False(model.NeedsChangesRefresh);
    }

    [Fact]
    public async Task StaleSearchCompletionCannotOverwriteTheNewQuery()
    {
        var repository = new SynologyPhotosTestRepository();
        var delayed = new TaskCompletionSource<SynologyPhotoPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Read = (query, offset, token) => query is SynologyPhotoQuery.Search { Keyword: "old" }
            ? delayed.Task : Task.FromResult(new SynologyPhotoPage([repository.Photo(2)], offset, offset + 1, false));
        using var model = new SynologyPhotosWorkspace(repository);
        var old = model.SearchAsync("old");
        await model.SearchAsync("new");
        delayed.SetResult(new([repository.Photo(1)], 0, 1, false));
        await old;
        Assert.Equal("new", model.SearchText); Assert.Equal(2, Assert.Single(model.Items).Id.ItemId);
    }

    [Fact]
    public async Task RawPaginationDeduplicatesAcrossPagesWithoutReusingOffsets()
    {
        var repository = new SynologyPhotosTestRepository();
        repository.Read = (_, offset, _) => Task.FromResult(offset == 0
            ? new SynologyPhotoPage([repository.Photo(1), repository.Photo(2)], 0, 2, true)
            : new SynologyPhotoPage([repository.Photo(2), repository.Photo(3)], 2, 4, false));
        using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync(); await model.LoadNextAsync();
        Assert.Equal(new long[] { 1, 2, 3 }, model.Items.Select(photo => photo.Id.ItemId));
        Assert.Equal(new[] { 0, 2 }, repository.Calls.Select(call => call.Offset)); Assert.False(model.HasMore);
    }

    [Fact]
    public async Task RepeatedNonProgressPageStopsAutomaticRetry()
    {
        var repository = new SynologyPhotosTestRepository();
        repository.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([repository.Photo()], offset, offset + 1, true));
        using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync(); await model.LoadNextAsync(); await model.LoadNextAsync(automatic: true);
        Assert.Equal(2, repository.Calls.Count); Assert.NotNull(model.ErrorKey); Assert.Single(model.Items);
    }

    [Fact]
    public async Task MonthNavigationConstrainsBothEndsAndDoesNotScanTheLibrary()
    {
        var repository = new SynologyPhotosTestRepository();
        using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync(); await model.JumpToMonthAsync(new(2026, 8));
        Assert.True(model.HasPrevious); Assert.Equal(2, repository.Calls.Count);
        var query = Assert.IsType<SynologyPhotoQuery.Timeline>(repository.Calls[^1].Query);
        Assert.Equal(SynologyPhotosWorkspace.StartOfDay(new(2026, 9, 1)) - 1, query.End);
        repository.Read = (_, offset, _) => Task.FromResult(new SynologyPhotoPage([repository.Photo(2)], offset, offset + 1, false));
        await model.LoadPreviousAsync();
        Assert.False(model.HasPrevious); Assert.Equal(new long[] { 2, 1 }, model.Items.Select(photo => photo.Id.ItemId));
    }

    [Fact]
    public async Task FailedPreviousMonthKeepsBoundaryAndAllowsOnlyExplicitRetry()
    {
        var repository = new SynologyPhotosTestRepository();
        using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync(); await model.JumpToMonthAsync(new(2026, 8));
        repository.Read = (_, _, _) => Task.FromException<SynologyPhotoPage>(new IOException());
        await model.LoadPreviousAsync(); var count = repository.Calls.Count;
        await model.LoadPreviousAsync(automatic: true);
        Assert.Equal(count, repository.Calls.Count); Assert.Equal(202608, model.PreviousMonthId);
        Assert.NotNull(model.PreviousErrorKey); Assert.Single(model.Items);
    }

    [Fact]
    public async Task FilterAndSearchAreMutuallyExclusiveAndRetainTypedIds()
    {
        var repository = new SynologyPhotosTestRepository();
        using var model = new SynologyPhotosWorkspace(repository);
        await model.SearchAsync(" synthetic ");
        await model.ApplyFilterAsync(new() { PersonId = 17, CameraId = 18, Rating = 3 });
        Assert.Empty(model.SearchText);
        var query = Assert.IsType<SynologyPhotoQuery.Filtered>(repository.Calls[^1].Query);
        Assert.Equal(17, query.Filter.PersonId); Assert.Equal(18, query.Filter.CameraId);
        await model.SearchAsync("new"); Assert.False(model.Filter.IsActive);
    }

    [Fact]
    public async Task SuspendedWorkspaceIgnoresAnUncooperativeRepository()
    {
        var repository = new SynologyPhotosTestRepository();
        var delayed = new TaskCompletionSource<SynologyPhotoPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Read = (_, _, _) => delayed.Task;
        using var model = new SynologyPhotosWorkspace(repository);
        var pending = model.RefreshAsync(); model.Suspend();
        delayed.SetResult(new([repository.Photo()], 0, 1, false)); await pending;
        Assert.Empty(model.Items); Assert.False(model.HasLoaded); Assert.False(model.IsLoading);
    }

    [Fact]
    public async Task UnknownDeletionCanOnlyBeReviewedAndRemovesPhotoAfterConfirmedReadback()
    {
        var repository = new SynologyPhotosTestRepository();
        using var model = new SynologyPhotosWorkspace(repository);
        await model.RefreshAsync(); await model.Deletion.PrepareAsync(repository.Photo());
        Assert.Equal(0, repository.DeleteCalls);
        await model.Deletion.ConfirmAsync(); await model.Deletion.ConfirmAsync();
        await model.Deletion.PrepareAsync(repository.Photo(2));
        Assert.Equal(1, repository.DeleteCalls); Assert.NotNull(model.Deletion.Pending); Assert.Single(model.Items);
        repository.ReviewResult = SynologyPhotoDeletionResult.Confirmed;
        await model.Deletion.ReviewAsync();
        Assert.Equal(1, repository.DeleteCalls); Assert.Equal(1, repository.ReviewCalls); Assert.Empty(model.Items);
        await model.RefreshAsync(); Assert.Empty(model.Items);
    }

    [Fact]
    public async Task ClosedGateNeverPreparesOrSubmitsDeletion()
    {
        var repository = new SynologyPhotosTestRepository { CanDeleteOriginals = false, Prepare = () => throw new InvalidOperationException() };
        using var model = new SynologyPhotoDeletionModel(repository, _ => throw new InvalidOperationException());
        await model.PrepareAsync(repository.Photo()); await model.ConfirmAsync();
        Assert.Equal(0, repository.DeleteCalls); Assert.Null(model.Candidate); Assert.NotNull(model.ErrorKey);
    }

    [Fact]
    public async Task LateVideoSourceIsDisposedWhenPreviewCloses()
    {
        var repository = new SynologyPhotosTestRepository();
        var delayed = new TaskCompletionSource<IReadOnlyMediaSource>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Video = (_, _) => delayed.Task;
        using var preview = new SynologyPhotoPreviewModel(repository);
        var opening = preview.OpenAsync(repository.Photo(type: "video")); preview.Close();
        var media = new SynologyPhotosTestMedia(); delayed.SetResult(media); await opening;
        Assert.True(media.Disposed); Assert.Null(preview.MediaSource); Assert.Null(preview.Photo);
    }

    [Fact]
    public async Task CompletedTemporaryCleanupLeavesRemovedAlbumAndDoesNotRepeatRefresh()
    {
        var repository = new SynologyPhotosTestRepository { Albums = [new(61, "Synthetic temporary"), new(62, "Synthetic copy")] };
        repository.ReadAlbum = id => Task.FromResult(new SynologyPhotoAlbum(id, 1, 1, "Synthetic temporary", false, false, new('a', 64)) { ProfileId = repository.ProfileId });
        using var model = new SynologyPhotosWorkspace(repository); await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCollectionAsync(model.Collections[0]);
        var change = new SynologyPhotoTemporaryChange(Guid.NewGuid(), 61, 62, SynologyPhotoTemporaryStage.Finished, SynologyPhotoChangeState.Completed, null, false, true, false, false, false, null);
        await model.ApplyTemporaryChangeAsync(change); Assert.Null(model.Album); Assert.Null(model.CurrentAlbum); Assert.Equal(SynologyPhotosSection.Albums, model.Section);
        var calls = repository.AlbumCalls; await model.ApplyTemporaryChangeAsync(change); Assert.Equal(calls, repository.AlbumCalls);
    }
    [Fact]
    public async Task PendingTemporaryCleanupAndKeptCreationDoNotLeaveCurrentAlbum()
    {
        var repository = new SynologyPhotosTestRepository { Albums = [new(61, "Synthetic temporary")] };
        using var model = new SynologyPhotosWorkspace(repository); await model.SelectSectionAsync(SynologyPhotosSection.Albums); await model.OpenCollectionAsync(model.Collections[0]);
        var change = new SynologyPhotoTemporaryChange(Guid.NewGuid(), 61, null, SynologyPhotoTemporaryStage.Delete, SynologyPhotoChangeState.PendingReview, null, false, false, false, false, false, null);
        await model.ApplyTemporaryChangeAsync(change); Assert.Equal(61, model.Album?.Id);
        await model.ApplyTemporaryChangeAsync(change with { State = SynologyPhotoChangeState.Completed, FromCreation = true, Stage = SynologyPhotoTemporaryStage.Finished }); Assert.Equal(61, model.Album?.Id);
    }
    [Fact]
    public async Task LivePhotoReturnsToItsPosterAfterMotionFinishes()
    {
        var repository = new SynologyPhotosTestRepository();
        var source = new SynologyPhotosTestMedia(); repository.Video = (_, _) => Task.FromResult<IReadOnlyMediaSource>(source);
        using var preview = new SynologyPhotoPreviewModel(repository);
        await preview.OpenAsync(repository.Photo(type: "live")); var poster = preview.ImageBytes;
        await preview.PlayMotionAsync(); Assert.True(preview.IsPlayingMotion);
        preview.FinishMotion(); Assert.False(preview.IsPlayingMotion); Assert.True(source.Disposed);
        Assert.Same(poster, preview.ImageBytes);
    }
}
