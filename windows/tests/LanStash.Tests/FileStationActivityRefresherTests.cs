using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class FileStationActivityRefresherTests
{
    [Fact]
    public async Task DisposalImmediatelyPreventsRestartWhileReadDrains()
    {
        var repository = new StubRepository(isAvailable: true);
        var delayed = new TaskCompletionSource<FileBackgroundTaskPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => delayed.Task;
        var callbackCount = 0;
        var refresher = new FileStationActivityRefresher(repository, _ => callbackCount++, TimeSpan.FromMinutes(1));
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
        var repository = new StubRepository(isAvailable: true);
        var delayed = new TaskCompletionSource<FileBackgroundTaskPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => delayed.Task;
        var callbackCount = 0;
        var refresher = new FileStationActivityRefresher(repository, _ => callbackCount++, TimeSpan.FromMinutes(1));
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
        var repository = new StubRepository(isAvailable: true);
        var first = new TaskCompletionSource<FileBackgroundTaskPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var second = new TaskCompletionSource<FileBackgroundTaskPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var secondStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => { if (repository.CallCount == 1) return first.Task; secondStarted.TrySetResult(); return second.Task; };
        var callbackCount = 0;
        var refresher = new FileStationActivityRefresher(repository, _ => callbackCount++, TimeSpan.FromMinutes(1));
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

    [Fact]
    public async Task UnavailableRepositoryMakesNoRequest()
    {
        var repository = new StubRepository(isAvailable: false);
        await using var refresher = new FileStationActivityRefresher(repository, _ => { });

        await refresher.StartAsync();
        await refresher.RefreshAsync();

        Assert.Equal(0, repository.CallCount);
        Assert.False(refresher.State.IsRunning);
        Assert.False(refresher.State.HasSnapshot);
    }

    [Fact]
    public async Task StartImmediatelyLoadsFirstHundredTasksAndReportsTruncation()
    {
        var repository = new StubRepository(isAvailable: true)
        {
            Result = Page(
                Enumerable.Range(1, 100).Select(TaskItem).ToArray(),
                total: 105,
                hasMore: true),
        };
        IReadOnlyList<FileBackgroundTaskSummary>? applied = null;
        await using var refresher = new FileStationActivityRefresher(
            repository,
            tasks => applied = tasks,
            TimeSpan.FromMinutes(1));

        await refresher.StartAsync();

        Assert.Equal([(0, 100)], repository.Arguments);
        Assert.Equal(100, Assert.IsAssignableFrom<IReadOnlyList<FileBackgroundTaskSummary>>(applied).Count);
        Assert.Equal(
            new FileStationActivityRefreshState(true, false, true, false, 100, 105, true),
            refresher.State);
    }

    [Fact]
    public async Task ConcurrentRefreshesShareOneRequestAndFailureKeepsSnapshot()
    {
        var repository = new StubRepository(isAvailable: true);
        var delayed = new TaskCompletionSource<FileBackgroundTaskPage>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => delayed.Task;
        var applied = new List<IReadOnlyList<FileBackgroundTaskSummary>>();
        await using var refresher = new FileStationActivityRefresher(
            repository,
            applied.Add,
            TimeSpan.FromMinutes(1));

        var first = refresher.StartAsync();
        await repository.FirstCall.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var second = refresher.RefreshAsync();
        Assert.Same(first, second);
        delayed.SetResult(Page([TaskItem(1)], 1, false));
        await Task.WhenAll(first, second);

        repository.Handler = (_, _, _) => throw new InvalidOperationException("synthetic");
        await refresher.RefreshAsync();

        Assert.Single(applied);
        Assert.True(refresher.State.HasSnapshot);
        Assert.True(refresher.State.HasFailed);
        Assert.Equal(1, refresher.State.DisplayedTaskCount);
    }

    [Fact]
    public async Task StopWaitsForRequestAndRejectsLateResult()
    {
        var repository = new StubRepository(isAvailable: true);
        var delayed = new TaskCompletionSource<FileBackgroundTaskPage>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (_, _, _) => delayed.Task;
        var callbackCount = 0;
        await using var refresher = new FileStationActivityRefresher(
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
    }

    [Fact]
    public async Task PollingStopsWithThePageLifecycle()
    {
        var repository = new StubRepository(isAvailable: true)
        {
            CallSignal = new SemaphoreSlim(0),
        };
        await using var refresher = new FileStationActivityRefresher(
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

    [Fact]
    public async Task LoadMoreUsesCursorAndRefreshKeepsExpandedRange()
    {
        var repository = new StubRepository(isAvailable: true);
        repository.Handler = (offset, limit, _) => Task.FromResult(PageAt(Enumerable.Range(offset + 1, Math.Min(limit, 250 - offset)).Select(TaskItem).ToArray(), offset, 250));
        IReadOnlyList<FileBackgroundTaskSummary> shown = [];
        await using var refresher = new FileStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
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
        var repository = new StubRepository(isAvailable: true); var fail = true;
        repository.Handler = (offset, _, _) => offset == 100 && fail ? Task.FromException<FileBackgroundTaskPage>(new IOException("synthetic")) :
            Task.FromResult(PageAt(Enumerable.Range(offset + 1, offset == 0 ? 100 : 50).Select(TaskItem).ToArray(), offset, 150));
        IReadOnlyList<FileBackgroundTaskSummary> shown = [];
        await using var refresher = new FileStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); await refresher.LoadMoreAsync();
        Assert.Equal(100, shown.Count); Assert.True(refresher.State.HasFailed); Assert.True(refresher.CanLoadMore);
        fail = false; await refresher.LoadMoreAsync();
        Assert.Equal(150, shown.Count); Assert.False(refresher.State.HasFailed); Assert.False(refresher.CanLoadMore);
        Assert.Equal(new[] { (0, 100), (100, 100), (100, 100) }, repository.Arguments);
    }

    [Fact]
    public async Task FailedExpandedRefreshDoesNotCommitOnlyItsFirstPage()
    {
        var repository = new StubRepository(isAvailable: true); var total = 200; var fail = false;
        repository.Handler = (offset, limit, _) => offset > 0 && fail ? Task.FromException<FileBackgroundTaskPage>(new IOException("synthetic")) :
            Task.FromResult(PageAt(Enumerable.Range(offset + 1, Math.Min(limit, total - offset)).Select(TaskItem).ToArray(), offset, total));
        var applied = new List<IReadOnlyList<FileBackgroundTaskSummary>>();
        await using var refresher = new FileStationActivityRefresher(repository, applied.Add, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); await refresher.LoadMoreAsync(); fail = true;
        await refresher.RefreshAsync(); Assert.Equal(2, applied.Count); Assert.Equal(200, applied[^1].Count); Assert.True(refresher.State.HasFailed);
        fail = false; total = 50; await refresher.RefreshAsync();
        Assert.Equal(50, applied[^1].Count); Assert.False(refresher.State.IsTruncated); Assert.False(refresher.CanLoadMore);
    }

    [Fact]
    public async Task MoreAndRefreshShareSingleFlightAndStoppedMoreCannotCommit()
    {
        var repository = new StubRepository(isAvailable: true);
        var delayed = new TaskCompletionSource<FileBackgroundTaskPage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Handler = (offset, _, _) => { if (offset == 0) return Task.FromResult(PageAt(Enumerable.Range(1, 100).Select(TaskItem).ToArray(), 0, 150)); started.TrySetResult(); return delayed.Task; };
        IReadOnlyList<FileBackgroundTaskSummary> shown = [];
        await using var refresher = new FileStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); var more = refresher.LoadMoreAsync(); await started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Same(more, refresher.LoadMoreAsync()); Assert.Same(more, refresher.RefreshAsync()); Assert.False(refresher.CanLoadMore);
        var stopping = refresher.StopAsync(); delayed.TrySetResult(PageAt(Enumerable.Range(101, 50).Select(TaskItem).ToArray(), 100, 150));
        await Task.WhenAll(more, stopping); Assert.Equal(100, shown.Count); Assert.False(refresher.CanLoadMore); Assert.Equal(2, repository.CallCount);
    }

    [Theory]
    [InlineData("offset")] [InlineData("oversized")] [InlineData("duplicate")]
    public async Task MalformedContinuationDoesNotReplacePreviouslyLoadedTasks(string failure)
    {
        var repository = new StubRepository(isAvailable: true);
        repository.Handler = (offset, _, _) =>
        {
            var tasks = Enumerable.Range(offset + 1, failure == "oversized" && offset > 0 ? 101 : 100).Select(TaskItem).ToArray();
            if (offset > 0 && failure == "duplicate") tasks[1] = tasks[0];
            var page = PageAt(tasks, offset, 300);
            return Task.FromResult(offset > 0 && failure == "offset" ? page with { Offset = 0 } : page);
        };
        IReadOnlyList<FileBackgroundTaskSummary> shown = [];
        await using var refresher = new FileStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); await refresher.LoadMoreAsync();
        Assert.Equal(100, shown.Count); Assert.True(refresher.State.HasFailed); Assert.True(refresher.CanLoadMore);
    }

    [Fact]
    public async Task OverlappingPageIdentityIsNotShownTwice()
    {
        var repository = new StubRepository(isAvailable: true);
        repository.Handler = (offset, _, _) => Task.FromResult(PageAt(offset == 0 ? Enumerable.Range(1, 100).Select(TaskItem).ToArray() : [TaskItem(100), TaskItem(101)], offset, 102));
        IReadOnlyList<FileBackgroundTaskSummary> shown = [];
        await using var refresher = new FileStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); await refresher.LoadMoreAsync(); Assert.Equal(101, shown.Count); Assert.Single(shown, item => item.Id == "task-100");
    }

    private static FileBackgroundTaskPage PageAt(IReadOnlyList<FileBackgroundTaskSummary> tasks, int offset, int total) => new(tasks, offset, offset + tasks.Count, total, offset + tasks.Count < total);

    [Fact]
    public async Task FilteredOutRawRecordsStillAdvanceTheReportedCursor()
    {
        var repository = new StubRepository(isAvailable: true);
        repository.Handler = (offset, _, _) => Task.FromResult(offset == 0 ? new FileBackgroundTaskPage([], 0, 100, 101, true) : new([TaskItem(101)], 100, 101, 101, false));
        IReadOnlyList<FileBackgroundTaskSummary> shown = [];
        await using var refresher = new FileStationActivityRefresher(repository, tasks => shown = tasks, TimeSpan.FromMinutes(1));
        await refresher.StartAsync(); Assert.Empty(shown); Assert.True(refresher.CanLoadMore);
        await refresher.LoadMoreAsync(); Assert.Equal("task-101", Assert.Single(shown).Id); Assert.Equal((100, 100), repository.Arguments[^1]);
    }

    private static FileBackgroundTaskPage Page(
        IReadOnlyList<FileBackgroundTaskSummary> tasks,
        int total,
        bool hasMore) =>
        new(tasks, 0, tasks.Count, total, hasMore);

    private static FileBackgroundTaskSummary TaskItem(int index) =>
        new(
            $"task-{index}",
            FileBackgroundTaskKind.CopyOrMove,
            FileBackgroundTaskState.Active,
            0.5,
            DateTimeOffset.UnixEpoch,
            null,
            null,
            50,
            100);

    private sealed class StubRepository(bool isAvailable) : IFileBackgroundTaskRepository
    {
        private int _callCount;

        public Guid ProfileId { get; } = Guid.NewGuid();
        public bool IsAvailable { get; } = isAvailable;
        public FileBackgroundTaskPage Result { get; set; } = Page([], 0, false);
        public Func<int, int, CancellationToken, Task<FileBackgroundTaskPage>>? Handler { get; set; }
        public List<(int Offset, int Limit)> Arguments { get; } = [];
        public TaskCompletionSource FirstCall { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);
        public SemaphoreSlim? CallSignal { get; set; }
        public int CallCount => Volatile.Read(ref _callCount);

        public Task<FileBackgroundTaskPage> ListTasksAsync(
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
    }
}
