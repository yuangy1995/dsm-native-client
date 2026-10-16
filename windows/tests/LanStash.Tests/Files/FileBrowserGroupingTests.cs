using System.Globalization;
using LanStash.App.Features.Files;
using LanStash.Domain;

namespace LanStash.Tests.Files;

public sealed class FileBrowserGroupingTests
{
    [Fact]
    public void TypeGroupingIncludesOfficeAndPreservesWithinGroupOrder()
    {
        var entries = new[] { Entry("b.txt"), Entry("a.docx"), Entry("image.png"), Entry("song.mp3"), Entry("movie.mp4"), Entry("unknown.bin"), Entry("folder", directory: true) };
        var groups = Groups(entries, FileBrowserGrouping.Type);
        Assert.Equal(["Folder", "Image", "Video", "Audio", "Document", "Other"], groups.Select(group => group.Key));
        Assert.Equal(["b.txt", "a.docx"], groups.Single(group => group.Key == "Document").Select(item => item.Name));
        Assert.Same(entries[0], groups.Single(group => group.Key == "Document")[0]);
    }

    [Theory]
    [InlineData(-1, "UnknownSize")] [InlineData(0, "Tiny")] [InlineData(10485759, "Tiny")]
    [InlineData(10485760, "Small")] [InlineData(104857600, "Medium")] [InlineData(1073741824, "Large")]
    public void SizeThresholdsAndUnknownRemainDistinct(long size, string key) =>
        Assert.Equal(key, Assert.Single(Groups([Entry("item.bin", size)], FileBrowserGrouping.Size)).Key);

    [Fact]
    public void DatesUseLocalDayAndCultureWeekWithUnknownLast()
    {
        var zone = TimeZoneInfo.CreateCustomTimeZone("Synthetic", TimeSpan.FromHours(8), "Synthetic", "Synthetic");
        var now = new DateTimeOffset(2026, 10, 15, 12, 0, 0, TimeSpan.Zero);
        var dates = new[] { now, now.AddDays(-1), now.AddDays(-2), now.AddDays(-10), now.AddMonths(-1), (DateTimeOffset?)null };
        var entries = dates.Select((date, i) => Entry("file-" + i) with { Item = Entry("file-" + i).Item with { ModifiedAt = date } });
        Assert.Equal(["Today", "Yesterday", "Week", "Month", "Earlier", "UnknownDate"],
            FileBrowserViewModel.BuildGroups(entries, FileBrowserGrouping.Date, now, zone, CultureInfo.GetCultureInfo("zh-CN")).Select(group => group.Key));
        var boundary = Entry("boundary") with { Item = Entry("boundary").Item with { ModifiedAt = new DateTimeOffset(2026, 10, 14, 18, 0, 0, TimeSpan.Zero) } };
        Assert.Equal("Today", Assert.Single(FileBrowserViewModel.BuildGroups([boundary], FileBrowserGrouping.Date, now, zone, CultureInfo.InvariantCulture)).Key);
    }

    [Fact]
    public void SearchFilteringAndGroupingShareOriginalEntriesAndSelection()
    {
        using var model = new FileBrowserViewModel(new EmptySource());
        model.SetAsyncSearchResults([Entry("z.txt").Item, Entry("a.docx").Item, Entry("photo.png").Item], 3, false);
        model.SelectedItem = model.Items.First(item => item.Name == "z.txt"); var selected = model.SelectedItem;
        model.Grouping = FileBrowserGrouping.Type;
        Assert.Same(selected, model.SelectedItem); Assert.Equal(3, model.Groups.Sum(group => group.Count));
        model.Grouping = FileBrowserGrouping.None; Assert.Empty(model.Groups); Assert.Equal(3, model.Items.Count);
    }

    private static FileBrowserEntry Entry(string name, long size = 1, bool directory = false) => new(new("/synthetic/" + name, name, directory, size, null, null, false, false));
    private static IReadOnlyList<FileBrowserGroup> Groups(IEnumerable<FileBrowserEntry> items, FileBrowserGrouping grouping) =>
        FileBrowserViewModel.BuildGroups(items, grouping, DateTimeOffset.UtcNow, TimeZoneInfo.Utc, CultureInfo.InvariantCulture);
    private sealed class EmptySource : IFileBrowserDataSource
    {
        public Task<FilePage> LoadPageAsync(string path, int offset, int limit, FileListOptions options, CancellationToken token) => Task.FromResult(new FilePage([], 0, 0));
    }
}
