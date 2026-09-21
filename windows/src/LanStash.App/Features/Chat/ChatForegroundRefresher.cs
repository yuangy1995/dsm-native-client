using LanStash.Domain;

namespace LanStash.App.Features.Chat;

internal sealed record ChatForegroundRefreshState(
    bool IsRunning,
    bool IsRefreshing,
    bool HasFailed,
    bool IsRealtimeConnected = false);

internal sealed class ChatForegroundRefresher : IDisposable
{
    // 实时连接不可用时保留五秒轮询；连接成功后只做低频校准。
    private static readonly TimeSpan DefaultPollingInterval = TimeSpan.FromSeconds(5);

    private readonly object _sync = new();
    private readonly Func<Task> _refreshConversations;
    private readonly Func<bool> _canRefreshMessages;
    private readonly Func<Task> _refreshMessages;
    private readonly Action _cancelRefreshes;
    private readonly TimeSpan _pollingInterval;
    private readonly TimeSpan _connectedPollingInterval;
    private readonly TimeSpan _eventCoalesceInterval;
    private readonly Func<CancellationToken, IAsyncEnumerable<ChatRealtimeEvent>>? _observeRealtime;
    private readonly TimeProvider _timeProvider;
    private CancellationTokenSource? _lifetimeCancellation;
    private Task? _pollingTask;
    private Task? _refreshTask;
    private Task? _realtimeTask;
    private Task? _eventRefreshTask;
    private long _eventRevision;
    private DateTimeOffset _lastRefreshAt;
    private long _refreshGeneration = -1;
    private long _generation;
    private bool _disposed;
    private ChatForegroundRefreshState _state = new(false, false, false);

    public ChatForegroundRefresher(
        Func<Task> refreshConversations,
        Func<bool> canRefreshMessages,
        Func<Task> refreshMessages,
        Action cancelRefreshes,
        TimeSpan? pollingInterval = null,
        Func<CancellationToken, IAsyncEnumerable<ChatRealtimeEvent>>? observeRealtime = null,
        TimeSpan? connectedPollingInterval = null,
        TimeSpan? eventCoalesceInterval = null,
        TimeProvider? timeProvider = null)
    {
        ArgumentNullException.ThrowIfNull(refreshConversations);
        ArgumentNullException.ThrowIfNull(canRefreshMessages);
        ArgumentNullException.ThrowIfNull(refreshMessages);
        ArgumentNullException.ThrowIfNull(cancelRefreshes);
        var interval = pollingInterval ?? DefaultPollingInterval;
        if (interval <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(pollingInterval));
        }

        _refreshConversations = refreshConversations;
        _canRefreshMessages = canRefreshMessages;
        _refreshMessages = refreshMessages;
        _cancelRefreshes = cancelRefreshes;
        _pollingInterval = interval;
        _connectedPollingInterval = connectedPollingInterval ?? TimeSpan.FromSeconds(30);
        _eventCoalesceInterval = eventCoalesceInterval ?? TimeSpan.FromMilliseconds(250);
        if (_connectedPollingInterval <= TimeSpan.Zero || _eventCoalesceInterval <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(connectedPollingInterval));
        _observeRealtime = observeRealtime;
        _timeProvider = timeProvider ?? TimeProvider.System;
    }

    public ChatForegroundRefreshState State
    {
        get
        {
            lock (_sync)
            {
                return _state;
            }
        }
    }

    public Task StartAsync(bool refreshImmediately = true)
    {
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_state.IsRunning)
            {
                return refreshImmediately ? GetOrStartRefreshLocked() : Task.CompletedTask;
            }

            _generation++;
            _lifetimeCancellation = new CancellationTokenSource();
            _state = _state with { IsRunning = true, HasFailed = false, IsRealtimeConnected = false };
            _lastRefreshAt = _timeProvider.GetUtcNow();
            _pollingTask = PollAsync(_generation, _lifetimeCancellation.Token);
            if (_observeRealtime is not null) _realtimeTask = ObserveRealtimeCoreAsync(_generation, _lifetimeCancellation.Token);
            return refreshImmediately ? GetOrStartRefreshLocked() : Task.CompletedTask;
        }
    }

    public Task RefreshAsync()
    {
        lock (_sync)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _state.IsRunning ? GetOrStartRefreshLocked() : Task.CompletedTask;
        }
    }

    public Task StopAsync()
    {
        CancellationTokenSource? cancellation;
        Task? pollingTask;
        Task? refreshTask;
        Task? realtimeTask;
        Task? eventTask;
        var wasRunning = true;
        lock (_sync)
        {
            if (!_state.IsRunning)
            {
                wasRunning = false;
                cancellation = null;
                pollingTask = null;
                refreshTask = null;
                realtimeTask = null; eventTask = null;
            }
            else
            {
                _generation++;
                cancellation = _lifetimeCancellation;
                pollingTask = _pollingTask;
                refreshTask = _refreshTask;
                realtimeTask = _realtimeTask; eventTask = _eventRefreshTask;
                _realtimeTask = null; _eventRefreshTask = null;
                _lifetimeCancellation = null;
                _pollingTask = null;
                _state = _state with { IsRunning = false, IsRefreshing = false, IsRealtimeConnected = false };
            }
        }

        _cancelRefreshes();
        if (!wasRunning)
        {
            return Task.CompletedTask;
        }
        cancellation?.Cancel();
        _ = FinishStoppedTasksAsync(cancellation, pollingTask, refreshTask, realtimeTask, eventTask);
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        CancellationTokenSource? cancellation;
        Task? pollingTask; Task? refreshTask; Task? realtimeTask; Task? eventTask;
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _generation++;
            cancellation = _lifetimeCancellation;
            pollingTask = _pollingTask; refreshTask = _refreshTask; realtimeTask = _realtimeTask; eventTask = _eventRefreshTask;
            _lifetimeCancellation = null;
            _pollingTask = null;
            _refreshTask = null;
            _realtimeTask = null; _eventRefreshTask = null;
            _refreshGeneration = -1;
            _state = _state with { IsRunning = false, IsRefreshing = false, IsRealtimeConnected = false };
        }

        cancellation?.Cancel();
        _ = FinishStoppedTasksAsync(cancellation, pollingTask, refreshTask, realtimeTask, eventTask);
        _cancelRefreshes();
    }

    private Task GetOrStartRefreshLocked()
    {
        if (_refreshTask is not null && _refreshGeneration == _generation)
        {
            return _refreshTask;
        }

        _state = _state with { IsRefreshing = true };
        _refreshGeneration = _generation;
        _refreshTask = RefreshCoreAsync(
            _generation,
            _lifetimeCancellation?.Token ?? CancellationToken.None);
        return _refreshTask;
    }

    private async Task RefreshCoreAsync(long generation, CancellationToken cancellationToken)
    {
        try
        {
            await Task.Yield();
            if (!IsCurrent(generation) || cancellationToken.IsCancellationRequested) return;
            await _refreshConversations();
            if (!IsCurrent(generation) || cancellationToken.IsCancellationRequested)
            {
                return;
            }
            if (_canRefreshMessages())
            {
                await _refreshMessages();
            }
            lock (_sync)
            {
                if (IsCurrent(generation))
                {
                    _state = _state with { HasFailed = false };
                    _lastRefreshAt = _timeProvider.GetUtcNow();
                }
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
                    _state = _state with { HasFailed = true };
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
                await Task.Delay(_pollingInterval, _timeProvider, cancellationToken);
                lock (_sync)
                {
                    if (!IsCurrent(generation)) return;
                    if (_state.IsRealtimeConnected && !_state.HasFailed && _timeProvider.GetUtcNow() - _lastRefreshAt < _connectedPollingInterval) continue;
                }
                await RefreshForGenerationAsync(generation);
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

    private bool IsCurrent(long generation)
    {
        lock (_sync)
        {
            return _state.IsRunning && generation == _generation;
        }
    }

    private async Task ObserveRealtimeCoreAsync(long generation, CancellationToken token)
    {
        try
        {
            await Task.Yield();
            if (!IsCurrent(generation) || token.IsCancellationRequested) return;
            await foreach (var value in _observeRealtime!(token).WithCancellation(token))
            {
                lock (_sync)
                {
                    if (!IsCurrent(generation) || token.IsCancellationRequested) return;
                    _state = _state with { IsRealtimeConnected = value != ChatRealtimeEvent.Disconnected };
                    if (value is ChatRealtimeEvent.Connected or ChatRealtimeEvent.ContentChanged)
                    {
                        _eventRevision++;
                        _eventRefreshTask ??= RefreshRealtimeEventsAsync(generation, token);
                    }
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { /* 实时通道独立失败时继续原有轮询，不清空消息或中断发送。 */ }
        finally
        {
            lock (_sync)
            {
                if (IsCurrent(generation)) { _state = _state with { IsRealtimeConnected = false }; _realtimeTask = null; }
            }
        }
    }

    private async Task RefreshRealtimeEventsAsync(long generation, CancellationToken token)
    {
        var completedNormally = false;
        try
        {
            await Task.Yield();
            while (true)
            {
                await Task.Delay(_eventCoalesceInterval, _timeProvider, token);
                long revision;
                Task? previous;
                lock (_sync)
                {
                    if (!IsCurrent(generation)) return;
                    revision = _eventRevision;
                    previous = _refreshGeneration == generation ? _refreshTask : null;
                }
                // 事件可能晚于当前请求的快照；先等待当前单飞请求，再执行一次新的回读。
                if (previous is not null) await previous;
                if (!IsCurrent(generation) || token.IsCancellationRequested) return;
                await RefreshForGenerationAsync(generation);
                lock (_sync)
                {
                    if (!IsCurrent(generation)) return;
                    if (revision == _eventRevision) { completedNormally = true; _eventRefreshTask = null; return; }
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (ObjectDisposedException) { }
        finally
        {
            lock (_sync) { if (!completedNormally && generation == _generation) _eventRefreshTask = null; }
        }
    }

    private Task RefreshForGenerationAsync(long generation)
    {
        lock (_sync) return IsCurrent(generation) ? GetOrStartRefreshLocked() : Task.CompletedTask;
    }

    private async Task FinishStoppedTasksAsync(
        CancellationTokenSource? cancellation,
        Task? pollingTask,
        Task? refreshTask,
        Task? realtimeTask,
        Task? eventTask)
    {
        try
        {
            if (pollingTask is not null)
            {
                await pollingTask.ConfigureAwait(false);
            }
            if (refreshTask is not null && !ReferenceEquals(refreshTask, pollingTask))
            {
                await refreshTask.ConfigureAwait(false);
            }
            if (realtimeTask is not null) await realtimeTask.ConfigureAwait(false);
            if (eventTask is not null) await eventTask.ConfigureAwait(false);
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
            }
        }
    }
}
