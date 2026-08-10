using LanStash.App.Features.Photos;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class PhotoBrowserViewModelTests
{
    [Fact]
    public async Task ZeroOneAndTwoSpacesProduceStableInitialStates()
    {
        var emptySource = new FakePhotoSource(Guid.NewGuid(), []);
        using var empty = new PhotoBrowserViewModel();
        await empty.ActivateAsync(emptySource);
        Assert.Equal(PhotoBrowserContentState.Empty, empty.ContentState);
        Assert.Empty(emptySource.PageRequests);

        var oneProfile = Guid.NewGuid();
        var oneSource = new FakePhotoSource(oneProfile, [PhotoSpace.Shared]);
        oneSource.Add(Page(oneProfile, PhotoSpace.Shared.RootPath, 0, 1, false,
            Image(oneProfile, "/photo/one.jpg")));
        using var one = new PhotoBrowserViewModel();
        await one.ActivateAsync(oneSource);
        Assert.Equal(PhotoSpaceIds.Shared, one.SelectedSpace?.Id);
        Assert.Equal("one.jpg", Assert.Single(one.Items).Name);

        var twoProfile = Guid.NewGuid();
        var twoSource = new FakePhotoSource(twoProfile, [PhotoSpace.Personal, PhotoSpace.Shared]);
        twoSource.Add(Page(twoProfile, PhotoSpace.Personal.RootPath, 0, 0, false));
        using var two = new PhotoBrowserViewModel();
        await two.ActivateAsync(twoSource);
        Assert.Equal([PhotoSpaceIds.Personal, PhotoSpaceIds.Shared], two.Spaces.Select(x => x.Id));
        Assert.Equal(PhotoSpaceIds.Personal, two.SelectedSpace?.Id);
    }

    [Fact]
    public async Task RawOffsetAdvancesAcrossInvisibleAndEmptyMediaPages()
    {
        var profile = Guid.NewGuid();
        var source = new FakePhotoSource(profile, [PhotoSpace.Shared]);
        source.Add(Page(profile, "/photo", 0, 2, true,
            Video(profile, "/photo/clip.mov")));
        source.Add(Page(profile, "/photo", 2, 4, true));
        source.Add(Page(profile, "/photo", 4, 5, false,
            Image(profile, "/photo/final.jpg")));
        using var model = new PhotoBrowserViewModel(pageSize: 2);

        await model.ActivateAsync(source);
        Assert.Equal("clip.mov", Assert.Single(model.Items).Name);
        Assert.True(model.CanLoadMore);
        await model.LoadMoreAsync();
        Assert.Equal("clip.mov", Assert.Single(model.Items).Name);
        Assert.True(model.CanLoadMore);
        await model.LoadMoreAsync();

        Assert.Equal(["clip.mov", "final.jpg"], model.Items.Select(item => item.Name));
        Assert.Equal([0, 2, 4], source.PageRequests.Select(request => request.Offset));
    }

    [Fact]
    public async Task CrossPagePathsAreDeduplicatedWithoutChangingRawOffset()
    {
        var profile = Guid.NewGuid();
        var source = new FakePhotoSource(profile, [PhotoSpace.Shared]);
        var first = Image(profile, "/photo/a.jpg");
        source.Add(Page(profile, "/photo", 0, 2, true, first));
        source.Add(Page(profile, "/photo", 2, 4, false,
            first, Image(profile, "/photo/b.jpg")));
        using var model = new PhotoBrowserViewModel();
        await model.ActivateAsync(source);
        await model.LoadMoreAsync();

        Assert.Equal(["/photo/a.jpg", "/photo/b.jpg"], model.Items.Select(item => item.Path));
        Assert.Equal([0, 2], source.PageRequests.Select(request => request.Offset));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task MisalignedOrZeroProgressPageEntersOrRetainsError(bool firstPage)
    {
        var profile = Guid.NewGuid();
        var source = new FakePhotoSource(profile, [PhotoSpace.Shared]);
        if (firstPage)
        {
            source.Add(new PhotoPage(profile, "/photo", [], 1, 1, 1, false));
        }
        else
        {
            source.Add(Page(profile, "/photo", 0, 1, true, Image(profile, "/photo/a.jpg")));
            source.Add(new PhotoPage(profile, "/photo", [], 1, 1, 2, true));
        }
        using var model = new PhotoBrowserViewModel();
        await model.ActivateAsync(source);
        if (!firstPage)
        {
            await model.LoadMoreAsync();
            Assert.Equal("a.jpg", Assert.Single(model.Items).Name);
            Assert.True(model.HasLoadMoreError);
        }
        else
        {
            Assert.Equal(PhotoBrowserContentState.Error, model.ContentState);
        }
    }

    [Fact]
    public async Task LoadMoreFailureKeepsExistingContentAndAllowsRetry()
    {
        var profile = Guid.NewGuid();
        var source = new FakePhotoSource(profile, [PhotoSpace.Shared]);
        source.Add(Page(profile, "/photo", 0, 1, true, Image(profile, "/photo/a.jpg")));
        source.Add(new IOException("synthetic"));
        source.Add(Page(profile, "/photo", 1, 2, false, Image(profile, "/photo/b.jpg")));
        using var model = new PhotoBrowserViewModel();
        await model.ActivateAsync(source);

        await model.LoadMoreAsync();
        Assert.Equal("a.jpg", Assert.Single(model.Items).Name);
        Assert.True(model.HasLoadMoreError);
        await model.LoadMoreAsync();

        Assert.Equal(["a.jpg", "b.jpg"], model.Items.Select(item => item.Name));
        Assert.False(model.HasLoadMoreError);
    }

    [Fact]
    public async Task BackSpaceAndProfileSwitchRestoreCachedPagesWithoutRequests()
    {
        var profileA = Guid.NewGuid();
        var sourceA = new FakePhotoSource(profileA, [PhotoSpace.Personal, PhotoSpace.Shared]);
        sourceA.Add(Page(profileA, PhotoSpace.Personal.RootPath, 0, 1, false,
            Folder(profileA, "/home/Photos/album")));
        sourceA.Add(Page(profileA, "/home/Photos/album", 0, 1, false,
            Image(profileA, "/home/Photos/album/a.jpg")));
        sourceA.Add(Page(profileA, PhotoSpace.Shared.RootPath, 0, 1, false,
            Image(profileA, "/photo/shared.jpg")));
        var profileB = Guid.NewGuid();
        var sourceB = new FakePhotoSource(profileB, [PhotoSpace.Shared]);
        sourceB.Add(Page(profileB, "/photo", 0, 1, false, Image(profileB, "/photo/b.jpg")));
        using var model = new PhotoBrowserViewModel();

        await model.ActivateAsync(sourceA);
        await model.OpenFolderAsync(model.Items.Single());
        var beforeBack = sourceA.PageRequests.Count;
        await model.GoBackAsync();
        Assert.Equal(beforeBack, sourceA.PageRequests.Count);
        Assert.Equal("album", Assert.Single(model.Items).Name);
        Assert.Equal(
            [PhotoSpace.Personal.Title],
            model.Breadcrumbs.Select(item => item.Name));

        await model.SelectSpaceAsync(PhotoSpaceIds.Shared);
        await model.SelectSpaceAsync(PhotoSpaceIds.Personal);
        Assert.Equal(3, sourceA.PageRequests.Count);
        Assert.Equal("album", Assert.Single(model.Items).Name);

        await model.ActivateAsync(sourceB);
        await model.ActivateAsync(sourceA);
        Assert.Equal(3, sourceA.PageRequests.Count);
        Assert.Equal(PhotoSpaceIds.Personal, model.SelectedSpace?.Id);
        Assert.Equal("album", Assert.Single(model.Items).Name);
    }

    [Fact]
    public async Task OnePageCacheEvictsLeastRecentlyUsedLocation()
    {
        var profile = Guid.NewGuid();
        var source = new FakePhotoSource(profile, [PhotoSpace.Shared]);
        source.Add(Page(profile, "/photo", 0, 1, false, Folder(profile, "/photo/album")));
        source.Add(Page(profile, "/photo/album", 0, 1, false, Image(profile, "/photo/album/a.jpg")));
        source.Add(Page(profile, "/photo", 0, 1, false, Folder(profile, "/photo/album")));
        using var model = new PhotoBrowserViewModel(cachedPagesPerProfile: 1);

        await model.ActivateAsync(source);
        await model.OpenFolderAsync(model.Items.Single());
        await model.GoBackAsync();

        Assert.Equal(3, source.PageRequests.Count);
        Assert.Equal("album", Assert.Single(model.Items).Name);
    }

    [Fact]
    public async Task ImagesFilterUsesFilteredEmptyStateWithoutNewRequest()
    {
        var profile = Guid.NewGuid();
        var source = new FakePhotoSource(profile, [PhotoSpace.Shared]);
        source.Add(Page(profile, "/photo", 0, 2, false,
            Folder(profile, "/photo/folder"), Video(profile, "/photo/video.mov")));
        using var model = new PhotoBrowserViewModel();
        await model.ActivateAsync(source);

        model.SetFilter(PhotoBrowserFilter.Images);

        Assert.Equal(PhotoBrowserContentState.FilteredEmpty, model.ContentState);
        Assert.Empty(model.Items);
        Assert.Single(source.PageRequests);
    }

    [Fact]
    public async Task FilterHasSeparateCacheAndVideoRemainsInAllMediaView()
    {
        var profile = Guid.NewGuid();
        var source = new FakePhotoSource(profile, [PhotoSpace.Shared]);
        source.Add(Page(profile, "/photo", 0, 3, false,
            Folder(profile, "/photo/folder"),
            Image(profile, "/photo/image.jpg"),
            Video(profile, "/photo/video.mov")));
        using var model = new PhotoBrowserViewModel();
        await model.ActivateAsync(source);

        Assert.Equal(["folder", "image.jpg", "video.mov"], model.Items.Select(item => item.Name));
        model.SetFilter(PhotoBrowserFilter.Images);
        Assert.Equal("image.jpg", Assert.Single(model.Items).Name);
        model.SetFilter(PhotoBrowserFilter.All);

        Assert.Equal(["folder", "image.jpg", "video.mov"], model.Items.Select(item => item.Name));
        Assert.Single(source.PageRequests);
    }

    [Fact]
    public async Task ProfileSwitchCancelsAndRejectsLateOldResponse()
    {
        var profileA = Guid.NewGuid();
        var profileB = Guid.NewGuid();
        var sourceA = new ControlledPhotoSource(profileA, [PhotoSpace.Shared]);
        var sourceB = new FakePhotoSource(profileB, [PhotoSpace.Shared]);
        sourceB.Add(Page(profileB, "/photo", 0, 1, false, Image(profileB, "/photo/b.jpg")));
        using var model = new PhotoBrowserViewModel();

        var oldActivation = model.ActivateAsync(sourceA);
        await sourceA.WaitForPageRequestAsync();
        await model.ActivateAsync(sourceB);
        sourceA.Complete(Page(profileA, "/photo", 0, 1, false, Image(profileA, "/photo/a.jpg")));
        await oldActivation;

        Assert.True(sourceA.PageCancellation.IsCancellationRequested);
        Assert.Equal(profileB, model.ActiveProfileId);
        Assert.Equal("b.jpg", Assert.Single(model.Items).Name);
    }

    [Fact]
    public async Task NewFolderGenerationRejectsLateOldPathResponse()
    {
        var profile = Guid.NewGuid();
        var source = new MultiControlledPhotoSource(profile, [PhotoSpace.Shared]);
        using var model = new PhotoBrowserViewModel();
        var activation = model.ActivateAsync(source);
        await source.WaitForRequestCountAsync(1);
        var folderA = Folder(profile, "/photo/a");
        var folderB = Folder(profile, "/photo/b");
        source.Complete(0, Page(profile, "/photo", 0, 2, false, folderA, folderB));
        await activation;
        var entryA = model.Items.Single(item => item.Path == folderA.Path);
        var entryB = model.Items.Single(item => item.Path == folderB.Path);

        var oldNavigation = model.OpenFolderAsync(entryA);
        await source.WaitForRequestCountAsync(2);
        var newNavigation = model.OpenFolderAsync(entryB);
        await source.WaitForRequestCountAsync(3);
        source.Complete(2, Page(profile, folderB.Path, 0, 1, false,
            Image(profile, "/photo/b/new.jpg")));
        source.Complete(1, Page(profile, folderA.Path, 0, 1, false,
            Image(profile, "/photo/a/stale.jpg")));
        await Task.WhenAll(oldNavigation, newNavigation);

        Assert.True(source.Requests[1].Cancellation.IsCancellationRequested);
        Assert.Equal(folderB.Path, model.CurrentPath);
        Assert.Equal("new.jpg", Assert.Single(model.Items).Name);
    }

    [Fact]
    public async Task DisposeCancelsOutstandingRequestAndModelHasNoWriteSurface()
    {
        var profile = Guid.NewGuid();
        var source = new ControlledPhotoSource(profile, [PhotoSpace.Shared]);
        var model = new PhotoBrowserViewModel();
        var activation = model.ActivateAsync(source);
        await source.WaitForPageRequestAsync();

        model.Dispose();
        source.Complete(Page(profile, "/photo", 0, 0, false));
        await activation;

        Assert.True(source.PageCancellation.IsCancellationRequested);
        var production = File.ReadAllText(Path.Combine(
            RepositoryRoot(),
            "windows", "src", "LanStash.App", "Features", "Photos", "PhotoBrowserViewModel.cs"));
        foreach (var forbidden in new[] { "Upload", "Delete", "Move", "Search", "Timeline" })
        {
            Assert.DoesNotContain(forbidden, production, StringComparison.Ordinal);
        }
    }

    private static PhotoPage Page(
        Guid profile,
        string path,
        int offset,
        int nextOffset,
        bool hasMore,
        params PhotoItem[] items) =>
        new(profile, path, items, offset, nextOffset, hasMore ? nextOffset + 1 : nextOffset, hasMore);

    private static PhotoItem Folder(Guid profile, string path) =>
        Item(profile, path, PhotoItemKind.Folder);

    private static PhotoItem Image(Guid profile, string path) =>
        Item(profile, path, PhotoItemKind.Image);

    private static PhotoItem Video(Guid profile, string path) =>
        Item(profile, path, PhotoItemKind.Video);

    private static PhotoItem Item(Guid profile, string path, PhotoItemKind kind) => new(
        profile,
        $"{profile:N}:{path}",
        Path.GetFileName(path),
        path,
        kind,
        kind == PhotoItemKind.Folder ? null : 10,
        null,
        DateTimeOffset.Parse("2026-01-01T00:00:00Z"),
        kind == PhotoItemKind.Folder ? null : Path.GetExtension(path).TrimStart('.'),
        kind == PhotoItemKind.Image);

    private sealed class FakePhotoSource(Guid profileId, IReadOnlyList<PhotoSpace> spaces)
        : IPhotoBrowserDataSource
    {
        private readonly Queue<object> _pages = [];
        public Guid ProfileId { get; } = profileId;
        public List<(string SpaceId, string Path, int Offset)> PageRequests { get; } = [];
        public void Add(PhotoPage page) => _pages.Enqueue(page);
        public void Add(Exception error) => _pages.Enqueue(error);
        public Task<IReadOnlyList<PhotoSpace>> DiscoverSpacesAsync(CancellationToken cancellationToken) =>
            Task.FromResult(spaces);
        public Task<PhotoPage> LoadPageAsync(
            PhotoSpace space, string path, int offset, int limit, CancellationToken cancellationToken)
        {
            PageRequests.Add((space.Id, path, offset));
            var next = _pages.Dequeue();
            return next is Exception error
                ? Task.FromException<PhotoPage>(error)
                : Task.FromResult((PhotoPage)next);
        }
        public Task<PhotoThumbnail> LoadThumbnailAsync(
            PhotoItem item, PhotoThumbnailSize size, CancellationToken cancellationToken) =>
            Task.FromResult(new PhotoThumbnail([1], "image/jpeg"));
    }

    private sealed class ControlledPhotoSource(Guid profileId, IReadOnlyList<PhotoSpace> spaces)
        : IPhotoBrowserDataSource
    {
        private readonly TaskCompletionSource<PhotoPage> _page =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Guid ProfileId { get; } = profileId;
        public CancellationToken PageCancellation { get; private set; }
        public Task<IReadOnlyList<PhotoSpace>> DiscoverSpacesAsync(CancellationToken cancellationToken) =>
            Task.FromResult(spaces);
        public Task<PhotoPage> LoadPageAsync(
            PhotoSpace space, string path, int offset, int limit, CancellationToken cancellationToken)
        {
            PageCancellation = cancellationToken;
            return _page.Task;
        }
        public Task<PhotoThumbnail> LoadThumbnailAsync(
            PhotoItem item, PhotoThumbnailSize size, CancellationToken cancellationToken) =>
            Task.FromResult(new PhotoThumbnail([1], "image/jpeg"));
        public void Complete(PhotoPage page) => _page.TrySetResult(page);
        public async Task WaitForPageRequestAsync()
        {
            for (var attempt = 0; attempt < 100 && PageCancellation == default; attempt++)
            {
                await Task.Yield();
            }
            Assert.NotEqual(default, PageCancellation);
        }
    }

    private sealed class MultiControlledPhotoSource(Guid profileId, IReadOnlyList<PhotoSpace> spaces)
        : IPhotoBrowserDataSource
    {
        private readonly List<TaskCompletionSource<PhotoPage>> _pages = [];
        public Guid ProfileId { get; } = profileId;
        public List<(string Path, CancellationToken Cancellation)> Requests { get; } = [];
        public Task<IReadOnlyList<PhotoSpace>> DiscoverSpacesAsync(CancellationToken cancellationToken) =>
            Task.FromResult(spaces);
        public Task<PhotoPage> LoadPageAsync(
            PhotoSpace space, string path, int offset, int limit, CancellationToken cancellationToken)
        {
            Requests.Add((path, cancellationToken));
            var page = new TaskCompletionSource<PhotoPage>(TaskCreationOptions.RunContinuationsAsynchronously);
            _pages.Add(page);
            return page.Task;
        }
        public Task<PhotoThumbnail> LoadThumbnailAsync(
            PhotoItem item, PhotoThumbnailSize size, CancellationToken cancellationToken) =>
            Task.FromResult(new PhotoThumbnail([1], "image/jpeg"));
        public void Complete(int index, PhotoPage page) => _pages[index].TrySetResult(page);
        public async Task WaitForRequestCountAsync(int expected)
        {
            for (var attempt = 0; attempt < 100 && Requests.Count < expected; attempt++)
            {
                await Task.Yield();
            }
            Assert.True(Requests.Count >= expected);
        }
    }

    private static string RepositoryRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory);
             directory is not null;
             directory = directory.Parent)
        {
            if (File.Exists(Path.Combine(directory.FullName, "AGENTS.md")))
            {
                return directory.FullName;
            }
        }
        throw new DirectoryNotFoundException();
    }
}
