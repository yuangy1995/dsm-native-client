using LanStash.App.Features.Files;
using LanStash.App.Features.Settings;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class WorkspacePerformanceTests
{
    [Fact]
    public void CacheEvictsLeastRecentlyUsedAndHonorsWeight()
    {
        var cache = new BoundedLruCache<string, int>(3, 6, value => value);
        cache["a"] = 2; cache["b"] = 2; cache["c"] = 2;
        Assert.True(cache.TryGetValue("a", out _));
        cache["d"] = 2;
        Assert.False(cache.TryGetValue("b", out _));
        Assert.True(cache.TryGetValue("a", out _));
        Assert.Equal(3, cache.Count);
        Assert.Equal(6, cache.Weight);
        cache["large"] = 5;
        Assert.Equal(1, cache.Count);
        Assert.Equal(5, cache.Weight);
    }

    [Fact]
    public void OversizedReplacementCannotLeaveAnOldCachedPage()
    {
        var cache = new BoundedLruCache<string, int>(2, 10, value => value, StringComparer.OrdinalIgnoreCase);
        cache["folder"] = 3;
        cache["FOLDER"] = 20;
        Assert.Equal(0, cache.Count);
        Assert.Equal(0, cache.Weight);
        Assert.False(cache.TryGetValue("folder", out _));
        cache["a"] = 1;
        cache.Clear();
        Assert.Equal(0, cache.Weight);
        Assert.False(cache.Remove("missing"));
    }

    [Fact]
    public void WeightArithmeticCannotOverflowAtLongMaxValue()
    {
        var cache = new BoundedLruCache<string, long>(2, long.MaxValue, value => value);
        cache["first"] = long.MaxValue;
        cache["second"] = 1;
        Assert.False(cache.TryGetValue("first", out _));
        Assert.Equal(1, cache.Weight);
        Assert.Throws<ArgumentOutOfRangeException>(() => cache["invalid"] = -1);
    }

    [Fact]
    public void EmptyPagesStillHaveACountLimit()
    {
        var cache = new BoundedLruCache<int, int>(2, 10, _ => 0);
        for (var i = 0; i < 1000; i++) cache[i] = i;
        Assert.Equal(2, cache.Count);
        Assert.Equal(0, cache.Weight);
    }

    [Fact]
    public void CacheRejectsInvalidConfiguration()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new BoundedLruCache<int, int>(0, 1, x => x));
        Assert.Throws<ArgumentOutOfRangeException>(() => new BoundedLruCache<int, int>(1, 0, x => x));
        Assert.Throws<ArgumentNullException>(() => new BoundedLruCache<int, int>(1, 1, null!));
    }

    [Fact]
    public async Task ManyDirectoriesStayInsideTheCombinedSnapshotBudget()
    {
        using var model = new FileBrowserViewModel(new SyntheticDirectories(250), pageSize: 250);
        for (var i = 0; i < 80; i++)
        {
            Assert.True(await model.OpenLocationAsync($"/synthetic/{i}"));
            Assert.InRange(model.CachedLocationCount, 0, FileBrowserViewModel.MaximumCachedLocations);
            Assert.InRange(model.CachedEntryCount, 0, FileBrowserViewModel.MaximumCachedEntries);
        }
        Assert.Equal(250, model.Items.Count);
        model.Dispose();
        Assert.Equal(0, model.CachedEntryCount);
        Assert.Equal(0, model.CachedLocationCount);
    }

    [Fact]
    public async Task LargeActiveDirectoryIsNotDuplicatedOrTruncatedByCacheBudget()
    {
        var count = FileBrowserViewModel.MaximumCachedEntries + 1;
        using var model = new FileBrowserViewModel(new SyntheticDirectories(count), pageSize: count);
        Assert.True(await model.OpenLocationAsync("/synthetic/large"));
        Assert.Equal(count, model.Items.Count);
        Assert.Equal(0, model.CachedEntryCount);
        Assert.True(model.IsGridLayout);
        Assert.False(model.IsListLayout);
    }

    [Fact]
    public async Task ConcurrentNotificationsCoalesceAndStopRejectsLateRendering()
    {
        var invalidation = new PresentationInvalidation();
        var accepted = await Task.WhenAll(Enumerable.Range(0, 64)
            .Select(_ => Task.Run(invalidation.TryRequest)));
        Assert.Single(accepted.Where(value => value));
        Assert.True(invalidation.Consume());
        Assert.True(invalidation.TryRequest());
        invalidation.Stop();
        Assert.False(invalidation.Consume());
        Assert.False(invalidation.TryRequest());
    }

    private sealed class SyntheticDirectories(int count) : IFileBrowserDataSource
    {
        public Task<FilePage> LoadPageAsync(string path, int offset, int limit, FileListOptions options,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var items = Enumerable.Range(offset, Math.Min(limit, count - offset))
                .Select(i => new FileItem($"{path}/item-{i}.txt", $"item-{i}.txt", false, i, null, null, true, true))
                .ToArray();
            return Task.FromResult(new FilePage(items, count, offset));
        }
    }
}
