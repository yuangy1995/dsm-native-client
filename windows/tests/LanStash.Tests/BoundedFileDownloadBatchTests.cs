using LanStash.App.Features.Transfers;

namespace LanStash.Tests;

public sealed class BoundedFileDownloadBatchTests
{
    [Fact]
    public void ValidatesBoundsNamesAndCaseInsensitiveTargets()
    {
        Assert.Equal(FileDownloadBatchValidationStatus.Empty, BoundedFileDownloadBatch.Validate([]));
        Assert.Equal(
            FileDownloadBatchValidationStatus.Valid,
            BoundedFileDownloadBatch.Validate(Items(20)));
        Assert.Equal(
            FileDownloadBatchValidationStatus.TooMany,
            BoundedFileDownloadBatch.Validate(Items(21)));
        Assert.Equal(
            FileDownloadBatchValidationStatus.InvalidItem,
            BoundedFileDownloadBatch.Validate([new("/a", "bad:name.txt", 1)]));
        Assert.Equal(
            FileDownloadBatchValidationStatus.InvalidItem,
            BoundedFileDownloadBatch.Validate([new("/a", "CON.txt", 1)]));
        Assert.Equal(
            FileDownloadBatchValidationStatus.InvalidItem,
            BoundedFileDownloadBatch.Validate([new("/a", "file.txt.", 1)]));
        Assert.Equal(
            FileDownloadBatchValidationStatus.DuplicateTarget,
            BoundedFileDownloadBatch.Validate([
                new("/a", "Same.txt", 1),
                new("/b", "same.TXT", 1),
            ]));
        Assert.Equal(
            FileDownloadBatchValidationStatus.InvalidItem,
            BoundedFileDownloadBatch.Validate([
                new("/same", "a.txt", 1),
                new("/same", "b.txt", 1),
            ]));
    }

    [Fact]
    public async Task RunsStrictlySequentiallyAndContinuesAfterFailure()
    {
        var active = 0;
        var maximumActive = 0;
        var calls = new List<string>();
        var items = Items(3);

        var summary = await BoundedFileDownloadBatch.RunAsync(
            items,
            async (item, _) =>
            {
                active++;
                maximumActive = Math.Max(maximumActive, active);
                calls.Add(item.Name);
                await Task.Yield();
                active--;
                return new FileDownloadBatchAttempt(
                    item.Name == "file-01.bin"
                        ? FileDownloadBatchAttemptStatus.Failed
                        : FileDownloadBatchAttemptStatus.Completed);
            },
            CancellationToken.None);

        Assert.Equal(1, maximumActive);
        Assert.Equal(items.Select(item => item.Name), calls);
        Assert.Equal(2, summary.CompletedCount);
        Assert.Equal(1, summary.FailedCount);
        Assert.Equal(0, summary.NotStartedCount);
    }

    [Fact]
    public async Task CancellationStopsRemainingItemsAndPreservesSummaryInvariant()
    {
        var calls = 0;
        var items = Items(4);

        var summary = await BoundedFileDownloadBatch.RunAsync(
            items,
            (_, _) => Task.FromResult(new FileDownloadBatchAttempt(
                ++calls == 2
                    ? FileDownloadBatchAttemptStatus.Cancelled
                    : FileDownloadBatchAttemptStatus.Completed)),
            CancellationToken.None);

        Assert.Equal(2, calls);
        Assert.Equal(1, summary.CompletedCount);
        Assert.Equal(1, summary.CancelledCount);
        Assert.Equal(2, summary.NotStartedCount);
        Assert.Equal(
            summary.SelectedCount,
            summary.CompletedCount + summary.FailedCount +
                summary.CancelledCount + summary.NotStartedCount);
    }

    [Fact]
    public async Task AlreadyCancelledBatchStartsNothing()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var summary = await BoundedFileDownloadBatch.RunAsync(
            Items(2),
            (_, _) => throw new InvalidOperationException(),
            cancellation.Token);

        Assert.Equal(2, summary.NotStartedCount);
    }

    [Fact]
    public async Task LateCancellationCanKeepCommittedItemAndStopRemainder()
    {
        var calls = 0;
        var summary = await BoundedFileDownloadBatch.RunAsync(
            Items(3),
            (_, _) => Task.FromResult(new FileDownloadBatchAttempt(
                FileDownloadBatchAttemptStatus.Completed,
                StopBatch: ++calls == 1)),
            CancellationToken.None);

        Assert.Equal(1, calls);
        Assert.Equal(1, summary.CompletedCount);
        Assert.Equal(2, summary.NotStartedCount);
    }

    [Fact]
    public async Task FailedCommitCanPreserveCancellationIntentAndStopRemainder()
    {
        var calls = 0;
        var summary = await BoundedFileDownloadBatch.RunAsync(
            Items(3),
            (_, _) => Task.FromResult(new FileDownloadBatchAttempt(
                FileDownloadBatchAttemptStatus.Failed,
                StopBatch: ++calls == 1)),
            CancellationToken.None);

        Assert.Equal(1, calls);
        Assert.Equal(1, summary.FailedCount);
        Assert.Equal(2, summary.NotStartedCount);
    }

    private static FileDownloadBatchItem[] Items(int count) =>
        Enumerable.Range(0, count)
            .Select(index => new FileDownloadBatchItem(
                $"/share/file-{index:D2}.bin",
                $"file-{index:D2}.bin",
                index))
            .ToArray();
}
