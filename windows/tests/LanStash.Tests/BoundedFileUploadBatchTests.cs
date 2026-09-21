using LanStash.App.Features.Transfers;

namespace LanStash.Tests;

public sealed class BoundedFileUploadBatchTests
{
    [Fact]
    public void ValidatePathsRejectsEmptyInvalidAndDuplicateTargets()
    {
        Assert.Equal(FileUploadBatchValidationStatus.Empty, BoundedFileUploadBatch.ValidatePaths([]));
        Assert.Equal(
            FileUploadBatchValidationStatus.InvalidPath,
            BoundedFileUploadBatch.ValidatePaths(["/source/one.txt", " "]));
        Assert.Equal(
            FileUploadBatchValidationStatus.DuplicateTarget,
            BoundedFileUploadBatch.ValidatePaths(["/first/same.txt", "/second/same.txt"]));
        Assert.Equal(
            FileUploadBatchValidationStatus.DuplicateTarget,
            BoundedFileUploadBatch.ValidatePaths(["/first/Case.txt", "/second/case.txt"]));
    }

    [Theory]
    [InlineData(21)]
    [InlineData(205)]
    [InlineData(1001)]
    public void ValidatePathsAcceptsLargeSelectionsAndNeverProducesTargetBusy(int count)
    {
        var status = BoundedFileUploadBatch.ValidatePaths(Paths(count));

        Assert.Equal(FileUploadBatchValidationStatus.Valid, status);
        Assert.NotEqual(FileUploadBatchValidationStatus.TargetBusy, status);
    }

    [Theory]
    [MemberData(nameof(InvalidBatches))]
    public async Task InvalidBatchExecutesNothing(IReadOnlyList<string> paths)
    {
        var executions = 0;

        await Assert.ThrowsAsync<ArgumentException>(() => BoundedFileUploadBatch.RunAsync(
            paths,
            (_, _) =>
            {
                executions++;
                return Task.FromResult(Confirmed());
            },
            CancellationToken.None));

        Assert.Equal(0, executions);
    }

    [Theory]
    [InlineData(21)]
    [InlineData(205)]
    [InlineData(1001)]
    public async Task RunsAllSelectedFilesStrictlyOneAtATime(int count)
    {
        var active = 0;
        var maximumActive = 0;

        var summary = await BoundedFileUploadBatch.RunAsync(
            Paths(count),
            async (_, _) =>
            {
                var current = Interlocked.Increment(ref active);
                UpdateMaximum(ref maximumActive, current);
                await Task.Yield();
                Interlocked.Decrement(ref active);
                return Confirmed();
            },
            CancellationToken.None);

        Assert.Equal(1, maximumActive);
        Assert.Equal(count, summary.ConfirmedCount);
        AssertConserved(summary);
    }

    [Fact]
    public async Task FailedAttemptDoesNotStopLaterFiles()
    {
        var executed = new List<string>();
        var paths = Paths(3);

        var summary = await BoundedFileUploadBatch.RunAsync(
            paths,
            (path, _) =>
            {
                executed.Add(path);
                return Task.FromResult(path == paths[1]
                    ? new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.Failed)
                    : Confirmed());
            },
            CancellationToken.None);

        Assert.Equal(paths, executed);
        Assert.Equal(2, summary.ConfirmedCount);
        Assert.Equal(1, summary.FailedCount);
        AssertConserved(summary);
    }

    [Fact]
    public async Task NeedsReviewIsNotReplayedAndDoesNotStopLaterFiles()
    {
        var calls = 0;

        var summary = await BoundedFileUploadBatch.RunAsync(
            Paths(3),
            (_, _) =>
            {
                calls++;
                return Task.FromResult(new FileUploadBatchAttempt(
                    calls == 1
                        ? FileUploadBatchAttemptStatus.NeedsReview
                        : FileUploadBatchAttemptStatus.Confirmed));
            },
            CancellationToken.None);

        Assert.Equal(3, calls);
        Assert.Equal(1, summary.NeedsReviewCount);
        Assert.Equal(2, summary.ConfirmedCount);
        AssertConserved(summary);
    }

    [Fact]
    public async Task NeedsReviewAfterCancellationStopsRemainingFilesWithoutReplay()
    {
        var calls = 0;

        var summary = await BoundedFileUploadBatch.RunAsync(
            Paths(3),
            (_, _) =>
            {
                calls++;
                return Task.FromResult(new FileUploadBatchAttempt(
                    FileUploadBatchAttemptStatus.NeedsReview,
                    StopBatch: true));
            },
            CancellationToken.None);

        Assert.Equal(1, calls);
        Assert.Equal(1, summary.NeedsReviewCount);
        Assert.Equal(2, summary.NotStartedCount);
        AssertConserved(summary);
    }

    [Fact]
    public async Task CancelledAttemptStopsRemainingFiles()
    {
        var calls = 0;

        var summary = await BoundedFileUploadBatch.RunAsync(
            Paths(4),
            (_, _) => Task.FromResult(new FileUploadBatchAttempt(
                ++calls == 2
                    ? FileUploadBatchAttemptStatus.Cancelled
                    : FileUploadBatchAttemptStatus.Confirmed)),
            CancellationToken.None);

        Assert.Equal(2, calls);
        Assert.Equal(1, summary.ConfirmedCount);
        Assert.Equal(1, summary.CancelledCount);
        Assert.Equal(2, summary.NotStartedCount);
        AssertConserved(summary);
    }

    [Fact]
    public async Task CancellationTokenStopsLaunchingRemainingFiles()
    {
        using var cancellation = new CancellationTokenSource();
        var calls = 0;

        var summary = await BoundedFileUploadBatch.RunAsync(
            Paths(3),
            (_, _) =>
            {
                calls++;
                cancellation.Cancel();
                return Task.FromResult(Confirmed());
            },
            cancellation.Token);

        Assert.Equal(1, calls);
        Assert.Equal(1, summary.ConfirmedCount);
        Assert.Equal(2, summary.NotStartedCount);
        AssertConserved(summary);
    }

    [Fact]
    public async Task NonCancellationExceptionCountsAsFailureAndContinues()
    {
        var calls = 0;

        var summary = await BoundedFileUploadBatch.RunAsync(
            Paths(3),
            (_, _) =>
            {
                calls++;
                return calls == 2
                    ? Task.FromException<FileUploadBatchAttempt>(new InvalidOperationException("synthetic"))
                    : Task.FromResult(Confirmed());
            },
            CancellationToken.None);

        Assert.Equal(3, calls);
        Assert.Equal(2, summary.ConfirmedCount);
        Assert.Equal(1, summary.FailedCount);
        AssertConserved(summary);
    }

    [Fact]
    public async Task CallerChangesCannotReplaceOrDropQueuedPaths()
    {
        var paths = Paths(205).ToList(); var original = paths.ToArray(); var executed = new List<string>();
        var result = await BoundedFileUploadBatch.RunAsync(paths, (path, _) =>
        {
            executed.Add(path);
            if (executed.Count == 1) { paths.Clear(); paths.Add("/source/replacement.txt"); }
            return Task.FromResult(Confirmed());
        }, CancellationToken.None);
        Assert.Equal(original, executed); Assert.Equal(205, result.SelectedCount); Assert.Equal(205, result.ConfirmedCount); AssertConserved(result);
    }

    [Fact]
    public async Task LargeBatchCancellationAfterTwentyItemsStillAccountsForEveryItem()
    {
        var calls = 0;
        var result = await BoundedFileUploadBatch.RunAsync(Paths(1001), (_, _) => Task.FromResult(++calls == 23
            ? new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.NeedsReview, StopBatch: true) : Confirmed()), CancellationToken.None);
        Assert.Equal(23, calls); Assert.Equal(22, result.ConfirmedCount); Assert.Equal(1, result.NeedsReviewCount);
        Assert.Equal(978, result.NotStartedCount); AssertConserved(result);
    }

    public static TheoryData<IReadOnlyList<string>> InvalidBatches => new()
    {
        Array.Empty<string>(),
        new[] { "C:\\source\\" },
        new[] { "/source/one.txt", string.Empty },
        new[] { "/first/same.txt", "/second/same.txt" },
    };

    private static string[] Paths(int count) =>
        Enumerable.Range(1, count).Select(index => $"/source/file-{index}.txt").ToArray();

    private static FileUploadBatchAttempt Confirmed() =>
        new(FileUploadBatchAttemptStatus.Confirmed);

    private static void AssertConserved(FileUploadBatchSummary summary) =>
        Assert.Equal(
            summary.SelectedCount,
            summary.ConfirmedCount + summary.NeedsReviewCount + summary.FailedCount +
            summary.CancelledCount + summary.NotStartedCount);

    private static void UpdateMaximum(ref int maximum, int current)
    {
        var observed = Volatile.Read(ref maximum);
        while (current > observed)
        {
            var previous = Interlocked.CompareExchange(ref maximum, current, observed);
            if (previous == observed)
            {
                return;
            }

            observed = previous;
        }
    }
}
