using LanStash.Domain;

namespace LanStash.App.Features.Transfers;

internal sealed partial class WindowsTransferPickerService
{
    private async Task<FileUploadBatchSummary> RunUploadBatchActivityAsync(Guid id, string profile,
        string folder, string name, long totalBytes, ForegroundTransferItemResult[] items,
        Func<ForegroundTransferControl, Func<int, Func<Task<FileUploadBatchAttempt>>, Task<FileUploadBatchAttempt>>,
            Action<int, long>, CancellationToken, Task<FileUploadBatchSummary>> run, CancellationToken token)
    {
        await Task.Yield();
        var control = new ForegroundTransferControl();
        var bytes = new long[items.Length];
        FileUploadBatchSummary? summary = null;
        try
        {
            await _coordinator.RunUploadAsync(new(profile, folder, name, totalBytes, id), async (progress, cancellation) =>
            {
                void Publish() => _coordinator.UpdateDownloadPlan(profile, id, totalBytes, items);
                async Task<FileUploadBatchAttempt> Track(int index, Func<Task<FileUploadBatchAttempt>> operation)
                {
                    FileUploadBatchAttempt result;
                    try
                    {
                        await control.WaitAsync(cancellation);
                        items[index] = items[index] with { State = ForegroundTransferItemState.Running }; Publish();
                        result = await operation();
                    }
                    catch (OperationCanceledException) { result = new(FileUploadBatchAttemptStatus.Cancelled, true); }
                    catch { result = new(FileUploadBatchAttemptStatus.Failed); }
                    items[index] = items[index] with { State = result.Status switch
                    {
                        FileUploadBatchAttemptStatus.Confirmed => ForegroundTransferItemState.Completed,
                        FileUploadBatchAttemptStatus.NeedsReview => ForegroundTransferItemState.ResultNeedsReview,
                        FileUploadBatchAttemptStatus.Cancelled => ForegroundTransferItemState.Cancelled,
                        _ => ForegroundTransferItemState.Failed,
                    } };
                    Publish(); return result;
                }
                Publish();
                summary = await run(control, Track, (index, value) =>
                {
                    bytes[index] = Math.Max(bytes[index], value);
                    progress.Report(Math.Min(totalBytes, bytes.Sum()));
                }, cancellation);
                return new MutationResult(1, summary.NeedsReviewCount > 0 ? MutationResultStatus.SubmittedButUnverified :
                    summary.ConfirmedCount == summary.SelectedCount ? MutationResultStatus.ConfirmedSuccess :
                    summary.ConfirmedCount > 0 && summary.FailedCount > 0 ? MutationResultStatus.PartialSuccess :
                    summary.ConfirmedCount > 0 || summary.FailedCount > 0 ? MutationResultStatus.ConfirmedFailure :
                    summary.CancelledCount > 0 || summary.NotStartedCount > 0 ? MutationResultStatus.CancelledBeforeSubmission : MutationResultStatus.ConfirmedFailure,
                    "uploadBatch", summary.ConfirmedCount + summary.NeedsReviewCount > 0, summary.NeedsReviewCount > 0,
                    new(summary.ConfirmedCount, summary.FailedCount, summary.NeedsReviewCount));
            }, token, control);
        }
        catch { /* 各项目保留已有事实，退出和连接切换由原有生命周期统一处理。 */ }
        return summary ?? new(items.Length, items.Count(item => item.State == ForegroundTransferItemState.Completed),
            items.Count(item => item.State == ForegroundTransferItemState.ResultNeedsReview),
            items.Count(item => item.State == ForegroundTransferItemState.Failed),
            items.Count(item => item.State == ForegroundTransferItemState.Cancelled),
            items.Count(item => item.State is ForegroundTransferItemState.Waiting or ForegroundTransferItemState.Running));
    }

    private sealed class UploadProgress(Action<long> report) : IProgress<long>
    {
        public void Report(long value) => report(value);
    }
}
