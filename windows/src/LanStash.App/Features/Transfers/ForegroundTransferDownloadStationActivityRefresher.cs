using LanStash.Domain;

namespace LanStash.App.Features.Transfers;

internal sealed record DownloadStationActivityRefreshState(
    bool IsRunning,
    bool IsRefreshing,
    bool HasSnapshot,
    bool HasFailed,
    int DisplayedTaskCount,
    int SourceTotal,
    bool IsTruncated);

internal sealed class DownloadStationActivityRefresher : IAsyncDisposable
{
    private const int TaskLimit = 100;
    private static readonly TimeSpan DefaultPollingInterval = TimeSpan.FromSeconds(5);

    private readonly object _sync = new();
    private readonly IDownloadStationRepository _repository;
    private readonly Action<IReadOnlyList<DownloadTask>> _applyTasks;
    private readonly TimeSpan _pollingInterval;
    private CancellationTokenSource? _lifetimeCancellation;
    private Task? _pollingTask;
    private Task? _refreshTask;
    private Task? _stopTask;
    private Task? _disposeTask;
    private long _refreshGeneration = -1;
    private long _generation;
    private bool _disposed;
    private DownloadTask[] _loadedTasks = [];
    private int _loadedEndOffset;
    private int? _nextOffset;
    private DownloadStationActivityRefreshState _state = new(
        IsRunning: false,
        IsRefreshing: false,
        HasSnapshot: false,
        HasFailed: false,
        DisplayedTaskCount: 0,
        SourceTotal: 0,
        IsTruncated: false);

    public DownloadStationActivityRefresher(
        IDownloadStationRepository repository,
        Action<IReadOnlyList<DownloadTask>> applyTasks,
        TimeSpan? pollingInterval = null)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(applyTasks);
        var interval = pollingInterval ?? DefaultPollingInterval;
        if (interval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(pollingInterval));
        }

        _repository = repository;
        _applyTasks = applyTasks;
        _pollingInterval = interval;
    }

    public DownloadStationActivityRefreshState State
    {
        get
        {
            lock (_sync)
            {
                return _state;
            }
        }
    }

    public Task StartAsync()
    {
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_state.IsRunning)
            {
                return CanReadTasks() ? GetOrStartRefreshLocked() : Task.CompletedTask;
            }

            if (!CanReadTasks())
            {
                return Task.CompletedTask;
            }

            _generation++;
            _lifetimeCancellation = new CancellationTokenSource();
            _state = _state with { IsRunning = true, HasFailed = false };
            _pollingTask = PollAsync(_generation, _lifetimeCancellation.Token);
            return GetOrStartRefreshLocked();
        }
    }

    public Task RefreshAsync()
    {
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (!_state.IsRunning || !CanReadTasks())
            {
                return Task.CompletedTask;
            }

            return GetOrStartRefreshLocked();
        }
    }

    public bool CanLoadMore
    {
        get { lock (_sync) return !_disposed && _state.IsRunning && !_state.IsRefreshing && _state.HasSnapshot && _nextOffset is not null && CanReadTasks(); }
    }

    public Task LoadMoreAsync()
    {
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (!_state.IsRunning || !_state.HasSnapshot || _nextOffset is null || !CanReadTasks()) return Task.CompletedTask;
            return GetOrStartRefreshLocked(loadMore: true);
        }
    }

    public Task StopAsync()
    {
        lock (_sync)
        {
            if (!_state.IsRunning)
            {
                return _stopTask ?? Task.CompletedTask;
            }

            _generation++;
            var cancellation = _lifetimeCancellation;
            var pollingTask = _pollingTask;
            var refreshTask = _refreshTask;
            _lifetimeCancellation = null;
            _pollingTask = null;
            _state = _state with { IsRunning = false, IsRefreshing = false };
            _stopTask = DrainStoppedRequestsAsync(_generation, cancellation, pollingTask, refreshTask, _stopTask);
            return _stopTask;
        }
    }

    private async Task DrainStoppedRequestsAsync(long generation, CancellationTokenSource? cancellation,
        Task? pollingTask, Task? refreshTask, Task? previousStop)
    {
        // 先发布停止状态再离开锁；取消回调和网络等待不得阻塞状态锁。
        await Task.Yield();
        try
        {
            cancellation?.Cancel();
            await Task.WhenAll(previousStop ?? Task.CompletedTask, pollingTask ?? Task.CompletedTask,
                refreshTask ?? Task.CompletedTask).ConfigureAwait(false);
        }
        finally
        {
            cancellation?.Dispose();
            lock (_sync)
            {
                if (ReferenceEquals(_refreshTask, refreshTask))
                {
                    _refreshTask = null;
                    _refreshGeneration = -1;
                }
                if (generation == _generation) _stopTask = null;
            }
        }
    }

    public ValueTask DisposeAsync()
    {
        lock (_sync)
        {
            if (_disposeTask is null)
            {
                _disposed = true;
                _loadedTasks = []; _nextOffset = null; _loadedEndOffset = 0;
                _disposeTask = StopAsync();
            }
            return new ValueTask(_disposeTask);
        }
    }

    private bool CanReadTasks() =>
        _repository.Availability.Status == DownloadStationAvailabilityStatus.Available &&
        _repository.Availability.SupportedFeatures.Contains(DownloadStationReadFeature.Tasks);

    private Task GetOrStartRefreshLocked(bool loadMore = false)
    {
        if (_refreshTask is not null && _refreshGeneration == _generation)
        {
            return _refreshTask;
        }

        _state = _state with { IsRefreshing = true };
        _refreshGeneration = _generation;
        _refreshTask = RefreshCoreAsync(
            _generation,
            _lifetimeCancellation?.Token ?? CancellationToken.None, loadMore);
        return _refreshTask;
    }

    private async Task RefreshCoreAsync(long generation, CancellationToken cancellationToken, bool loadMore)
    {
        try
        {
            await Task.Yield();
            int offset;
            int refreshEnd;
            List<DownloadTask> tasks;
            lock (_sync)
            {
                if (!IsCurrent(generation) || cancellationToken.IsCancellationRequested) return;
                offset = loadMore ? _nextOffset ?? 0 : 0;
                refreshEnd = Math.Max(TaskLimit, _loadedEndOffset);
                tasks = loadMore ? new List<DownloadTask>(_loadedTasks) : [];
            }
            var positions = tasks.Select((task, index) => (task.Id, index)).ToDictionary(pair => pair.Id, pair => pair.index, StringComparer.Ordinal);
            int end;
            int total;
            bool hasMore;
            while (true)
            {
                lock (_sync) { if (!IsCurrent(generation)) return; }
                cancellationToken.ThrowIfCancellationRequested();
                var page = await _repository.ListTasksAsync(offset, TaskLimit, cancellationToken).ConfigureAwait(false);
                end = checked(page.SourceOffset + page.SourceRecordCount); total = page.SourceTotal; hasMore = page.HasMore || total > end;
                if (page.NextOffset is { } cursor && cursor != end || page.HasMore && page.NextOffset is null)
                    throw new InvalidOperationException("activity.pagination.cursor");
                if (page.SourceOffset != offset || page.Tasks.Count > TaskLimit || total < end || end < offset ||
                    (long)end - offset > TaskLimit || page.Tasks.Count > (long)end - offset || hasMore && end == offset)
                    throw new InvalidOperationException("activity.pagination.invalid");
                var pageIds = new HashSet<string>(StringComparer.Ordinal);
                foreach (var task in page.Tasks)
                {
                    if (string.IsNullOrWhiteSpace(task.Id) || !pageIds.Add(task.Id)) throw new InvalidOperationException("activity.pagination.identity");
                    if (positions.TryGetValue(task.Id, out var index)) tasks[index] = task;
                    else { positions.Add(task.Id, tasks.Count); tasks.Add(task); }
                }
                if (loadMore || !hasMore || end >= refreshEnd) break;
                offset = end;
            }
            var snapshot = tasks.ToArray();

            lock (_sync)
            {
                if (!IsCurrent(generation) || cancellationToken.IsCancellationRequested)
                {
                    return;
                }

                _applyTasks(snapshot);
                _loadedTasks = snapshot; _loadedEndOffset = end; _nextOffset = hasMore ? end : null;
                _state = new DownloadStationActivityRefreshState(
                    IsRunning: true,
                    IsRefreshing: false,
                    HasSnapshot: true,
                    HasFailed: false,
                    DisplayedTaskCount: snapshot.Length,
                    SourceTotal: total,
                    IsTruncated: hasMore);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch
        {
            lock (_sync)
            {
                if (IsCurrent(generation))
                {
                    _state = _state with { IsRefreshing = false, HasFailed = true };
                }
            }
        }
        finally
        {
            lock (_sync)
            {
                if (generation == _generation)
                {
                    _refreshTask = null;
                    _refreshGeneration = -1;
                    _state = _state with { IsRefreshing = false };
                }
            }
        }
    }

    private async Task PollAsync(long generation, CancellationToken cancellationToken)
    {
        try
        {
            while (true)
            {
                await Task.Delay(_pollingInterval, cancellationToken).ConfigureAwait(false);
                await RefreshAsync().ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException)
        {
        }
        finally
        {
            lock (_sync)
            {
                if (generation == _generation)
                {
                    _pollingTask = null;
                }
            }
        }
    }

    private bool IsCurrent(long generation) =>
        !_disposed && _state.IsRunning && generation == _generation;
}
