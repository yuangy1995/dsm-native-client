using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DownloadStationActivityRefresherTests
{
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
        repository.Result = Page(Enumerable.Range(1, 105).Select(TaskItem).ToArray(), 105, true);
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
