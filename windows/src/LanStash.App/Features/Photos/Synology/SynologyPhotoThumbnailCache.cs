using LanStash.App.Features.Settings;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

public sealed record SynologyPhotoDecodedThumbnail<T>(T Value, long Cost);
public sealed record SynologyPhotoThumbnailKey(SynologyPhotoIdentity Photo, long UnitId, string Revision);

/// <summary>按账号、空间、项目、单元和修订号隔离；仅可见项取图，最后一个订阅者离开即取消。</summary>
public sealed class SynologyPhotoThumbnailCache<T> : IRegenerableCacheParticipant, IDisposable
{
    public const int MaximumConcurrency = 4;
    public const int MaximumEntries = 120;
    public const long MaximumCost = 32L * 1024 * 1024;
    private readonly ISynologyPhotosRepository _repository;
    private readonly Func<byte[], CancellationToken, Task<SynologyPhotoDecodedThumbnail<T>>> _decode;
    private readonly object _gate = new();
    private readonly SemaphoreSlim _slots = new(MaximumConcurrency, MaximumConcurrency);
    private CancellationTokenSource _lifetime = new();
    private readonly Dictionary<SynologyPhotoThumbnailKey, Entry> _requests = [];
    private readonly Dictionary<SynologyPhotoThumbnailKey, (SynologyPhotoDecodedThumbnail<T> Image, LinkedListNode<SynologyPhotoThumbnailKey> Node)> _cache = [];
    private readonly LinkedList<SynologyPhotoThumbnailKey> _lru = [];
    private long _generation;
    private long _cost;
    private bool _disposed;

    public SynologyPhotoThumbnailCache(ISynologyPhotosRepository repository,
        Func<byte[], CancellationToken, Task<SynologyPhotoDecodedThumbnail<T>>> decode)
    { _repository = repository; _decode = decode; }

    public string CacheId => "synology-photos-memory-thumbnails";
    public RegenerableCacheSummary Snapshot() { lock (_gate) return new(_cache.Count, _cost); }
    public Task ClearAsync(CancellationToken cancellationToken = default)
    { cancellationToken.ThrowIfCancellationRequested(); Clear(); return Task.CompletedTask; }

    public async Task<T> GetAsync(SynologyPhoto photo, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (photo.Id.ProfileId != _repository.ProfileId || photo.Id.Space != SynologyPhotoSpace.Personal || photo.Thumbnail is not { } thumbnail)
            throw new SynologyPhotoException(SynologyPhotoFailure.Permission);
        var key = new SynologyPhotoThumbnailKey(photo.Id, thumbnail.UnitId, thumbnail.Revision);
        Entry entry; var start = false;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_cache.TryGetValue(key, out var cached))
            {
                _lru.Remove(cached.Node); _lru.AddLast(cached.Node); return cached.Image.Value;
            }
            if (!_requests.TryGetValue(key, out entry!))
            {
                entry = new(_generation, CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token));
                _requests.Add(key, entry); start = true;
            }
            entry.Subscribers++;
        }
        if (start) _ = LoadAsync(key, photo, entry);
        try { return (await entry.Completion.Task.WaitAsync(cancellationToken)).Value; }
        finally
        {
            lock (_gate)
            {
                entry.Subscribers--;
                if (entry.Subscribers == 0 && _requests.TryGetValue(key, out var current) && ReferenceEquals(current, entry))
                { _requests.Remove(key); entry.Cancellation.Cancel(); }
            }
        }
    }

    private async Task LoadAsync(SynologyPhotoThumbnailKey key, SynologyPhoto photo, Entry entry)
    {
        var token = entry.Cancellation.Token; var acquired = false;
        try
        {
            await _slots.WaitAsync(token); acquired = true;
            var bytes = await _repository.ThumbnailAsync(photo, cancellationToken: token);
            token.ThrowIfCancellationRequested();
            // 解码由平台传入；Windows 使用有尺寸上限的 BitmapImage，不在列表中解码原图。
            var image = await _decode(bytes, token);
            token.ThrowIfCancellationRequested();
            if (image.Cost <= 0) throw new SynologyPhotoException(SynologyPhotoFailure.Media);
            lock (_gate)
            {
                if (_disposed || entry.Generation != _generation || token.IsCancellationRequested) throw new OperationCanceledException(token);
                if (image.Cost <= MaximumCost)
                {
                    while (_cache.Count >= MaximumEntries || _cost + image.Cost > MaximumCost)
                    {
                        var oldest = _lru.First!;
                        _cost -= _cache[oldest.Value].Image.Cost; _cache.Remove(oldest.Value); _lru.RemoveFirst();
                    }
                    _cache[key] = (image, _lru.AddLast(key)); _cost += image.Cost;
                }
                entry.Completion.TrySetResult(image);
            }
        }
        catch (OperationCanceledException) { entry.Completion.TrySetCanceled(); }
        catch (Exception error) { entry.Completion.TrySetException(error); }
        finally
        {
            if (acquired) _slots.Release();
            lock (_gate)
            { if (_requests.TryGetValue(key, out var current) && ReferenceEquals(current, entry)) _requests.Remove(key); }
            entry.Cancellation.Dispose();
        }
    }

    public void Clear()
    {
        CancellationTokenSource previous;
        lock (_gate)
        {
            if (_disposed) return;
            previous = _lifetime; _lifetime = new(); _generation++;
            _cache.Clear(); _lru.Clear(); _cost = 0; _requests.Clear();
        }
        previous.Cancel(); previous.Dispose();
    }
    public void Dispose()
    {
        Clear(); lock (_gate) { if (_disposed) return; _disposed = true; _lifetime.Cancel(); _lifetime.Dispose(); }
    }
    private sealed class Entry(long generation, CancellationTokenSource cancellation)
    {
        public long Generation { get; } = generation;
        public CancellationTokenSource Cancellation { get; } = cancellation;
        public TaskCompletionSource<SynologyPhotoDecodedThumbnail<T>> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int Subscribers { get; set; }
    }
}
