namespace LanStash.App.Features.Chat;

internal sealed record ChatForegroundRefreshState(
    bool IsRunning,
    bool IsRefreshing,
    bool HasFailed);

internal sealed class ChatForegroundRefresher : IDisposable
{
    private static readonly TimeSpan DefaultPollingInterval = TimeSpan.FromSeconds(30);

    private readonly object _sync = new();
    private readonly Func<Task> _refreshConversations;
    private readonly Func<bool> _canRefreshMessages;
    private readonly Func<Task> _refreshMessages;
    private readonly Action _cancelRefreshes;
    private readonly TimeSpan _pollingInterval;
    private CancellationTokenSource? _lifetimeCancellation;
    private Task? _pollingTask;
    private Task? _refreshTask;
    private long _refreshGeneration = -1;
    private long _generation;
    private bool _disposed;
    private ChatForegroundRefreshState _state = new(false, false, false);

    public ChatForegroundRefresher(
        Func<Task> refreshConversations,
        Func<bool> canRefreshMessages,
        Func<Task> refreshMessages,
        Action cancelRefreshes,
        TimeSpan? pollingInterval = null)
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
            _state = _state with { IsRunning = true, HasFailed = false };
            _pollingTask = PollAsync(_generation, _lifetimeCancellation.Token);
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
        var wasRunning = true;
        lock (_sync)
        {
            if (!_state.IsRunning)
            {
                wasRunning = false;
                cancellation = null;
                pollingTask = null;
                refreshTask = null;
            }
            else
            {
                _generation++;
                cancellation = _lifetimeCancellation;
                pollingTask = _pollingTask;
                refreshTask = _refreshTask;
                _lifetimeCancellation = null;
                _pollingTask = null;
                _state = _state with { IsRunning = false, IsRefreshing = false };
            }
        }

        _cancelRefreshes();
        if (!wasRunning)
        {
            return Task.CompletedTask;
        }
        cancellation?.Cancel();
        _ = FinishStoppedTasksAsync(cancellation, pollingTask, refreshTask);
        return Task.CompletedTask;
    }

    public void Dispose()
    {
        CancellationTokenSource? cancellation;
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            _generation++;
            cancellation = _lifetimeCancellation;
            _lifetimeCancellation = null;
            _pollingTask = null;
            _refreshTask = null;
            _refreshGeneration = -1;
            _state = _state with { IsRunning = false, IsRefreshing = false };
        }

        cancellation?.Cancel();
        cancellation?.Dispose();
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
                await Task.Delay(_pollingInterval, cancellationToken);
                await RefreshAsync();
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

    private async Task FinishStoppedTasksAsync(
        CancellationTokenSource? cancellation,
        Task? pollingTask,
        Task? refreshTask)
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
