using LanStash.Domain;

namespace LanStash.App.Features.Transfers;

internal sealed record FileStationActivityRefreshState(
    bool IsRunning,
    bool IsRefreshing,
    bool HasSnapshot,
    bool HasFailed,
    int DisplayedTaskCount,
    int SourceTotal,
    bool IsTruncated);

internal sealed class FileStationActivityRefresher : IAsyncDisposable
{
    private const int TaskLimit = 100;
    private static readonly TimeSpan DefaultPollingInterval = TimeSpan.FromSeconds(5);

    private readonly object _sync = new();
    private readonly IFileBackgroundTaskRepository _repository;
    private readonly Action<IReadOnlyList<FileBackgroundTaskSummary>> _applyTasks;
    private readonly TimeSpan _pollingInterval;
    private CancellationTokenSource? _lifetimeCancellation;
    private Task? _pollingTask;
    private Task? _refreshTask;
    private long _refreshGeneration = -1;
    private long _generation;
    private bool _disposed;
    private FileStationActivityRefreshState _state = new(
        IsRunning: false,
        IsRefreshing: false,
        HasSnapshot: false,
        HasFailed: false,
        DisplayedTaskCount: 0,
        SourceTotal: 0,
        IsTruncated: false);

    public FileStationActivityRefresher(
        IFileBackgroundTaskRepository repository,
        Action<IReadOnlyList<FileBackgroundTaskSummary>> applyTasks,
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

    public FileStationActivityRefreshState State
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

    private bool CanReadTasks() => _repository.IsAvailable;

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
                _state = new FileStationActivityRefreshState(
                    IsRunning: true,
                    IsRefreshing: false,
                    HasSnapshot: true,
                    HasFailed: false,
                    DisplayedTaskCount: tasks.Length,
                    SourceTotal: page.Total,
                    IsTruncated: page.HasMore || page.Total > page.NextOffset);
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

internal sealed class UnavailableFileBackgroundTaskRepository(Guid profileId) :
    IFileBackgroundTaskRepository
{
    public Guid ProfileId { get; } = profileId;
    public bool IsAvailable => false;

    public Task<FileBackgroundTaskPage> ListTasksAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken = default) =>
        Task.FromException<FileBackgroundTaskPage>(
            new NotSupportedException("File Station background tasks are unavailable."));
}
