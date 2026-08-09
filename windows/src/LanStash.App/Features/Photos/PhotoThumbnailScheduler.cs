using LanStash.Domain;
using LanStash.App.Features.Settings;

namespace LanStash.App.Features.Photos;

public enum PhotoThumbnailPriority
{
    Visible,
    Prefetch,
}

public readonly record struct PhotoThumbnailCacheKey(
    Guid ProfileId,
    string Path,
    DateTimeOffset? ModifiedAt,
    long? SizeBytes,
    PhotoThumbnailSize Size)
{
    public static PhotoThumbnailCacheKey From(PhotoItem item, PhotoThumbnailSize size) =>
        new(item.ProfileId, item.Path, item.ModifiedAt, item.SizeBytes, size);
}

public sealed class PhotoThumbnailScheduler : IRegenerableCacheParticipant, IDisposable
{
    public const int DefaultConcurrencyLimit = 4;
    public const int DefaultPrefetchLimit = 12;
    public const long DefaultCacheCostLimit = 32L * 1024 * 1024;

    private readonly object _gate = new();
    private readonly int _concurrencyLimit;
    private readonly int _prefetchLimit;
    private readonly long _cacheCostLimit;
    private readonly CancellationTokenSource _disposeCancellation = new();
    private CancellationTokenSource _cacheCancellation = new();
    private readonly LinkedList<Waiter> _visibleWaiters = [];
    private readonly LinkedList<Waiter> _prefetchWaiters = [];
    private readonly Dictionary<PhotoThumbnailCacheKey, CacheEntry> _cache = [];
    private readonly LinkedList<PhotoThumbnailCacheKey> _lru = [];
    private int _activeCount;
    private long _cacheCost;
    private long _cacheGeneration;
    private bool _disposed;

    public PhotoThumbnailScheduler(
        int concurrencyLimit = DefaultConcurrencyLimit,
        int prefetchLimit = DefaultPrefetchLimit,
        long cacheCostLimit = DefaultCacheCostLimit)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(concurrencyLimit, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(prefetchLimit, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(cacheCostLimit, 1);
        _concurrencyLimit = Math.Min(concurrencyLimit, DefaultConcurrencyLimit);
        _prefetchLimit = Math.Min(prefetchLimit, DefaultPrefetchLimit);
        _cacheCostLimit = cacheCostLimit;
    }

    public int CachedItemCount
    {
        get
        {
            lock (_gate)
            {
                return _cache.Count;
            }
        }
    }

    public long CachedCost
    {
        get
        {
            lock (_gate)
            {
                return _cacheCost;
            }
        }
    }

    public string CacheId => "photos-memory-thumbnails";

    public RegenerableCacheSummary Snapshot() => new(CachedItemCount, CachedCost);

    public Task ClearAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ClearCache();
        return Task.CompletedTask;
    }

    public void ClearCache()
    {
        CancellationTokenSource previous;
        lock (_gate)
        {
            ThrowIfDisposed();
            previous = _cacheCancellation;
            _cacheCancellation = new CancellationTokenSource();
            _cacheGeneration++;
            _cache.Clear();
            _lru.Clear();
            _cacheCost = 0;
        }
        previous.Cancel();
        previous.Dispose();
    }

    public async Task<PhotoThumbnail?> GetAsync(
        IPhotoBrowserDataSource source,
        PhotoItem item,
        PhotoThumbnailSize size,
        PhotoThumbnailPriority priority,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(item);
        if (item.ProfileId != source.ProfileId || item.Kind != PhotoItemKind.Image)
        {
            return null;
        }

        var key = PhotoThumbnailCacheKey.From(item, size);
        if (TryGetCached(key, out var cached))
        {
            return cached;
        }

        long cacheGeneration;
        CancellationTokenSource linkedCancellation;
        lock (_gate)
        {
            ThrowIfDisposed();
            cacheGeneration = _cacheGeneration;
            linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                _disposeCancellation.Token,
                _cacheCancellation.Token);
        }
        using var linkedLifetime = linkedCancellation;
        using var lease = await AcquireAsync(priority, linkedCancellation.Token);
        linkedCancellation.Token.ThrowIfCancellationRequested();
        if (TryGetCached(key, out cached))
        {
            return cached;
        }

        var thumbnail = await source.LoadThumbnailAsync(item, size, linkedCancellation.Token);
        linkedCancellation.Token.ThrowIfCancellationRequested();
        if (thumbnail.Bytes.Length == 0)
        {
            return null;
        }
        Insert(key, thumbnail, cacheGeneration);
        return thumbnail;
    }

    public async Task PrefetchAsync(
        IPhotoBrowserDataSource source,
        IEnumerable<PhotoItem> items,
        PhotoThumbnailSize size = PhotoThumbnailSize.Small,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(source);
        ArgumentNullException.ThrowIfNull(items);
        var candidates = items
            .Where(item => item.ProfileId == source.ProfileId && item.Kind == PhotoItemKind.Image)
            .Take(_prefetchLimit)
            .ToArray();
        await Task.WhenAll(candidates.Select(async item =>
        {
            try
            {
                _ = await GetAsync(source, item, size, PhotoThumbnailPriority.Prefetch, cancellationToken);
            }
            catch (OperationCanceledException)
            {
            }
        }));
    }

    public bool TryGetCached(PhotoThumbnailCacheKey key, out PhotoThumbnail thumbnail)
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            if (!_cache.TryGetValue(key, out var entry))
            {
                thumbnail = default!;
                return false;
            }
            _lru.Remove(entry.Node);
            _lru.AddFirst(entry.Node);
            thumbnail = entry.Thumbnail;
            return true;
        }
    }

    private Task<Lease> AcquireAsync(
        PhotoThumbnailPriority priority,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        Waiter waiter;
        lock (_gate)
        {
            ThrowIfDisposed();
            if (_activeCount < _concurrencyLimit)
            {
                _activeCount += 1;
                return Task.FromResult(new Lease(this));
            }

            waiter = new Waiter(cancellationToken);
            waiter.Node = priority == PhotoThumbnailPriority.Visible
                ? _visibleWaiters.AddLast(waiter)
                : _prefetchWaiters.AddLast(waiter);
        }

        var registration = cancellationToken.Register(
            static state =>
            {
                var pair = ((PhotoThumbnailScheduler Scheduler, Waiter Waiter))state!;
                pair.Scheduler.CancelWaiter(pair.Waiter);
            },
            (this, waiter));
        lock (_gate)
        {
            waiter.Registration = registration;
            if (waiter.Node is null)
            {
                registration.Dispose();
            }
        }
        return waiter.Completion.Task;
    }

    private void CancelWaiter(Waiter waiter)
    {
        lock (_gate)
        {
            if (waiter.Node is null)
            {
                return;
            }
            waiter.Node.List!.Remove(waiter.Node);
            waiter.Node = null;
            waiter.Completion.TrySetCanceled(waiter.CancellationToken);
        }
    }

    private void Release()
    {
        Waiter? next = null;
        lock (_gate)
        {
            if (!_disposed)
            {
                var node = _visibleWaiters.First ?? _prefetchWaiters.First;
                if (node is not null)
                {
                    next = node.Value;
                    node.List!.Remove(node);
                    next.Node = null;
                }
            }
            if (next is null)
            {
                _activeCount = Math.Max(0, _activeCount - 1);
            }
        }
        if (next is not null)
        {
            next.Registration.Dispose();
            next.Completion.TrySetResult(new Lease(this));
        }
    }

    private void Insert(
        PhotoThumbnailCacheKey key,
        PhotoThumbnail thumbnail,
        long cacheGeneration)
    {
        var cost = thumbnail.Bytes.LongLength;
        if (cost > _cacheCostLimit)
        {
            return;
        }
        lock (_gate)
        {
            ThrowIfDisposed();
            if (cacheGeneration != _cacheGeneration)
            {
                return;
            }
            if (_cache.Remove(key, out var existing))
            {
                _lru.Remove(existing.Node);
                _cacheCost -= existing.Cost;
            }
            var node = _lru.AddFirst(key);
            _cache[key] = new CacheEntry(thumbnail, cost, node);
            _cacheCost += cost;
            while (_cacheCost > _cacheCostLimit)
            {
                var oldest = _lru.Last!;
                _lru.RemoveLast();
                var removed = _cache[oldest.Value];
                _cache.Remove(oldest.Value);
                _cacheCost -= removed.Cost;
            }
        }
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        List<Waiter> waiters;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            waiters = _visibleWaiters.Concat(_prefetchWaiters).ToList();
            _visibleWaiters.Clear();
            _prefetchWaiters.Clear();
            foreach (var waiter in waiters)
            {
                waiter.Node = null;
            }
            _cache.Clear();
            _lru.Clear();
            _cacheCost = 0;
        }
        _disposeCancellation.Cancel();
        _cacheCancellation.Cancel();
        foreach (var waiter in waiters)
        {
            waiter.Registration.Dispose();
            waiter.Completion.TrySetException(new ObjectDisposedException(nameof(PhotoThumbnailScheduler)));
        }
        _disposeCancellation.Dispose();
        _cacheCancellation.Dispose();
    }

    private sealed class Lease(PhotoThumbnailScheduler owner) : IDisposable
    {
        private PhotoThumbnailScheduler? _owner = owner;

        public void Dispose() => Interlocked.Exchange(ref _owner, null)?.Release();
    }

    private sealed class Waiter(CancellationToken cancellationToken)
    {
        public CancellationToken CancellationToken { get; } = cancellationToken;
        public TaskCompletionSource<Lease> Completion { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public LinkedListNode<Waiter>? Node { get; set; }
        public CancellationTokenRegistration Registration { get; set; }
    }

    private sealed record CacheEntry(
        PhotoThumbnail Thumbnail,
        long Cost,
        LinkedListNode<PhotoThumbnailCacheKey> Node);
}
