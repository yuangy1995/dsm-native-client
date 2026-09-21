using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DownloadStationActivityRefresherTests
{
    [Fact]
    public async Task DisposalImmediatelyPreventsRestartWhileReadDrains()
    {
        var repository = AvailableRepository();
        var delayed = new TaskCompletionSource<DownloadTaskPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => delayed.Task;
        var callbackCount = 0;
        var refresher = new DownloadStationActivityRefresher(repository, _ => callbackCount++, TimeSpan.FromMinutes(1));
        var reading = refresher.StartAsync(); await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var disposing = refresher.DisposeAsync().AsTask();
        try
        {
            Assert.Throws<ObjectDisposedException>(() => { _ = refresher.StartAsync(); });
            Assert.Throws<ObjectDisposedException>(() => { _ = refresher.RefreshAsync(); });
            Assert.False(disposing.IsCompleted);
        }
        finally
        {
            delayed.TrySetResult(Page([TaskItem(1)], 1, false));
            await Task.WhenAll(reading, disposing).WaitAsync(TimeSpan.FromSeconds(2));
            await refresher.StopAsync();
        }
        Assert.Equal(1, repository.CallCount); Assert.Equal(0, callbackCount);
    }

    [Fact]
    public async Task ConcurrentDisposeWaitsForEarlierStopAndDoesNotAcceptLateData()
    {
        var repository = AvailableRepository();
        var delayed = new TaskCompletionSource<DownloadTaskPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => delayed.Task;
        var callbackCount = 0;
        var refresher = new DownloadStationActivityRefresher(repository, _ => callbackCount++, TimeSpan.FromMinutes(1));
        var reading = refresher.StartAsync(); await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var stopping = refresher.StopAsync();
        var firstDispose = refresher.DisposeAsync().AsTask(); var secondDispose = refresher.DisposeAsync().AsTask();
        try { Assert.False(firstDispose.IsCompleted); Assert.False(secondDispose.IsCompleted); }
        finally
        {
            delayed.TrySetResult(Page([TaskItem(1)], 1, false));
            await Task.WhenAll(reading, stopping, firstDispose, secondDispose).WaitAsync(TimeSpan.FromSeconds(2));
        }
        Assert.Equal(0, callbackCount); Assert.False(refresher.State.IsRunning);
    }

    [Fact]
    public async Task DisposalDrainsBothGenerationsWhenRestartOverlapsAnEarlierStop()
    {
        var repository = AvailableRepository();
        var first = new TaskCompletionSource<DownloadTaskPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var second = new TaskCompletionSource<DownloadTaskPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var secondStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => { if (repository.CallCount == 1) return first.Task; secondStarted.TrySetResult(); return second.Task; };
        var callbackCount = 0;
        var refresher = new DownloadStationActivityRefresher(repository, _ => callbackCount++, TimeSpan.FromMinutes(1));
        var firstRead = refresher.StartAsync(); await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var stopping = refresher.StopAsync(); var secondRead = refresher.StartAsync(); await secondStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var disposing = refresher.DisposeAsync().AsTask();
        try
        {
            second.TrySetResult(Page([TaskItem(2)], 1, false)); await secondRead;
            Assert.False(disposing.IsCompleted); Assert.Equal(0, callbackCount);
        }
        finally
        {
            first.TrySetResult(Page([TaskItem(1)], 1, false)); second.TrySetResult(Page([TaskItem(2)], 1, false));
            await Task.WhenAll(firstRead, secondRead, stopping, disposing).WaitAsync(TimeSpan.FromSeconds(2));
        }
        Assert.False(refresher.State.IsRunning); Assert.Equal(0, callbackCount);
    }

    [Theory]
    [InlineData(DownloadStationAvailabilityStatus.Unavailable, true)]
    [InlineData(DownloadStationAvailabilityStatus.Available, false)]
    public async Task UnsupportedAvailabilityMakesNoRequest(
        DownloadStationAvailabilityStatus status,
        bool includesTasks)
    {
        var repository = new StubRepository(Availability(status, includesTasks));
        await using var refresher = new DownloadStationActivityRefresher(repository, _ => { });

        await refresher.StartAsync();
        await refresher.RefreshAsync();

        Assert.Equal(0, repository.CallCount);
        Assert.False(refresher.State.IsRunning);
        Assert.False(refresher.State.HasSnapshot);
    }

    [Fact]
    public async Task StartImmediatelyLoadsFirstHundredTasksAndReportsTruncation()
    {
        var repository = AvailableRepository();
        repository.Result = Page(Enumerable.Range(1, 100).Select(TaskItem).ToArray(), 105, true);
        IReadOnlyList<DownloadTask>? applied = null;
        await using var refresher = new DownloadStationActivityRefresher(
            repository,
            tasks => applied = tasks,
            TimeSpan.FromMinutes(1));

        await refresher.StartAsync();

        Assert.Equal([(0, 100)], repository.Arguments);
        Assert.NotNull(applied);
        Assert.Equal(100, applied.Count);
        Assert.Equal("task-100", applied[^1].Id);
        Assert.Equal(
            new DownloadStationActivityRefreshState(true, false, true, false, 100, 105, true),
            refresher.State);
    }

    [Fact]
    public async Task ConcurrentManualRefreshesShareSingleInFlightRequest()
    {
        var repository = AvailableRepository();
        var delayed = new TaskCompletionSource<DownloadTaskPage>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => delayed.Task;
        await using var refresher = new DownloadStationActivityRefresher(
            repository,
            _ => { },
            TimeSpan.FromMinutes(1));

        var first = refresher.StartAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var second = refresher.RefreshAsync();
        var third = refresher.RefreshAsync();

        Assert.Same(first, second);
        Assert.Same(first, third);
        Assert.Equal(1, repository.CallCount);
        delayed.SetResult(Page([TaskItem(1)], 1, false));
        await Task.WhenAll(first, second, third);
        Assert.Equal(1, repository.CallCount);
    }

    [Fact]
    public async Task FailureKeepsPreviousSnapshotAndMarksFailure()
    {
        var repository = AvailableRepository();
        var applied = new List<IReadOnlyList<DownloadTask>>();
        await using var refresher = new DownloadStationActivityRefresher(
            repository,
            applied.Add,
            TimeSpan.FromMinutes(1));
        await refresher.StartAsync();
        var previousState = refresher.State;
        repository.Handler = (_, _, _) => throw new InvalidOperationException("synthetic");

        await refresher.RefreshAsync();

        Assert.Single(applied);
        Assert.True(refresher.State.HasSnapshot);
        Assert.True(refresher.State.HasFailed);
        Assert.Equal(previousState.DisplayedTaskCount, refresher.State.DisplayedTaskCount);
        Assert.Equal(previousState.SourceTotal, refresher.State.SourceTotal);
        Assert.Equal(previousState.IsTruncated, refresher.State.IsTruncated);
    }

    [Fact]
    public async Task StopWaitsForRequestAndRejectsLateResult()
    {
        var repository = AvailableRepository();
        var delayed = new TaskCompletionSource<DownloadTaskPage>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => delayed.Task;
        var callbackCount = 0;
        await using var refresher = new DownloadStationActivityRefresher(
            repository,
            _ => callbackCount++,
            TimeSpan.FromMinutes(1));
        var refresh = refresher.StartAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));

        var stop = refresher.StopAsync();
        Assert.False(stop.IsCompleted);
        delayed.SetResult(Page([TaskItem(1)], 1, false));
        await stop.WaitAsync(TimeSpan.FromSeconds(2));
        await refresh;

        Assert.Equal(0, callbackCount);
        Assert.False(refresher.State.IsRunning);
        Assert.False(refresher.State.HasFailed);
        Assert.False(refresher.State.HasSnapshot);
    }

    [Fact]
    public async Task LifecycleCancellationIsNotReportedAsFailure()
    {
        var repository = AvailableRepository();
        repository.Handler = async (_, _, token) =>
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return Page([], 0, false);
        };
        await using var refresher = new DownloadStationActivityRefresher(
            repository,
            _ => { },
            TimeSpan.FromMinutes(1));
        var refresh = refresher.StartAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));

        await refresher.StopAsync();
        await refresh;

        Assert.False(refresher.State.HasFailed);
    }

    [Fact]
    public async Task RestartDuringStopStartsANewImmediateRequest()
    {
        var repository = AvailableRepository();
        var firstResult = new TaskCompletionSource<DownloadTaskPage>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var secondResult = new TaskCompletionSource<DownloadTaskPage>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => repository.CallCount == 1
            ? firstResult.Task
            : secondResult.Task;
        var applied = new List<IReadOnlyList<DownloadTask>>();
        await using var refresher = new DownloadStationActivityRefresher(
            repository,
            applied.Add,
            TimeSpan.FromMinutes(1));
        var firstRefresh = refresher.StartAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));

        var stop = refresher.StopAsync();
        var restart = refresher.StartAsync();
        await WaitForCallCountAsync(repository, 2);
        secondResult.SetResult(Page([TaskItem(2)], 1, false));
        await restart;

        Assert.Single(applied);
        Assert.Equal("task-2", applied[0][0].Id);
        firstResult.SetResult(Page([TaskItem(1)], 1, false));
        await Task.WhenAll(firstRefresh, stop);
        Assert.Single(applied);
    }

    [Fact]
    public async Task PollingRefreshesUntilStopped()
    {
        var repository = AvailableRepository();
        repository.CallSignal = new SemaphoreSlim(0);
        await using var refresher = new DownloadStationActivityRefresher(
            repository,
            _ => { },
            TimeSpan.FromMilliseconds(20));

        await refresher.StartAsync();
        Assert.True(await repository.CallSignal.WaitAsync(TimeSpan.FromSeconds(2)));
        Assert.True(await repository.CallSignal.WaitAsync(TimeSpan.FromSeconds(2)));
        await refresher.StopAsync();
        var countAfterStop = repository.CallCount;
        await Task.Delay(60);

        Assert.True(countAfterStop >= 2);
        Assert.Equal(countAfterStop, repository.CallCount);
    }

    private static StubRepository AvailableRepository()
    {
        var repository = new StubRepository(Availability(
            DownloadStationAvailabilityStatus.Available,
            includesTasks: true));
        repository.Result = Page([TaskItem(1)], 1, false);
        return repository;
    }

    private static async Task WaitForCallCountAsync(StubRepository repository, int expected)
    {
        var timeout = DateTime.UtcNow + TimeSpan.FromSeconds(2);
        while (repository.CallCount < expected && DateTime.UtcNow < timeout)
        {
            await Task.Delay(10);
        }
        Assert.Equal(expected, repository.CallCount);
    }

    private static DownloadStationAvailability Availability(
        DownloadStationAvailabilityStatus status,
        bool includesTasks) =>
        new(
            status,
            includesTasks
                ? new HashSet<DownloadStationReadFeature> { DownloadStationReadFeature.Tasks }
                : new HashSet<DownloadStationReadFeature>());

    [Fact]
    public async Task LoadMoreUsesCursorAndRefreshKeepsExpandedRange()
    {
        var repository = AvailableRepository();
        repository.Handler = (offset, limit, _) => Task.FromResult(PageAt(Enumerable.Range(offset + 1, Math.Min(limit, 250 - offset)).Select(TaskItem).ToArray(), offset, 250));
        IReadOnlyList<DownloadTask> shown = [];
        await using var refresher = new DownloadStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
        await refresher.LoadMoreAsync(); Assert.Equal(0, repository.CallCount);
        await refresher.StartAsync(); Assert.True(refresher.CanLoadMore); Assert.Equal(100, shown.Count);
        await refresher.LoadMoreAsync(); Assert.Equal(200, shown.Count); Assert.True(refresher.CanLoadMore);
        await refresher.LoadMoreAsync(); Assert.Equal(250, shown.Count); Assert.False(refresher.CanLoadMore);
        await refresher.LoadMoreAsync(); Assert.Equal(3, repository.CallCount);
        await refresher.RefreshAsync();
        Assert.Equal(250, shown.Count); Assert.Equal("task-250", shown[^1].Id);
        Assert.Equal(new[] { (0, 100), (100, 100), (200, 100), (0, 100), (100, 100), (200, 100) }, repository.Arguments);
    }

    [Fact]
    public async Task FailedMoreKeepsSnapshotAndRetriesSameCursor()
    {
        var repository = AvailableRepository(); var fail = true;
        repository.Handler = (offset, _, _) => offset == 100 && fail ? Task.FromException<DownloadTaskPage>(new IOException("synthetic")) :
            Task.FromResult(PageAt(Enumerable.Range(offset + 1, offset == 0 ? 100 : 50).Select(TaskItem).ToArray(), offset, 150));
        IReadOnlyList<DownloadTask> shown = [];
        await using var refresher = new DownloadStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); await refresher.LoadMoreAsync();
        Assert.Equal(100, shown.Count); Assert.True(refresher.State.HasFailed); Assert.True(refresher.CanLoadMore);
        fail = false; await refresher.LoadMoreAsync();
        Assert.Equal(150, shown.Count); Assert.False(refresher.State.HasFailed); Assert.False(refresher.CanLoadMore);
        Assert.Equal(new[] { (0, 100), (100, 100), (100, 100) }, repository.Arguments);
    }

    [Fact]
    public async Task FailedExpandedRefreshDoesNotCommitOnlyItsFirstPage()
    {
        var repository = AvailableRepository(); var total = 200; var fail = false;
        repository.Handler = (offset, limit, _) => offset > 0 && fail ? Task.FromException<DownloadTaskPage>(new IOException("synthetic")) :
            Task.FromResult(PageAt(Enumerable.Range(offset + 1, Math.Min(limit, total - offset)).Select(TaskItem).ToArray(), offset, total));
        var applied = new List<IReadOnlyList<DownloadTask>>();
        await using var refresher = new DownloadStationActivityRefresher(repository, applied.Add, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); await refresher.LoadMoreAsync(); fail = true;
        await refresher.RefreshAsync(); Assert.Equal(2, applied.Count); Assert.Equal(200, applied[^1].Count); Assert.True(refresher.State.HasFailed);
        fail = false; total = 50; await refresher.RefreshAsync();
        Assert.Equal(50, applied[^1].Count); Assert.False(refresher.State.IsTruncated); Assert.False(refresher.CanLoadMore);
    }

    [Fact]
    public async Task MoreAndRefreshShareSingleFlightAndStoppedMoreCannotCommit()
    {
        var repository = AvailableRepository();
        var delayed = new TaskCompletionSource<DownloadTaskPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (offset, _, _) => { if (offset == 0) return Task.FromResult(PageAt(Enumerable.Range(1, 100).Select(TaskItem).ToArray(), 0, 150)); started.TrySetResult(); return delayed.Task; };
        IReadOnlyList<DownloadTask> shown = [];
        await using var refresher = new DownloadStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); var more = refresher.LoadMoreAsync(); await started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Same(more, refresher.LoadMoreAsync()); Assert.Same(more, refresher.RefreshAsync()); Assert.False(refresher.CanLoadMore);
        var stopping = refresher.StopAsync(); delayed.TrySetResult(PageAt(Enumerable.Range(101, 50).Select(TaskItem).ToArray(), 100, 150));
        await Task.WhenAll(more, stopping); Assert.Equal(100, shown.Count); Assert.False(refresher.CanLoadMore); Assert.Equal(2, repository.CallCount);
    }

    [Theory]
    [InlineData("offset")] [InlineData("oversized")] [InlineData("duplicate")]
    public async Task MalformedContinuationDoesNotReplacePreviouslyLoadedTasks(string failure)
    {
        var repository = AvailableRepository();
        repository.Handler = (offset, _, _) =>
        {
            var tasks = Enumerable.Range(offset + 1, failure == "oversized" && offset > 0 ? 101 : 100).Select(TaskItem).ToArray();
            if (offset > 0 && failure == "duplicate") tasks[1] = tasks[0];
            var page = PageAt(tasks, offset, 300);
            return Task.FromResult(offset > 0 && failure == "offset" ? page with { SourceOffset = 0 } : page);
        };
        IReadOnlyList<DownloadTask> shown = [];
        await using var refresher = new DownloadStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); await refresher.LoadMoreAsync();
        Assert.Equal(100, shown.Count); Assert.True(refresher.State.HasFailed); Assert.True(refresher.CanLoadMore);
    }

    [Fact]
    public async Task OverlappingPageIdentityIsNotShownTwice()
    {
        var repository = AvailableRepository();
        repository.Handler = (offset, _, _) => Task.FromResult(PageAt(offset == 0 ? Enumerable.Range(1, 100).Select(TaskItem).ToArray() : [TaskItem(100), TaskItem(101)], offset, 102));
        IReadOnlyList<DownloadTask> shown = [];
        await using var refresher = new DownloadStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); await refresher.LoadMoreAsync(); Assert.Equal(101, shown.Count); Assert.Single(shown, item => item.Id == "task-100");
    }

    private static DownloadTaskPage PageAt(IReadOnlyList<DownloadTask> tasks, int offset, int total) => new(tasks, offset, tasks.Count, total, offset + tasks.Count < total ? offset + tasks.Count : null, offset + tasks.Count < total);

    private static DownloadTaskPage Page(
        IReadOnlyList<DownloadTask> tasks,
        int total,
        bool hasMore) =>
        new(tasks, 0, tasks.Count, total, hasMore ? tasks.Count : null, hasMore);

    private static DownloadTask TaskItem(int index) =>
        new(
            $"task-{index}",
            $"Task {index}",
            "downloading",
            100,
            index,
            1,
            0,
            "/downloads",
            null);

    private sealed class StubRepository : IDownloadStationRepository
    {
        private int _callCount;

        public StubRepository(DownloadStationAvailability availability)
        {
            Availability = availability;
        }

        public Guid ProfileId { get; } = Guid.NewGuid();
        public DownloadStationAvailability Availability { get; }
        public DownloadTaskPage Result { get; set; } = Page([], 0, false);
        public Func<int, int, CancellationToken, Task<DownloadTaskPage>>? Handler { get; set; }
        public List<(int Offset, int Limit)> Arguments { get; } = [];
        public TaskCompletionSource FirstCall { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        public SemaphoreSlim? CallSignal { get; set; }
        public int CallCount => Volatile.Read(ref _callCount);

        public Task<DownloadTaskPage> ListTasksAsync(
            int offset,
            int limit,
            CancellationToken cancellationToken = default)
        {
            Arguments.Add((offset, limit));
            Interlocked.Increment(ref _callCount);
            FirstCall.TrySetResult();
            CallSignal?.Release();
            return Handler?.Invoke(offset, limit, cancellationToken) ?? Task.FromResult(Result);
        }

        public Task<DownloadStationSnapshot> LoadSnapshotAsync(
            int offset,
            int limit,
            CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("The refresher must not load a full snapshot.");

        public Task<DownloadTaskControlOutcome> ControlTaskAsync(
            DownloadTaskControlRequest request,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
    }
}
