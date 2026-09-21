using LanStash.App.Features.Files.Downloads;
using LanStash.Domain;

namespace LanStash.Tests.Files.Downloads;

public sealed class FileDownloadSelectionTests
{
    [Theory]
    [InlineData(21)]
    [InlineData(205)]
    [InlineData(1001)]
    public void MixedSelectionHasNoArbitraryCountLimit(int count)
    {
        var items = Items(count); Assert.True(FileDownloadSelection.IsValid(items)); Assert.True(FileDownloadSelection.UsesArchive(items));
        Assert.Equal("/share", FileDownloadSelection.SourceLocation(items));
    }

    [Fact]
    public void SingleFileStaysOriginalAndSingleFolderUsesArchive()
    {
        Assert.False(FileDownloadSelection.UsesArchive([Item("/share/one.txt")]));
        Assert.True(FileDownloadSelection.UsesArchive([Item("/share/folder", true)]));
        Assert.Equal("/share/folder", FileDownloadSelection.SourceLocation([Item("/share/folder", true)]));
        Assert.True(FileDownloadSelection.IsValid([Item("/a/same.txt"), Item("/b/same.txt")]));
        Assert.Equal("/", FileDownloadSelection.SourceLocation([Item("/a/same.txt"), Item("/b/same.txt")]));
    }

    [Fact]
    public void CompleteSnapshotMustStillBeSelectedIncludingLastItem()
    {
        var items = Items(1001); var selected = items.Select(item => item.Path).ToHashSet(StringComparer.Ordinal);
        Assert.True(FileDownloadSelection.MatchesSnapshot(items, items, selected));
        Assert.False(FileDownloadSelection.MatchesSnapshot(items, items[..^1], selected));
        var changed = items.ToArray(); changed[^1] = changed[^1] with { Size = 999 };
        Assert.False(FileDownloadSelection.MatchesSnapshot(items, changed, selected));
        selected.Remove(items[^1].Path); Assert.False(FileDownloadSelection.MatchesSnapshot(items, items, selected));
        Assert.False(FileDownloadSelection.MatchesSnapshot(items, items.Append(items[^1]).ToArray(), items.Select(item => item.Path).ToHashSet()));
    }

    [Theory]
    [InlineData("")]
    [InlineData("/")]
    [InlineData("relative/file")]
    [InlineData("/share/../file")]
    [InlineData("/share//file")]
    [InlineData("/share/folder/")]
    [InlineData("/share/file\n")]
    public void InvalidRemoteTargetsAreRejected(string path) => Assert.False(FileArchivePaths.IsValid(path));

    [Fact]
    public void InvalidOrDuplicateSelectionCannotSilentlyDropItems()
    {
        Assert.False(FileDownloadSelection.IsValid([]));
        Assert.False(FileDownloadSelection.IsValid([Item("/share/a"), Item("/share/a")]));
        Assert.False(FileDownloadSelection.IsValid([Item("/share/a") with { Name = "different" }]));
        Assert.False(FileDownloadSelection.IsValid([Item("/share/a") with { Size = -1 }]));
        Assert.True(FileDownloadSelection.IsValid([Item("/share/CON.txt"), Item("/share/name:part")]));
    }

    private static FileItem[] Items(int count) => Enumerable.Range(0, count).Select(index => Item($"/share/item-{index:D4}", index % 7 == 0)).ToArray();
    private static FileItem Item(string path, bool folder = false) => new(path, path[(path.LastIndexOf('/') + 1)..], folder, 1, DateTimeOffset.UnixEpoch, null, false, false);
}
