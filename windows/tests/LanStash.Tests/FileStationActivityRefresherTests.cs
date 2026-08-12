using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class FileStationActivityRefresherTests
{
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
