using LanStash.App.Features.Downloads;
using LanStash.App.Features.Files.CopyMove;

namespace LanStash.Tests.Downloads;

public sealed class DownloadCreateOptionsTests
{
    [Fact]
    public async Task SelectionRequiresCurrentWritableFolderAndDefaultClearsOverride()
    {
        using var model = new DownloadCreateOptionsViewModel(new Folders());
        await model.BrowseAsync("");
        model.Choose(model.Folders[0]); Assert.Null(model.Destination);
        model.Choose(new("/foreign", "Foreign", true)); Assert.Null(model.Destination);
        model.Choose(model.Folders[1]); Assert.Equal("downloads", model.Destination); Assert.False(model.IsBrowsing);
        model.UseDefault(); Assert.Null(model.Destination);
    }

    [Fact]
    public async Task ClosingBrowserRejectsLateFolderResults()
    {
        var delayed = new TaskCompletionSource<IReadOnlyList<FileCopyMoveFolder>>(TaskCreationOptions.RunContinuationsAsynchronously);
        var folders = new Folders { Loader = () => delayed.Task };
        using var model = new DownloadCreateOptionsViewModel(folders);
        var load = model.BrowseAsync(""); model.CloseBrowser();
        delayed.SetResult([new("/late", "Late", true)]); await load;
        Assert.Empty(model.Folders); Assert.False(model.IsBrowsing); Assert.Null(model.Destination);
    }
    private sealed class Folders : IFileCopyMoveFolderSource
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public Func<Task<IReadOnlyList<FileCopyMoveFolder>>>? Loader { get; init; }
        public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path, CancellationToken cancellationToken) =>
            Loader?.Invoke() ?? Task.FromResult<IReadOnlyList<FileCopyMoveFolder>>([new("/readonly", "Read only", false), new("/downloads", "Downloads", true)]);
        public bool IsReadOnlyPath(string path) => false;
    }
}
