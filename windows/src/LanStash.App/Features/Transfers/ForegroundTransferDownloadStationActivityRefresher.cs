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
    private long _refreshGeneration = -1;
    private long _generation;
    private bool _disposed;
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

    public async Task StopAsync()
    {
        CancellationTokenSource? cancellation;
        Task? pollingTask;
        Task? refreshTask;
        lock (_sync)
        {
            if (!_state.IsRunning)
            {
                return;
            }

            _generation++;
            cancellation = _lifetimeCancellation;
            pollingTask = _pollingTask;
            refreshTask = _refreshTask;
            _lifetimeCancellation = null;
            _pollingTask = null;
            _state = _state with { IsRunning = false, IsRefreshing = false };
        }

        cancellation?.Cancel();
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

    public async ValueTask DisposeAsync()
    {
        lock (_sync)
        {
            if (_disposed)
            {
                return;
            }
        }

        await StopAsync().ConfigureAwait(false);
        lock (_sync)
        {
            _disposed = true;
        }
    }

    private bool CanReadTasks() =>
        _repository.Availability.Status == DownloadStationAvailabilityStatus.Available &&
        _repository.Availability.SupportedFeatures.Contains(DownloadStationReadFeature.Tasks);

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
            var page = await _repository.ListTasksAsync(0, TaskLimit, cancellationToken)
                .ConfigureAwait(false);
            var tasks = page.Tasks.Take(TaskLimit).ToArray();

            lock (_sync)
            {
                if (!IsCurrent(generation) || cancellationToken.IsCancellationRequested)
                {
                    return;
                }

                _applyTasks(tasks);
                _state = new DownloadStationActivityRefreshState(
                    IsRunning: true,
                    IsRefreshing: false,
                    HasSnapshot: true,
                    HasFailed: false,
                    DisplayedTaskCount: tasks.Length,
                    SourceTotal: page.SourceTotal,
                    IsTruncated: page.HasMore || page.SourceTotal > tasks.Length);
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
        _state.IsRunning && generation == _generation;
}
