using LanStash.App.Features.Files.DirectorySize;
using LanStash.Domain;

namespace LanStash.Tests.Files.DirectorySize;

public sealed class FileDirectorySizeViewModelTests
{
    [Fact]
    public async Task ExplicitCalculationPublishesOnlySummary()
    {
        var repository = new StubRepository(
            new DirectorySizeResult(4_096, 3, 2));
        using var model = Model(repository);

        Assert.Equal(FileDirectorySizeState.Ready, model.State);
        Assert.Empty(repository.Paths);

        await model.CalculateAsync();

        Assert.Equal(FileDirectorySizeState.Available, model.State);
        Assert.Equal(new DirectorySizeResult(4_096, 3, 2), model.Summary);
        Assert.Equal(["/home/docs"], repository.Paths);
    }

    [Fact]
    public async Task FailureRequiresExplicitRetryAndKeepsPreviousSummary()
    {
        var repository = new StubRepository(new DirectorySizeResult(100, 1, 0));
        using var model = Model(repository);
        await model.CalculateAsync();
        repository.Error = new InvalidOperationException("synthetic");

        await model.CalculateAsync();

        Assert.Equal(FileDirectorySizeState.Error, model.State);
        Assert.Equal(100, model.Summary?.TotalBytes);
        Assert.Equal(2, repository.Paths.Count);
    }

    [Fact]
    public async Task CancelStopsCurrentCalculationWithoutStartingAnother()
    {
        var repository = new StubRepository();
        using var model = Model(repository);

        var calculation = model.CalculateAsync();
        await repository.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        model.Cancel();
        await calculation;

        Assert.Equal(FileDirectorySizeState.Cancelled, model.State);
        Assert.Single(repository.Paths);
    }

    [Fact]
    public async Task CancelAndWaitDoesNotFinishBeforeRepositoryCleanup()
    {
        var repository = new StubRepository { WaitForCleanup = true };
        using var model = Model(repository);
        _ = model.CalculateAsync();
        await repository.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));

        var closing = model.CancelAndWaitAsync();
        await repository.CancellationObserved.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.False(closing.IsCompleted);

        repository.CleanupFinished.TrySetResult();
        await closing;
        Assert.Equal(FileDirectorySizeState.Cancelled, model.State);
    }

    [Fact]
    public void UnsupportedAndInvalidTargetsNeverCalculate()
    {
        var repository = new StubRepository { IsAvailable = false };
        using var model = Model(repository);

        Assert.Equal(FileDirectorySizeState.Unsupported, model.State);
        Assert.False(model.CanCalculate);
        Assert.Throws<ArgumentException>(() => new FileDirectorySizeViewModel(
            repository,
            repository.ProfileId,
            Folder() with { IsDirectory = false }));
        Assert.Throws<ArgumentException>(() => new FileDirectorySizeViewModel(
            repository,
            Guid.NewGuid(),
            Folder()));
    }

    private static FileDirectorySizeViewModel Model(StubRepository repository) =>
        new(repository, repository.ProfileId, Folder());

    private static FileItem Folder() =>
        new("/home/docs", "docs", true, 0, DateTimeOffset.UnixEpoch, "owner", true, true);

    private sealed class StubRepository(DirectorySizeResult? result = null)
        : IDirectorySizeRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public bool IsAvailable { get; set; } = true;
        public DirectorySizeAvailability Availability => new(IsAvailable, IsAvailable ? 2 : null);
        public Exception? Error { get; set; }
        public List<string> Paths { get; } = [];
        public TaskCompletionSource Started { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool WaitForCleanup { get; set; }
        public TaskCompletionSource CancellationObserved { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource CleanupFinished { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<DirectorySizeResult> CalculateDirectorySizeAsync(
            string path,
            CancellationToken cancellationToken = default)
        {
            Paths.Add(path);
            Started.TrySetResult();
            if (Error is { } error)
            {
                throw error;
            }
            if (result is { } summary)
            {
                return summary;
            }
            try
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }
            catch (OperationCanceledException) when (WaitForCleanup)
            {
                CancellationObserved.TrySetResult();
                await CleanupFinished.Task;
                throw;
            }
            throw new InvalidOperationException();
        }
    }
}
