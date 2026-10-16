using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Synology;

/// <summary>复用现有预览，独立读取完整查询；只有实际显示或播放结束事件才能推进。</summary>
public sealed class SynologyPhotoSlideshowModel : ObservableObject, IDisposable
{
    private readonly ISynologyPhotosRepository _repository;
    private readonly SynologyPhotoPreviewModel _preview;
    private readonly Func<CancellationToken, Task> _delay;
    private readonly List<SynologyPhoto> _photos = [];
    private CancellationTokenSource? _session;
    private CancellationTokenSource? _move;
    private CancellationTokenSource? _timer;
    private SynologyPhotoQuery? _query;
    private int _offset;
    private bool _hasMore;
    private bool _ready;
    private bool _videoEnded;
    private bool _disposed;
    private int? _failedDirection;
    private SynologyPhoto? _initialPhoto;
    private bool _needsInitialRead;

    public SynologyPhotoSlideshowModel(ISynologyPhotosRepository repository, SynologyPhotoPreviewModel preview,
        Func<CancellationToken, Task>? delay = null)
    { _repository = repository; _preview = preview; _delay = delay ?? (token => Task.Delay(TimeSpan.FromSeconds(3), token)); }

    public bool IsPresented { get; private set; }
    public bool IsPlaying { get; private set; }
    public bool IsLoading { get; private set; }
    public string? ErrorKey { get; private set; }
    public long MediaGeneration { get; private set; }
    public IReadOnlyList<SynologyPhoto> Photos => _photos;
    public bool HasMore => _hasMore;

    public async Task StartAsync(SynologyPhotoQuery query, SynologyPhoto photo, SynologyPhotoSimilarDetail? similar = null)
    {
        if (_disposed || IsPresented || photo.Id.ProfileId != _repository.ProfileId) return;
        _session = new(); var token = _session.Token;
        _query = query; _offset = 0; _hasMore = true; _photos.Clear();
        _initialPhoto = photo; _needsInitialRead = true;
        IsPresented = IsPlaying = IsLoading = true; ErrorKey = null; _ready = false; Changed();
        await InitializeAsync(photo, similar, token);
    }

    private async Task InitializeAsync(SynologyPhoto photo, SynologyPhotoSimilarDetail? similar, CancellationToken token)
    {
        try
        {
            if (photo.SimilarGroup is { } group && photo.AlbumContext is null)
            {
                similar ??= await _repository.SimilarGroupAsync(group.Id, group.Space, token);
                EnsureCurrent(token);
                if (similar is null || similar.Group.Id != group.Id || similar.Group.Space != photo.Id.Space ||
                    !similar.Group.PhotoIds.Contains(photo.Id.ItemId) || similar.Group.Count != similar.Photos.Count ||
                    similar.Photos.Any(item => item.Id.ProfileId != _repository.ProfileId || item.Id.Space != group.Space || item.AlbumContext is not null) ||
                    similar.Photos.Select(item => item.Id.ItemId).Distinct().Count() != similar.Photos.Count ||
                    !similar.Photos.Select(item => item.Id.ItemId).ToHashSet().SetEquals(similar.Group.PhotoIds)) throw Invalid();
                _photos.AddRange(similar.Photos); _query = null; _hasMore = false;
            }
            _needsInitialRead = false;
            await ShowAsync(photo, token);
        }
        catch (OperationCanceledException) when (!Current(token)) { }
        catch (Exception) { if (Current(token)) PlaybackFailed(MediaGeneration); }
    }

    private async Task ShowAsync(SynologyPhoto photo, CancellationToken token)
    {
        EnsureCurrent(token);
        var generation = ++MediaGeneration;
        _ready = false; _videoEnded = false; _failedDirection = null;
        IsLoading = true; ErrorKey = null; Changed();
        await _preview.OpenAsync(photo);
        if (!Current(token) || generation != MediaGeneration) return;
        if (_preview.ErrorKey is not null) PlaybackFailed(generation);
        // 解码成功前不启动图片计时，播放器也必须先报告 MediaOpened。
    }

    public void MediaPresented(long generation)
    {
        if (!IsPresented || generation != MediaGeneration || _ready || _preview.Photo is null || _preview.ErrorKey is not null) return;
        _ready = true; IsLoading = false; Changed(); Schedule();
    }

    public void PlaybackFailed(long generation)
    {
        if (!IsPresented || generation != MediaGeneration) return;
        CancelTimer(); IsPlaying = false; IsLoading = false; ErrorKey = "PhotosSlideshowFailed"; Changed();
    }

    public async Task VideoEndedAsync(long generation)
    {
        if (!IsPresented || generation != MediaGeneration || _preview.MediaSource is null) return;
        _videoEnded = true;
        if (IsPlaying) await AdvanceAsync(1);
    }

    public async Task ToggleAsync()
    {
        if (!IsPresented) return;
        if (IsPlaying)
        {
            IsPlaying = false; CancelTimer(); _move?.Cancel();
            IsLoading = !_ready; Changed(); return;
        }
        var retry = ErrorKey is not null; var direction = _failedDirection;
        ErrorKey = null; IsPlaying = true; Changed();
        if (retry && _needsInitialRead && _initialPhoto is { } initial && _session is { } startSession)
        { IsLoading = true; Changed(); await InitializeAsync(initial, null, startSession.Token); }
        else if (retry && direction is { } failed) await AdvanceAsync(failed);
        else if (_videoEnded) await AdvanceAsync(1);
        else if (retry && _preview.Photo is { } photo && _session is { } session) await ShowAsync(photo, session.Token);
        else Schedule();
    }

    public async Task AdvanceAsync(int direction)
    {
        if (!IsPresented || direction is not (-1 or 1) || _session is null || _preview.Photo is not { } photo) return;
        CancelTimer(); _move?.Cancel();
        using var request = CancellationTokenSource.CreateLinkedTokenSource(_session.Token); _move = request;
        var token = request.Token; IsLoading = true; ErrorKey = null; _failedDirection = direction; Changed();
        try
        {
            while (_photos.All(item => item.Id != photo.Id) && _hasMore) await ReadPageAsync(token);
            EnsureCurrent(token);
            var index = _photos.FindIndex(item => item.Id == photo.Id);
            if (index < 0 || _photos[index].AlbumContext?.OwnerUserId != photo.AlbumContext?.OwnerUserId) throw Invalid();
            if (direction > 0 && index + 1 == _photos.Count && _hasMore) await ReadPageAsync(token);
            if (direction < 0 && index == 0) while (_hasMore) await ReadPageAsync(token);
            EnsureCurrent(token);
            await ShowAsync(_photos[(index + direction + _photos.Count) % _photos.Count], token);
        }
        catch (OperationCanceledException) when (!Current(token)) { }
        catch (Exception) { if (Current(token)) PlaybackFailed(MediaGeneration); }
        finally { if (ReferenceEquals(_move, request)) _move = null; }
    }

    private async Task ReadPageAsync(CancellationToken token)
    {
        if (_query is not { } query) throw Invalid();
        var offset = _offset;
        var page = await _repository.PhotosAsync(query, offset, SynologyPhotosWorkspace.PageSize, token);
        EnsureCurrent(token);
        var existing = _photos.Select(item => item.Id).ToHashSet();
        if (page.Offset != offset || page.Items.Count > SynologyPhotosWorkspace.PageSize ||
            page.NextOffset != checked(offset + page.Items.Count) || page.HasMore && page.Items.Count == 0 ||
            page.Items.Any(item => !existing.Add(item.Id) || item.Id.ProfileId != _repository.ProfileId ||
                (query is SynologyPhotoQuery.Album album
                    ? item.AlbumContext is not { } context || context.AlbumId != album.Id || context.OwnerUserId < 0 ||
                        item.Id.Space != (context.OwnerUserId == 0 ? SynologyPhotoSpace.Shared : SynologyPhotoSpace.Personal)
                    : item.Id.Space != query.Space || item.AlbumContext is not null))) throw Invalid();
        _photos.AddRange(page.Items); _offset = page.NextOffset; _hasMore = page.HasMore;
    }

    private void Schedule()
    {
        CancelTimer();
        if (!IsPresented || !IsPlaying || !_ready || ErrorKey is not null || _preview.MediaSource is not null || _session is null) return;
        var timer = CancellationTokenSource.CreateLinkedTokenSource(_session.Token); _timer = timer;
        _ = WaitAndAdvanceAsync(timer, MediaGeneration);
    }

    private async Task WaitAndAdvanceAsync(CancellationTokenSource timer, long generation)
    {
        var token = timer.Token;
        try
        {
            await _delay(token);
            if (Current(token) && IsPlaying && generation == MediaGeneration) await AdvanceAsync(1);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception) { if (Current(token) && generation == MediaGeneration) PlaybackFailed(generation); }
        finally { if (ReferenceEquals(_timer, timer)) _timer = null; timer.Dispose(); }
    }

    private void CancelTimer() { _timer?.Cancel(); _timer = null; }
    private bool Current(CancellationToken token) => !_disposed && IsPresented && !token.IsCancellationRequested;
    private void EnsureCurrent(CancellationToken token) { if (!Current(token)) throw new OperationCanceledException(token); }
    private static SynologyPhotoException Invalid() => new(SynologyPhotoFailure.InvalidResponse);
    private void Changed() => RaisePropertyChanged(string.Empty);
    public void Stop()
    {
        if (!IsPresented) return;
        IsPresented = IsPlaying = false; MediaGeneration++;
        CancelTimer(); _move?.Cancel(); _session?.Cancel(); _session?.Dispose(); _session = null;
        if (!_ready) _preview.Close();
        IsLoading = false; ErrorKey = null; _query = null; _photos.Clear(); _initialPhoto = null; _failedDirection = null; Changed();
    }
    public void Dispose() { if (_disposed) return; Stop(); _disposed = true; }
}
