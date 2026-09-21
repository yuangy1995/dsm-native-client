namespace LanStash.App.Features.Transfers;

internal enum FileUploadBatchAttemptStatus
{
    Confirmed,
    NeedsReview,
    Failed,
    Cancelled,
}

internal sealed record FileUploadBatchAttempt(
    FileUploadBatchAttemptStatus Status,
    bool StopBatch = false);

internal sealed record FileUploadBatchSummary(
    int SelectedCount,
    int ConfirmedCount,
    int NeedsReviewCount,
    int FailedCount,
    int CancelledCount,
    int NotStartedCount);

internal enum FileUploadBatchValidationStatus
{
    Valid,
    Empty,
    TooMany, // 保留既有枚举值，不再由数量检查产生。
    InvalidPath,
    DuplicateTarget,
    TargetBusy,
}

internal static class BoundedFileUploadBatch
{
    internal static FileUploadBatchValidationStatus ValidatePaths(IReadOnlyList<string> paths)
    {
        ArgumentNullException.ThrowIfNull(paths);

        if (paths.Count == 0)
        {
            return FileUploadBatchValidationStatus.Empty;
        }

        var targetNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in paths)
        {
            if (string.IsNullOrWhiteSpace(path))
            {
                return FileUploadBatchValidationStatus.InvalidPath;
            }

            string targetName;
            try
            {
                targetName = Path.GetFileName(path);
            }
            catch (Exception exception) when (exception is ArgumentException or NotSupportedException)
            {
                return FileUploadBatchValidationStatus.InvalidPath;
            }

            if (string.IsNullOrEmpty(targetName))
            {
                return FileUploadBatchValidationStatus.InvalidPath;
            }

            if (!targetNames.Add(targetName))
            {
                return FileUploadBatchValidationStatus.DuplicateTarget;
            }
        }

        return FileUploadBatchValidationStatus.Valid;
    }

    internal static async Task<FileUploadBatchSummary> RunAsync(
        IReadOnlyList<string> paths,
        Func<string, CancellationToken, Task<FileUploadBatchAttempt>> attempt,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(attempt);
        ArgumentNullException.ThrowIfNull(paths);
        var snapshot = paths.ToArray();

        if (ValidatePaths(snapshot) != FileUploadBatchValidationStatus.Valid)
        {
            throw new ArgumentException("upload.batch_invalid", nameof(paths));
        }

        var confirmed = 0;
        var needsReview = 0;
        var failed = 0;
        var cancelled = 0;
        var started = 0;

        foreach (var path in snapshot)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                break;
            }

            started++;
            FileUploadBatchAttempt result;
            try
            {
                result = await attempt(path, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                cancelled++;
                break;
            }
            catch (Exception)
            {
                failed++;
                continue;
            }

            switch (result.Status)
            {
                case FileUploadBatchAttemptStatus.Confirmed:
                    confirmed++;
                    break;
                case FileUploadBatchAttemptStatus.NeedsReview:
                    needsReview++;
                    break;
                case FileUploadBatchAttemptStatus.Failed:
                    failed++;
                    break;
                case FileUploadBatchAttemptStatus.Cancelled:
                    cancelled++;
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(result.Status));
            }

            if (result.StopBatch ||
                result.Status == FileUploadBatchAttemptStatus.Cancelled ||
                cancellationToken.IsCancellationRequested)
            {
                break;
            }
        }

        return new FileUploadBatchSummary(
            snapshot.Length,
            confirmed,
            needsReview,
            failed,
            cancelled,
            snapshot.Length - started);
    }
}
