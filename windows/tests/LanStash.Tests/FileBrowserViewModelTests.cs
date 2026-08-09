using LanStash.App.Features.Files;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class FileBrowserViewModelTests
{
    [Fact]
    public async Task LoadsSharedRootAndUsesRealOffsetAndLimitForMore()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 3, Directory("/homes", "homes"), Directory("/photo", "photo")));
        source.Enqueue(Page(2, 3, File("/video/movie.mkv", "movie.mkv")));
        using var model = new FileBrowserViewModel(source, pageSize: 2);

        await model.InitializeAsync();
        await model.LoadMoreAsync();

        Assert.Equal([0, 2], source.Requests.Select(request => request.Offset));
        Assert.All(source.Requests, request => Assert.Equal(FileListOptions.Default, request.Options));
        Assert.Equal(3, model.Items.Count);
        Assert.False(model.CanLoadMore);
        Assert.Equal(FileBrowserContentState.Content, model.ContentState);
    }

    [Fact]
    public async Task OpensDirectoryBuildsBreadcrumbsAndSupportsUpAndBackHistory()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 1, Directory("/homes", "homes")));
        source.Enqueue(Page(0, 1, Directory("/homes/alice", "alice")));
        source.Enqueue(Page(0, 1, Directory("/homes", "homes")));
        source.Enqueue(Page(0, 1, Directory("/homes/alice", "alice")));
        using var model = new FileBrowserViewModel(source);

        await model.InitializeAsync();
        await model.OpenAsync(model.Items.Single());
        await model.OpenAsync(model.Items.Single());

        Assert.Equal("/homes/alice", model.CurrentPath);
        Assert.Equal([string.Empty, "/homes", "/homes/alice"], model.Breadcrumbs.Select(item => item.Path));

        await model.GoUpAsync();
        Assert.Equal("/homes", model.CurrentPath);

        await model.GoBackAsync();
        Assert.Equal("/homes/alice", model.CurrentPath);
    }

    [Fact]
    public async Task BreadcrumbJumpRecordsHistory()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 1, Directory("/share", "share")));
        source.Enqueue(Page(0, 1, Directory("/share/folder", "folder")));
        source.Enqueue(Page(0, 1, File("/share/folder/file.txt", "file.txt")));
        source.Enqueue(Page(0, 1, Directory("/share/folder", "folder")));
        source.Enqueue(Page(0, 1, File("/share/folder/file.txt", "file.txt")));
        using var model = new FileBrowserViewModel(source);

        await model.InitializeAsync();
        await model.OpenAsync(model.Items.Single());
        await model.OpenAsync(model.Items.Single());
        await model.NavigateToBreadcrumbAsync(model.Breadcrumbs.Single(item => item.Path == "/share"));
        await model.GoBackAsync();

        Assert.Equal("/share/folder", model.CurrentPath);
    }

    [Theory]
    [InlineData(0, false, FileBrowserContentState.Empty)]
    [InlineData(1, true, FileBrowserContentState.FilteredEmpty)]
    public async Task DistinguishesEmptyAndFilteredEmpty(
        int itemCount,
        bool applyFilter,
        FileBrowserContentState expected)
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(itemCount == 0
            ? Page(0, 0)
            : Page(0, 1, File("/share/readme.txt", "readme.txt")));
        using var model = new FileBrowserViewModel(source);

        await model.InitializeAsync();
        if (applyFilter)
        {
            model.SetFilter("missing");
        }

        Assert.Equal(expected, model.ContentState);
    }

    [Fact]
    public async Task InitialFailureUsesErrorStateAndRetryCanRecover()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(new InvalidOperationException("synthetic"));
        source.Enqueue(Page(0, 1, File("/share/readme.txt", "readme.txt")));
        using var model = new FileBrowserViewModel(source);

        await model.InitializeAsync();
        Assert.Equal(FileBrowserContentState.Error, model.ContentState);

        await model.RefreshAsync();
        Assert.Equal(FileBrowserContentState.Content, model.ContentState);
        Assert.Single(model.Items);
    }

    [Fact]
    public async Task LoadMoreFailureKeepsExistingContentAndCanRetrySameOffset()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 2, File("/share/a.txt", "a.txt")));
        source.Enqueue(new InvalidOperationException("synthetic"));
        source.Enqueue(Page(1, 2, File("/share/b.txt", "b.txt")));
        using var model = new FileBrowserViewModel(source, pageSize: 1);

        await model.InitializeAsync();
        await model.LoadMoreAsync();

        Assert.Equal(FileBrowserContentState.Content, model.ContentState);
        Assert.True(model.HasLoadMoreError);
        Assert.Single(model.Items);

        await model.LoadMoreAsync();
        Assert.Equal([0, 1, 1], source.Requests.Select(request => request.Offset));
        Assert.Equal(2, model.Items.Count);
        Assert.False(model.HasLoadMoreError);
    }

    [Fact]
    public async Task RepeatedServerPathDoesNotAppendDuplicateEntry()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 3,
            File("/share/a.txt", "a.txt"),
            File("/share/b.txt", "b.txt")));
        source.Enqueue(Page(2, 4,
            File("/share/b.txt", "b.txt"),
            File("/share/c.txt", "c.txt")));
        using var model = new FileBrowserViewModel(source, pageSize: 2);

        await model.InitializeAsync();
        await model.LoadMoreAsync();

        Assert.Equal(3, model.Items.Count);
        Assert.Equal(3, model.Items.Select(item => item.Path).Distinct(StringComparer.Ordinal).Count());
        Assert.Equal([0, 2], source.Requests.Select(request => request.Offset));
    }

    [Fact]
    public async Task EmptyFirstPageThatReportsMoreItemsEntersStableErrorState()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 3));
        using var model = new FileBrowserViewModel(source, pageSize: 2);

        await model.InitializeAsync();

        Assert.Equal(FileBrowserContentState.Error, model.ContentState);
        Assert.Empty(model.Items);
        Assert.False(model.CanLoadMore);
        Assert.Single(source.Requests);
    }

    [Fact]
    public async Task EmptyLoadMorePageKeepsContentAndDoesNotRequestAgainAutomatically()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 3, File("/share/a.txt", "a.txt")));
        source.Enqueue(Page(1, 3));
        using var model = new FileBrowserViewModel(source, pageSize: 1);

        await model.InitializeAsync();
        await model.LoadMoreAsync();

        Assert.Equal(FileBrowserContentState.Content, model.ContentState);
        Assert.True(model.HasLoadMoreError);
        Assert.Single(model.Items);
        Assert.Equal([0, 1], source.Requests.Select(request => request.Offset));
    }

    [Fact]
    public async Task BackwardLoadMoreOffsetKeepsContentAndOriginalNextOffset()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 3, File("/share/a.txt", "a.txt")));
        source.Enqueue(Page(0, 3, File("/share/b.txt", "b.txt")));
        source.Enqueue(Page(1, 3, File("/share/b.txt", "b.txt")));
        using var model = new FileBrowserViewModel(source, pageSize: 1);

        await model.InitializeAsync();
        await model.LoadMoreAsync();

        Assert.True(model.HasLoadMoreError);
        Assert.Equal(["/share/a.txt"], model.Items.Select(item => item.Path));

        await model.LoadMoreAsync();
        Assert.Equal([0, 1, 1], source.Requests.Select(request => request.Offset));
        Assert.Equal(2, model.Items.Count);
    }

    [Fact]
    public async Task NewNavigationCancelsAndSupersedesOlderRequest()
    {
        var source = new ControlledFileBrowserDataSource();
        using var model = new FileBrowserViewModel(source);
        var initial = model.InitializeAsync();
        source.CompleteNext(Page(0, 1, Directory("/share", "share")));
        await initial;

        var oldNavigation = model.OpenAsync(model.Items.Single());
        await source.WaitForRequestCountAsync(2);
        var root = model.Breadcrumbs.Single(item => item.Path == string.Empty);
        var newNavigation = model.NavigateToBreadcrumbAsync(root);

        source.CompleteAt(1, Page(0, 1, File("/share/stale.txt", "stale.txt")));
        await Task.WhenAll(oldNavigation, newNavigation);

        Assert.Equal(string.Empty, model.CurrentPath);
        Assert.Equal("share", model.Items.Single().Name);
        Assert.Equal(2, source.Requests.Count);
        Assert.True(source.Requests[1].Cancellation.IsCancellationRequested);
    }

    [Fact]
    public async Task SelectionSurvivesLayoutChangeAndFilterWhenEntryRemainsVisible()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 2,
            File("/share/alpha.txt", "alpha.txt"),
            File("/share/beta.txt", "beta.txt")));
        using var model = new FileBrowserViewModel(source);
        await model.InitializeAsync();
        model.SelectedItem = model.Items[0];

        model.Layout = FileBrowserLayout.Grid;
        model.SetFilter("alpha");

        Assert.Equal(FileBrowserLayout.Grid, model.Layout);
        Assert.Equal("/share/alpha.txt", model.SelectedItem?.Path);
    }

    [Fact]
    public async Task DisposeCancelsOutstandingRequestAndPreventsPublication()
    {
        var source = new ControlledFileBrowserDataSource();
        var model = new FileBrowserViewModel(source);
        var load = model.InitializeAsync();
        await source.WaitForRequestCountAsync(1);

        model.Dispose();
        source.CompleteAt(0, Page(0, 1, File("/late.txt", "late.txt")));
        await load;

        Assert.True(source.Requests[0].Cancellation.IsCancellationRequested);
        Assert.Empty(model.Items);
    }

    [Fact]
    public async Task LoadMoreUsesTheSameEffectiveOptionsAsTheFirstPage()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 1, Directory("/share", "share")));
        source.Enqueue(Page(0, 2, File("/share/a.txt", "a.txt")));
        source.Enqueue(Page(0, 2, File("/share/a.txt", "a.txt")));
        source.Enqueue(Page(0, 2, File("/share/a.txt", "a.txt")));
        source.Enqueue(Page(0, 2, File("/share/a.txt", "a.txt")));
        source.Enqueue(Page(0, 2, File("/share/a.txt", "a.txt")));
        source.Enqueue(Page(1, 2, File("/share/b.txt", "b.txt")));
        using var model = new FileBrowserViewModel(source, pageSize: 1);

        await model.InitializeAsync();
        await model.OpenAsync(model.Items.Single());
        await model.SetSortFieldAsync(FileListSortField.Size);
        await model.SetSortDirectionAsync(FileListSortDirection.Descending);
        await model.SetTypeFilterAsync(FileListTypeFilter.Files);

        await model.RefreshAsync();
        await model.LoadMoreAsync();

        var expected = new FileListOptions(
            FileListSortField.Size,
            FileListSortDirection.Descending,
            FileListTypeFilter.Files);
        Assert.Equal(expected, source.Requests[^2].Options);
        Assert.Equal(expected, source.Requests[^1].Options);
        Assert.Equal([0, 1], source.Requests.TakeLast(2).Select(request => request.Offset));
    }

    [Fact]
    public async Task SharedRootNormalizesEffectiveOptionsAndRestoresDirectoryPreference()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 1, Directory("/share", "share")));
        source.Enqueue(Page(0, 1, File("/share/a.txt", "a.txt")));
        source.Enqueue(Page(0, 1, File("/share/a.txt", "a.txt")));
        source.Enqueue(Page(0, 1, File("/share/a.txt", "a.txt")));
        source.Enqueue(Page(0, 1, File("/share/a.txt", "a.txt")));
        using var model = new FileBrowserViewModel(source);

        await model.InitializeAsync();
        await model.OpenAsync(model.Items.Single());
        await model.SetSortFieldAsync(FileListSortField.Size);
        await model.SetTypeFilterAsync(FileListTypeFilter.Files);
        await model.SetSortDirectionAsync(FileListSortDirection.Descending);
        await model.GoBackAsync();

        Assert.Equal(
            new FileListOptions(
                FileListSortField.Name,
                FileListSortDirection.Ascending,
                FileListTypeFilter.All),
            model.CurrentOptions);
        Assert.False(model.CanChooseNonNameSort);
        Assert.False(model.CanChooseTypeFilter);

        await model.OpenAsync(model.Items.Single());

        Assert.Equal(
            new FileListOptions(
                FileListSortField.Size,
                FileListSortDirection.Descending,
                FileListTypeFilter.Files),
            model.CurrentOptions);
    }

    [Fact]
    public async Task DifferentOptionsUseSeparateCacheAndSwitchingBackDoesNotRequestAgain()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 1, Directory("/share", "share")));
        source.Enqueue(Page(0, 1, File("/share/name.txt", "name.txt")));
        source.Enqueue(Page(0, 1, File("/share/size.txt", "size.txt")));
        using var model = new FileBrowserViewModel(source);

        await model.InitializeAsync();
        await model.OpenAsync(model.Items.Single());
        await model.SetSortFieldAsync(FileListSortField.Size);
        var requestCount = source.Requests.Count;

        await model.SetSortFieldAsync(FileListSortField.Name);

        Assert.Equal(requestCount, source.Requests.Count);
        Assert.Equal("name.txt", model.Items.Single().Name);
        Assert.Equal(FileListSortField.Name, model.SortField);
    }

    [Fact]
    public async Task BackRestoresMultiplePagesSelectionQuickFilterAndOptionsWithoutRequest()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 1, Directory("/share", "share")));
        source.Enqueue(Page(0, 1, Directory("/share", "share")));
        source.Enqueue(Page(0, 2, Directory("/share/sub", "sub")));
        source.Enqueue(Page(1, 2, File("/share/other.txt", "other.txt")));
        source.Enqueue(Page(0, 0));
        using var model = new FileBrowserViewModel(source, pageSize: 1);

        await model.InitializeAsync();
        await model.SetSortDirectionAsync(FileListSortDirection.Descending);
        await model.OpenAsync(model.Items.Single());
        await model.LoadMoreAsync();
        model.SetFilter("sub");
        model.SelectedItem = model.Items.Single();
        await model.OpenAsync(model.SelectedItem);
        var requestCount = source.Requests.Count;

        await model.GoBackAsync();

        Assert.Equal(requestCount, source.Requests.Count);
        Assert.Equal("/share", model.CurrentPath);
        Assert.Equal("sub", model.FilterText);
        Assert.Equal("/share/sub", model.SelectedItem?.Path);
        Assert.Equal(FileListSortDirection.Descending, model.SortDirection);
        Assert.False(model.CanLoadMore);
    }

    [Fact]
    public async Task ServerTypeFilterEmptyIsFilteredEmptyAndClearRestoresAllCache()
    {
        var source = new FakeFileBrowserDataSource();
        source.Enqueue(Page(0, 1, Directory("/share", "share")));
        source.Enqueue(Page(0, 1, Directory("/share/folder", "folder")));
        source.Enqueue(Page(0, 0));
        using var model = new FileBrowserViewModel(source);

        await model.InitializeAsync();
        await model.OpenAsync(model.Items.Single());
        await model.SetTypeFilterAsync(FileListTypeFilter.Files);

        Assert.Equal(FileBrowserContentState.FilteredEmpty, model.ContentState);
        Assert.Equal(FileListTypeFilter.Files, model.TypeFilter);
        var requestCount = source.Requests.Count;

        await model.ClearFiltersAsync();

        Assert.Equal(requestCount, source.Requests.Count);
        Assert.Equal(FileListTypeFilter.All, model.TypeFilter);
        Assert.Equal(FileBrowserContentState.Content, model.ContentState);
        Assert.Equal("folder", model.Items.Single().Name);
    }

    [Fact]
    public async Task NewOptionGenerationRejectsLateOldResponse()
    {
        var source = new ControlledFileBrowserDataSource();
        using var model = new FileBrowserViewModel(source);
        var initial = model.InitializeAsync();
        source.CompleteAt(0, Page(0, 1, Directory("/share", "share")));
        await initial;

        var navigation = model.OpenAsync(model.Items.Single());
        await source.WaitForRequestCountAsync(2);
        var sort = model.SetSortFieldAsync(FileListSortField.Size);
        await source.WaitForRequestCountAsync(3);
        source.CompleteAt(2, Page(0, 1, File("/share/new.txt", "new.txt")));
        source.CompleteAt(1, Page(0, 1, File("/share/stale.txt", "stale.txt")));
        await Task.WhenAll(navigation, sort);

        Assert.True(source.Requests[1].Cancellation.IsCancellationRequested);
        Assert.Equal(FileListSortField.Size, model.SortField);
        Assert.Equal("new.txt", model.Items.Single().Name);
    }

    private static FilePage Page(int offset, int total, params FileItem[] items) =>
        new(items, total, offset);

    private static FileItem Directory(string path, string name) =>
        new(path, name, true, 0, null, null, true, true);

    private static FileItem File(string path, string name) =>
        new(path, name, false, 42, DateTimeOffset.Parse("2026-01-01T00:00:00Z"), "owner", true, true);

    private sealed class FakeFileBrowserDataSource : IFileBrowserDataSource
    {
        private readonly Queue<object> _results = new();

        public List<(string Path, int Offset, int Limit, FileListOptions Options)> Requests { get; } = [];

        public void Enqueue(FilePage page) => _results.Enqueue(page);
        public void Enqueue(Exception exception) => _results.Enqueue(exception);

        public Task<FilePage> LoadPageAsync(
            string path,
            int offset,
            int limit,
            FileListOptions options,
            CancellationToken cancellationToken)
        {
            Requests.Add((path, offset, limit, options));
            var result = _results.Dequeue();
            return result is Exception exception
                ? Task.FromException<FilePage>(exception)
                : Task.FromResult((FilePage)result);
        }
    }

    private sealed class ControlledFileBrowserDataSource : IFileBrowserDataSource
    {
        private readonly List<TaskCompletionSource<FilePage>> _completions = [];

        public List<(string Path, int Offset, int Limit, FileListOptions Options, CancellationToken Cancellation)> Requests { get; } = [];

        public Task<FilePage> LoadPageAsync(
            string path,
            int offset,
            int limit,
            FileListOptions options,
            CancellationToken cancellationToken)
        {
            Requests.Add((path, offset, limit, options, cancellationToken));
            var completion = new TaskCompletionSource<FilePage>(TaskCreationOptions.RunContinuationsAsynchronously);
            _completions.Add(completion);
            return completion.Task;
        }

        public void CompleteNext(FilePage page) => CompleteAt(0, page);

        public void CompleteAt(int index, FilePage page) => _completions[index].TrySetResult(page);

        public async Task WaitForRequestCountAsync(int expected)
        {
            for (var attempt = 0; attempt < 100 && Requests.Count < expected; attempt++)
            {
                await Task.Yield();
            }

            Assert.True(Requests.Count >= expected, $"Expected {expected} requests, got {Requests.Count}.");
        }
    }
}
