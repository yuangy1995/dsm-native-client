using LanStash.App.Features.Files;
using LanStash.Domain;

namespace LanStash.Tests.Files;

public sealed class FileSearchPresentationTests
{
    [Fact]
    public async Task SortingSearchResultsDoesNotReloadTheDirectoryOrEnableItsNextPage()
    {
        var source = new Source();
        using var model = new FileBrowserViewModel(source);
        await model.InitializeAsync();
        Assert.True(model.CanLoadMore);
        model.BeginAsyncSearch(FileListTypeFilter.All);
        model.SetAsyncSearchResults([
            Item("/share/a.txt", 20), Item("/other/b.txt", 10),
        ], 2, false, FileSearchIndexCoverage.Incomplete);
        var reads = source.Reads;
        await model.SetSortFieldAsync(FileListSortField.Size);
        Assert.Equal(new[] { "/other/b.txt", "/share/a.txt" }, model.Items.Select(item => item.Path));
        Assert.Equal("/other/b.txt", model.Items[0].Detail);
        await model.SetSortDirectionAsync(FileListSortDirection.Descending);
        Assert.Equal("/share/a.txt", model.Items[0].Path);
        await model.LoadMoreAsync();
        Assert.Equal(reads, source.Reads);
        Assert.False(model.CanLoadMore);
        Assert.True(model.HasIncompleteSearchIndex);
        model.SetFilter(string.Empty);
        Assert.Equal(FileListSortField.Name, model.SortField);
        Assert.Equal(FileListSortDirection.Ascending, model.SortDirection);
        Assert.Equal("/directory/original.txt", Assert.Single(model.Items).Path);
    }

    [Fact]
    public async Task ClearingSearchRestoresDirectoryAndRemovesCoverageAndErrorStates()
    {
        using var model = new FileBrowserViewModel(new Source());
        await model.InitializeAsync();
        model.SetAsyncSearchResults([], 0, false, FileSearchIndexCoverage.Incomplete);
        Assert.True(model.IsFilteredEmpty);
        Assert.True(model.HasIncompleteSearchIndex);
        model.SetAsyncSearchError("FileSearchContentsUnavailable");
        Assert.True(model.HasError);
        Assert.False(model.HasIncompleteSearchIndex);
        Assert.Equal("FileSearchContentsUnavailable", model.SearchErrorMessageKey);
        model.SetFilter(string.Empty);
        Assert.False(model.HasSearchError);
        Assert.Equal("/directory/original.txt", Assert.Single(model.Items).Path);
        Assert.True(model.CanLoadMore);
    }

    [Fact]
    public async Task BeginningSearchCancelsDirectoryReadsAndIgnoresLatePages()
    {
        var source = new Source { Delay = true };
        using var model = new FileBrowserViewModel(source);
        var loading = model.InitializeAsync();
        model.BeginAsyncSearch();
        model.SetAsyncSearchResults([Item("/search/match.txt", 1)], 1, false);
        source.Completion.SetResult(new([Item("/directory/late.txt", 2)], 1, 0));
        await loading;
        Assert.True(source.Token.IsCancellationRequested);
        Assert.Equal("/search/match.txt", Assert.Single(model.Items).Path);
        Assert.False(model.CanLoadMore);
    }

    private static FileItem Item(string path, long size) => new(path, path.Split('/')[^1], false, size, null, null, false, false);

    private sealed class Source : IFileBrowserDataSource
    {
        public int Reads;
        public bool Delay;
        public CancellationToken Token;
        public TaskCompletionSource<FilePage> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<FilePage> LoadPageAsync(string path, int offset, int limit, FileListOptions options, CancellationToken token)
        {
            Reads++;
            Token = token;
            return Delay ? Completion.Task : Task.FromResult(new FilePage([Item("/directory/original.txt", 1)], 2, 0));
        }
    }
}
