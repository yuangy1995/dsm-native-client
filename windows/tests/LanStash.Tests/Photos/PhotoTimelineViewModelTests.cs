using LanStash.App.Features.Photos.Timeline;
using LanStash.Domain;

namespace LanStash.Tests.Photos;

public sealed class PhotoTimelineViewModelTests
{
    [Fact]
    public async Task FirstShowScansOnceAndCompletedSnapshotIsReused()
    {
        var profile = Guid.NewGuid();
        var source = new TimelineSource(profile, (_, _) => Task.FromResult(Snapshot(profile, [Image(profile, "one.jpg", "/photo/one.jpg")])));
        using var model = new PhotoTimelineViewModel();
        model.Activate(source, PhotoSpace.Shared);

        await model.ScanIfNeededAsync();
        await model.ScanIfNeededAsync();

        Assert.Equal(1, source.LoadCount);
        Assert.Equal(PhotoTimelinePhase.Content, model.Phase);
    }

    [Fact]
    public async Task FailedRefreshRestoresExactCompletedSnapshot()
    {
        var profile = Guid.NewGuid();
        var old = Image(profile, "old.jpg", "/photo/old.jpg");
        var call = 0;
        var source = new TimelineSource(profile, (_, _) => ++call == 1
            ? Task.FromResult(Snapshot(profile, [old]))
            : Task.FromException<PhotoTimelineSnapshot>(new IOException("offline")));
        using var model = new PhotoTimelineViewModel();
        model.Activate(source, PhotoSpace.Shared);
        await model.RefreshAsync();

        await model.RefreshAsync();

        Assert.Equal(PhotoTimelinePhase.Content, model.Phase);
        Assert.True(model.RefreshFailed);
        Assert.Equal([old.Path], model.Groups.SelectMany(group => group.Items).Select(item => item.Path));
    }

    [Fact]
    public async Task CancelledRefreshRestoresExactCompletedSnapshot()
    {
        var profile = Guid.NewGuid();
        var old = Image(profile, "old.jpg", "/photo/old.jpg");
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var call = 0;
        var source = new TimelineSource(profile, async (_, token) =>
        {
            if (++call == 1) return Snapshot(profile, [old]);
            started.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            throw new InvalidOperationException();
        });
        using var model = new PhotoTimelineViewModel();
        model.Activate(source, PhotoSpace.Shared);
        await model.RefreshAsync();
        var refresh = model.RefreshAsync();
        await started.Task;

        model.Cancel();
        await refresh;

        Assert.Equal(PhotoTimelinePhase.Content, model.Phase);
        Assert.Equal([old.Path], model.Groups.SelectMany(group => group.Items).Select(item => item.Path));
    }

    [Fact]
    public async Task SearchIsCaseAndDiacriticInsensitiveAndVideoFilterIsLocal()
    {
        var profile = Guid.NewGuid();
        var image = Image(profile, "Café.JPG", "/photo/Café.JPG");
        var video = Item(profile, "CAFETERIA.mov", "/photo/CAFETERIA.mov", PhotoItemKind.Video);
        var source = new TimelineSource(profile, (_, _) => Task.FromResult(Snapshot(profile, [image, video])));
        using var model = new PhotoTimelineViewModel();
        model.Activate(source, PhotoSpace.Shared);
        await model.RefreshAsync();

        model.Query = "cafe";
        await model.WaitForPendingQueryAsync();
        Assert.Equal(2, model.Groups.SelectMany(group => group.Items).Count());
        model.SetFilter(PhotoTimelineFilter.Videos);
        Assert.Equal([video.Path], model.Groups.SelectMany(group => group.Items).Select(item => item.Path));
        Assert.Equal(1, source.LoadCount);
    }

    [Fact]
    public async Task RapidQueriesOnlyApplyLastValueAndDisposePreventsLateWriteback()
    {
        var profile = Guid.NewGuid();
        var source = new TimelineSource(profile, (_, _) => Task.FromResult(Snapshot(profile,
            [Image(profile, "Café.jpg", "/photo/Café.jpg"), Image(profile, "Beach.jpg", "/photo/Beach.jpg")])));
        var model = new PhotoTimelineViewModel();
        model.Activate(source, PhotoSpace.Shared);
        await model.RefreshAsync();

        model.Query = "ca";
        model.Query = "cafe";
        await model.WaitForPendingQueryAsync();
        Assert.Equal(["Café.jpg"], model.Groups.SelectMany(group => group.Items).Select(item => item.Name));

        model.Query = "beach";
        var pending = model.WaitForPendingQueryAsync();
        model.Dispose();
        await pending;
        Assert.Empty(model.Groups);
    }

    [Fact]
    public async Task GroupsByCreatedThenModifiedMonthWithUnknownLastAndSurfacesLimits()
    {
        var profile = Guid.NewGuid();
        var created = Image(profile, "created.jpg", "/photo/created.jpg", new DateTimeOffset(2026, 8, 2, 0, 0, 0, TimeSpan.Zero));
        var unknown = Image(profile, "unknown.jpg", "/photo/unknown.jpg");
        var source = new TimelineSource(profile, (_, _) => Task.FromResult(new PhotoTimelineSnapshot(
            profile, PhotoSpaceIds.Shared, [unknown, created], 3, 1, 5, PhotoTimelineCompletion.Truncated)));
        using var model = new PhotoTimelineViewModel();
        model.Activate(source, PhotoSpace.Shared);
        await model.RefreshAsync();

        Assert.Equal("2026-08", model.Groups[0].Key);
        Assert.Equal("unknown", model.Groups[^1].Key);
        Assert.True(model.IsPartial);
        Assert.True(model.IsTruncated);
    }

    [Fact]
    public async Task VisibleJumpGroupsStayInDescendingCrossYearOrderAfterFiltering()
    {
        var profile = Guid.NewGuid();
        var source = new TimelineSource(profile, (_, _) => Task.FromResult(Snapshot(profile,
        [
            Image(profile, "february.jpg", "/photo/february.jpg", new DateTimeOffset(2026, 2, 1, 0, 0, 0, TimeSpan.Zero)),
            Image(profile, "january.jpg", "/photo/january.jpg", new DateTimeOffset(2026, 1, 1, 0, 0, 0, TimeSpan.Zero)),
            Image(profile, "december.jpg", "/photo/december.jpg", new DateTimeOffset(2025, 12, 1, 0, 0, 0, TimeSpan.Zero)),
            Image(profile, "unknown.jpg", "/photo/unknown.jpg"),
        ])));
        using var model = new PhotoTimelineViewModel();
        model.Activate(source, PhotoSpace.Shared);
        await model.RefreshAsync();

        Assert.Equal(["2026-02", "2026-01", "2025-12", "unknown"],
            model.Groups.Select(group => group.Key));

        model.Query = "december";
        await model.WaitForPendingQueryAsync();

        Assert.Equal(["2025-12"], model.Groups.Select(group => group.Key));
    }

    [Fact]
    public void MonthBoundaryUsesRequestedLocalTimeZoneBeforeGrouping()
    {
        var zone = TimeZoneInfo.CreateCustomTimeZone("test-plus-eight", TimeSpan.FromHours(8), "test", "test");
        var utc = new DateTimeOffset(2026, 7, 31, 16, 30, 0, TimeSpan.Zero);

        var month = PhotoTimelineViewModel.MonthStart(utc, zone);

        Assert.Equal("2026-08", month?.ToString("yyyy-MM"));
    }

    [Fact]
    public async Task FailedRefreshAfterEmptySnapshotRestoresEmptyNotFilteredEmpty()
    {
        var profile = Guid.NewGuid();
        var call = 0;
        var source = new TimelineSource(profile, (_, _) => ++call == 1
            ? Task.FromResult(Snapshot(profile, []))
            : Task.FromException<PhotoTimelineSnapshot>(new IOException("offline")));
        using var model = new PhotoTimelineViewModel();
        model.Activate(source, PhotoSpace.Shared);
        await model.RefreshAsync();

        await model.RefreshAsync();

        Assert.Equal(PhotoTimelinePhase.Empty, model.Phase);
        Assert.True(model.RefreshFailed);
        Assert.Empty(model.Groups);
    }

    [Fact]
    public async Task EmptyAndFilteredEmptyBaselinesRemainAvailableWhileRefreshing()
    {
        var profile = Guid.NewGuid();
        var pending = new TaskCompletionSource<PhotoTimelineSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var call = 0;
        var source = new TimelineSource(profile, (_, _) => ++call == 1
            ? Task.FromResult(Snapshot(profile, []))
            : pending.Task);
        using var model = new PhotoTimelineViewModel();
        model.Activate(source, PhotoSpace.Shared);
        await model.RefreshAsync();

        var refresh = model.RefreshAsync();
        Assert.Equal(PhotoTimelinePhase.Scanning, model.Phase);
        Assert.True(model.HasCompletedSnapshot);
        Assert.True(model.CommittedIsEmpty);
        Assert.Empty(model.Groups);
        model.Cancel();
        pending.SetResult(Snapshot(profile, []));
        await refresh;
        Assert.Equal(PhotoTimelinePhase.Empty, model.Phase);

        var pendingFiltered = new TaskCompletionSource<PhotoTimelineSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var filteredCall = 0;
        var filteredSource = new TimelineSource(profile, (_, _) => ++filteredCall == 1
            ? Task.FromResult(Snapshot(profile, [Image(profile, "one.jpg", "/photo/one.jpg")]))
            : pendingFiltered.Task);
        using var filteredModel = new PhotoTimelineViewModel();
        filteredModel.Activate(filteredSource, PhotoSpace.Shared);
        await filteredModel.RefreshAsync();
        filteredModel.Query = "missing";
        await filteredModel.WaitForPendingQueryAsync();

        var filteredRefresh = filteredModel.RefreshAsync();
        Assert.Equal(PhotoTimelinePhase.Scanning, filteredModel.Phase);
        Assert.True(filteredModel.HasCompletedSnapshot);
        Assert.False(filteredModel.CommittedIsEmpty);
        Assert.Empty(filteredModel.Groups);
        filteredModel.Cancel();
        pendingFiltered.SetResult(Snapshot(profile, []));
        await filteredRefresh;
        Assert.Equal(PhotoTimelinePhase.Content, filteredModel.Phase);
    }

    [Theory]
    [InlineData("/photo", "/photo/a.jpg", true)]
    [InlineData("/photo", "/photos/a.jpg", false)]
    [InlineData("/photo", "/photo//a.jpg", false)]
    [InlineData("/photo", "/photo/./a.jpg", false)]
    [InlineData("/photo", "/photo/x/../a.jpg", false)]
    [InlineData("/photo/", "/photo/a.jpg", false)]
    [InlineData("photo", "/photo/a.jpg", false)]
    [InlineData("/photo", "/photo/a.jpg/", false)]
    [InlineData("/photo", "\\photo\\a.jpg", false)]
    public void CanonicalContainmentRejectsAmbiguousAndEscapingPaths(string root, string path, bool expected) =>
        Assert.Equal(expected, PhotoTimelineViewModel.ContainsCanonicalPath(root, path));

    [Fact]
    public async Task RepositoryIdentityChangeClearsOldSnapshotAndLateOutcomeCannotApply()
    {
        var profile = Guid.NewGuid();
        var lateA = new TaskCompletionSource<PhotoTimelineSnapshot>(TaskCreationOptions.RunContinuationsAsynchronously);
        var sourceA = new TimelineSource(profile, (_, _) => lateA.Task);
        var b = Image(profile, "b.jpg", "/photo/b.jpg");
        var sourceB = new TimelineSource(profile, (_, _) => Task.FromResult(Snapshot(profile, [b])));
        using var model = new PhotoTimelineViewModel();
        model.Activate(sourceA, PhotoSpace.Shared);
        var oldRefresh = model.RefreshAsync();
        Assert.Equal(PhotoTimelinePhase.Scanning, model.Phase);

        model.Activate(sourceB, PhotoSpace.Shared);
        await model.RefreshAsync();
        lateA.SetResult(new PhotoTimelineSnapshot(
            profile,
            PhotoSpaceIds.Shared,
            [Image(profile, "must-not-apply.jpg", "/photo/must-not-apply.jpg")],
            9,
            4,
            99,
            PhotoTimelineCompletion.Truncated));
        await oldRefresh;

        Assert.Equal(PhotoTimelinePhase.Content, model.Phase);
        Assert.Equal([b.Path], model.Groups.SelectMany(group => group.Items).Select(item => item.Path));
        Assert.False(model.IsPartial);
        Assert.False(model.IsTruncated);
    }

    private static PhotoTimelineSnapshot Snapshot(Guid profile, IReadOnlyList<PhotoItem> items) =>
        new(profile, PhotoSpaceIds.Shared, items, 1, 0, items.Count, PhotoTimelineCompletion.Complete);

    private static PhotoItem Image(Guid profile, string name, string path, DateTimeOffset? created = null) =>
        Item(profile, name, path, PhotoItemKind.Image, created);

    private static PhotoItem Item(Guid profile, string name, string path, PhotoItemKind kind, DateTimeOffset? created = null) =>
        new(profile, path, name, path, kind, 12, created, null, Path.GetExtension(path), kind == PhotoItemKind.Image);

    private sealed class TimelineSource(
        Guid profileId,
        Func<PhotoSpace, CancellationToken, Task<PhotoTimelineSnapshot>> load) : IPhotoTimelineDataSource
    {
        public Guid ProfileId { get; } = profileId;
        public int LoadCount { get; private set; }
        public Task<PhotoTimelineSnapshot> LoadAsync(PhotoSpace space, CancellationToken cancellationToken)
        { LoadCount++; return load(space, cancellationToken); }
        public Task<IReadOnlyList<PhotoSpace>> DiscoverSpacesAsync(CancellationToken cancellationToken) => Task.FromResult<IReadOnlyList<PhotoSpace>>([PhotoSpace.Shared]);
        public Task<PhotoPage> LoadPageAsync(PhotoSpace space, string path, int offset, int limit, CancellationToken cancellationToken) => throw new NotSupportedException();
        public Task<PhotoThumbnail> LoadThumbnailAsync(PhotoItem item, PhotoThumbnailSize size, CancellationToken cancellationToken) => Task.FromResult(new PhotoThumbnail([1], "image/jpeg"));
    }
}
