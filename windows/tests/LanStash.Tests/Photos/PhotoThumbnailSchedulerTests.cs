using LanStash.App.Features.Photos;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class PhotoThumbnailSchedulerTests
{
    [Fact]
    public async Task ActiveThumbnailLoadsNeverExceedFour()
    {
        var profile = Guid.NewGuid();
        var probe = new ThumbnailProbe(delay: TimeSpan.FromMilliseconds(20));
        var source = new ThumbnailSource(profile, probe.LoadAsync);
        using var scheduler = new PhotoThumbnailScheduler(concurrencyLimit: 4);

        await Task.WhenAll(Enumerable.Range(0, 16).Select(index => scheduler.GetAsync(
            source,
            Image(profile, $"/photo/{index}.jpg"),
            PhotoThumbnailSize.Small,
            PhotoThumbnailPriority.Visible)));

        Assert.Equal(4, probe.PeakActive);
    }

    [Fact]
    public async Task VisibleRequestRunsBeforeQueuedPrefetch()
    {
        var profile = Guid.NewGuid();
        var probe = new ThumbnailProbe(blockFirst: true);
        var source = new ThumbnailSource(profile, probe.LoadAsync);
        using var scheduler = new PhotoThumbnailScheduler(concurrencyLimit: 1);
        var first = scheduler.GetAsync(
            source, Image(profile, "/photo/first.jpg"), PhotoThumbnailSize.Small,
            PhotoThumbnailPriority.Prefetch);
        await probe.FirstStarted.Task;
        var prefetch = scheduler.GetAsync(
            source, Image(profile, "/photo/prefetch.jpg"), PhotoThumbnailSize.Small,
            PhotoThumbnailPriority.Prefetch);
        await YieldSeveralTimesAsync();
        var visible = scheduler.GetAsync(
            source, Image(profile, "/photo/visible.jpg"), PhotoThumbnailSize.Small,
            PhotoThumbnailPriority.Visible);
        await YieldSeveralTimesAsync();

        probe.ReleaseFirst();
        await Task.WhenAll(first, prefetch, visible);

        Assert.Equal(
            ["first.jpg", "visible.jpg", "prefetch.jpg"],
            probe.StartedNames);
    }

    [Fact]
    public async Task QueuedAndActiveRequestsObserveCallerCancellation()
    {
        var profile = Guid.NewGuid();
        var probe = new ThumbnailProbe(blockFirst: true);
        var source = new ThumbnailSource(profile, probe.LoadAsync);
        using var scheduler = new PhotoThumbnailScheduler(concurrencyLimit: 1);
        var firstCancellation = new CancellationTokenSource();
        var first = scheduler.GetAsync(
            source, Image(profile, "/photo/first.jpg"), PhotoThumbnailSize.Small,
            PhotoThumbnailPriority.Visible, firstCancellation.Token);
        await probe.FirstStarted.Task;
        var queuedCancellation = new CancellationTokenSource();
        var queued = scheduler.GetAsync(
            source, Image(profile, "/photo/queued.jpg"), PhotoThumbnailSize.Small,
            PhotoThumbnailPriority.Visible, queuedCancellation.Token);

        queuedCancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => queued);
        firstCancellation.Cancel();
        probe.ReleaseFirst();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);

        Assert.DoesNotContain("queued.jpg", probe.StartedNames);
    }

    [Fact]
    public async Task PrefetchStartsAtMostTwelveEligibleItems()
    {
        var profile = Guid.NewGuid();
        var probe = new ThumbnailProbe();
        var source = new ThumbnailSource(profile, probe.LoadAsync);
        using var scheduler = new PhotoThumbnailScheduler();
        var items = Enumerable.Range(0, 20)
            .Select(index => Image(profile, $"/photo/{index}.jpg"))
            .Prepend(Video(profile, "/photo/video.mov"))
            .ToArray();

        await scheduler.PrefetchAsync(source, items);

        Assert.Equal(12, probe.StartedNames.Count);
        Assert.DoesNotContain("video.mov", probe.StartedNames);
    }

    [Fact]
    public async Task CostLruKeepsRecentlyReadEntryAndSeparatesProfiles()
    {
        var profileA = Guid.NewGuid();
        var profileB = Guid.NewGuid();
        var sourceA = new ThumbnailSource(profileA, (item, _) =>
            Task.FromResult(new PhotoThumbnail([1, 1], "image/jpeg")));
        var sourceB = new ThumbnailSource(profileB, (item, _) =>
            Task.FromResult(new PhotoThumbnail([2, 2], "image/jpeg")));
        using var scheduler = new PhotoThumbnailScheduler(cacheCostLimit: 4);
        var a = Image(profileA, "/photo/a.jpg");
        var b = Image(profileA, "/photo/b.jpg");
        var c = Image(profileA, "/photo/c.jpg");

        _ = await scheduler.GetAsync(sourceA, a, PhotoThumbnailSize.Small, PhotoThumbnailPriority.Visible);
        _ = await scheduler.GetAsync(sourceA, b, PhotoThumbnailSize.Small, PhotoThumbnailPriority.Visible);
        Assert.True(scheduler.TryGetCached(PhotoThumbnailCacheKey.From(a, PhotoThumbnailSize.Small), out _));
        _ = await scheduler.GetAsync(sourceA, c, PhotoThumbnailSize.Small, PhotoThumbnailPriority.Visible);

        Assert.True(scheduler.TryGetCached(PhotoThumbnailCacheKey.From(a, PhotoThumbnailSize.Small), out _));
        Assert.False(scheduler.TryGetCached(PhotoThumbnailCacheKey.From(b, PhotoThumbnailSize.Small), out _));
        Assert.True(scheduler.TryGetCached(PhotoThumbnailCacheKey.From(c, PhotoThumbnailSize.Small), out _));
        var foreign = Image(profileB, "/photo/a.jpg");
        var foreignThumbnail = await scheduler.GetAsync(
            sourceB, foreign, PhotoThumbnailSize.Small, PhotoThumbnailPriority.Visible);
        Assert.Equal([2, 2], foreignThumbnail!.Bytes);
        Assert.Equal(2, scheduler.CachedItemCount);
        Assert.True(scheduler.TryGetCached(
            PhotoThumbnailCacheKey.From(foreign, PhotoThumbnailSize.Small), out _));
    }

    [Fact]
    public async Task ModifiedVersionInvalidatesSamePathCache()
    {
        var profile = Guid.NewGuid();
        var calls = 0;
        var source = new ThumbnailSource(profile, (item, _) => Task.FromResult(
            new PhotoThumbnail([(byte)Interlocked.Increment(ref calls)], "image/jpeg")));
        using var scheduler = new PhotoThumbnailScheduler();
        var original = Image(profile, "/photo/a.jpg");
        var changed = original with { ModifiedAt = original.ModifiedAt!.Value.AddMinutes(1) };

        var first = await scheduler.GetAsync(
            source, original, PhotoThumbnailSize.Small, PhotoThumbnailPriority.Visible);
        var second = await scheduler.GetAsync(
            source, changed, PhotoThumbnailSize.Small, PhotoThumbnailPriority.Visible);

        Assert.Equal([1], first!.Bytes);
        Assert.Equal([2], second!.Bytes);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task DisposeCancelsActiveLoaderAndClearsCache()
    {
        var profile = Guid.NewGuid();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var source = new ThumbnailSource(profile, async (_, cancellationToken) =>
        {
            started.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            return new PhotoThumbnail([1], "image/jpeg");
        });
        var scheduler = new PhotoThumbnailScheduler();
        var load = scheduler.GetAsync(
            source, Image(profile, "/photo/a.jpg"), PhotoThumbnailSize.Small,
            PhotoThumbnailPriority.Visible);
        await started.Task;

        scheduler.Dispose();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => load);
        Assert.Equal(0, scheduler.CachedItemCount);
        Assert.Equal(0, scheduler.CachedCost);
    }

    [Fact]
    public async Task ClearCancelsGenerationAndLateLoaderCannotRefillCache()
    {
        var profile = Guid.NewGuid();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var delayed = new TaskCompletionSource<PhotoThumbnail>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var source = new ThumbnailSource(profile, (_, _) =>
        {
            if (Interlocked.Increment(ref calls) == 1)
            {
                started.TrySetResult();
                return delayed.Task;
            }
            return Task.FromResult(new PhotoThumbnail([2], "image/jpeg"));
        });
        using var scheduler = new PhotoThumbnailScheduler();
        var item = Image(profile, "/photo/a.jpg");
        var stale = scheduler.GetAsync(
            source,
            item,
            PhotoThumbnailSize.Small,
            PhotoThumbnailPriority.Visible);
        await started.Task;

        scheduler.ClearCache();
        delayed.SetResult(new PhotoThumbnail([1], "image/jpeg"));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => stale);
        Assert.Equal(0, scheduler.CachedItemCount);
        Assert.Equal(0, scheduler.CachedCost);
        var current = await scheduler.GetAsync(
            source,
            item,
            PhotoThumbnailSize.Small,
            PhotoThumbnailPriority.Visible);
        Assert.Equal([2], current!.Bytes);
        Assert.Equal(1, scheduler.CachedItemCount);
    }

    private static async Task YieldSeveralTimesAsync()
    {
        for (var index = 0; index < 10; index++)
        {
            await Task.Yield();
        }
    }

    private static PhotoItem Image(Guid profile, string path) => Item(profile, path, PhotoItemKind.Image);
    private static PhotoItem Video(Guid profile, string path) => Item(profile, path, PhotoItemKind.Video);
    private static PhotoItem Item(Guid profile, string path, PhotoItemKind kind) => new(
        profile,
        $"{profile:N}:{path}",
        Path.GetFileName(path),
        path,
        kind,
        2,
        null,
        DateTimeOffset.Parse("2026-01-01T00:00:00Z"),
        Path.GetExtension(path).TrimStart('.'),
        true);

    private sealed class ThumbnailSource(
        Guid profileId,
        Func<PhotoItem, CancellationToken, Task<PhotoThumbnail>> loader)
        : IPhotoBrowserDataSource
    {
        public Guid ProfileId { get; } = profileId;
        public Task<IReadOnlyList<PhotoSpace>> DiscoverSpacesAsync(CancellationToken cancellationToken) =>
            throw new NotSupportedException();
        public Task<PhotoPage> LoadPageAsync(
            PhotoSpace space, string path, int offset, int limit, CancellationToken cancellationToken) =>
            throw new NotSupportedException();
        public Task<PhotoThumbnail> LoadThumbnailAsync(
            PhotoItem item, PhotoThumbnailSize size, CancellationToken cancellationToken) =>
            loader(item, cancellationToken);
    }

    private sealed class ThumbnailProbe(TimeSpan? delay = null, bool blockFirst = false)
    {
        private readonly object _gate = new();
        private readonly TaskCompletionSource _release =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int _active;
        public TaskCompletionSource FirstStarted { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int PeakActive { get; private set; }
        public List<string> StartedNames { get; } = [];

        public async Task<PhotoThumbnail> LoadAsync(PhotoItem item, CancellationToken cancellationToken)
        {
            bool isFirst;
            lock (_gate)
            {
                _active += 1;
                PeakActive = Math.Max(PeakActive, _active);
                StartedNames.Add(item.Name);
                isFirst = StartedNames.Count == 1;
            }
            if (isFirst)
            {
                FirstStarted.TrySetResult();
            }
            try
            {
                if (blockFirst && isFirst)
                {
                    await _release.Task.WaitAsync(cancellationToken);
                }
                if (delay is TimeSpan value)
                {
                    await Task.Delay(value, cancellationToken);
                }
                return new PhotoThumbnail([1], "image/jpeg");
            }
            finally
            {
                lock (_gate)
                {
                    _active -= 1;
                }
            }
        }

        public void ReleaseFirst() => _release.TrySetResult();
    }
}
