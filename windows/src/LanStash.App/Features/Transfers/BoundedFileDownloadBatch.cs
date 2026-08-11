namespace LanStash.App.Features.Transfers;

internal enum FileDownloadBatchValidationStatus
{
    Valid,
    Empty,
    TooMany,
    InvalidItem,
    DuplicateTarget,
    TargetExists,
    TargetBusy,
}

internal enum FileDownloadBatchAttemptStatus
{
    Completed,
    Cancelled,
    Failed,
}

internal sealed record FileDownloadBatchItem(
    string RemotePath,
    string Name,
    long Length);

internal sealed record FileDownloadBatchAttempt(
    FileDownloadBatchAttemptStatus Status,
    bool StopBatch = false);

internal sealed record FileDownloadBatchSummary(
    int SelectedCount,
    int CompletedCount,
    int FailedCount,
    int CancelledCount,
    int NotStartedCount);

internal static class BoundedFileDownloadBatch
{
    internal const int MaximumFileCount = 20;

    internal static FileDownloadBatchValidationStatus Validate(
        IReadOnlyList<FileDownloadBatchItem> items)
    {
        ArgumentNullException.ThrowIfNull(items);
        if (items.Count == 0)
        {
            return FileDownloadBatchValidationStatus.Empty;
        }
        if (items.Count > MaximumFileCount)
        {
            return FileDownloadBatchValidationStatus.TooMany;
        }

        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var paths = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in items)
        {
            if (string.IsNullOrWhiteSpace(item.RemotePath) ||
                item.Length < 0 ||
                !IsValidLocalName(item.Name) ||
                !paths.Add(item.RemotePath))
            {
                return FileDownloadBatchValidationStatus.InvalidItem;
            }
            if (!names.Add(item.Name))
            {
                return FileDownloadBatchValidationStatus.DuplicateTarget;
            }
        }
        return FileDownloadBatchValidationStatus.Valid;
    }

    internal static async Task<FileDownloadBatchSummary> RunAsync(
        IReadOnlyList<FileDownloadBatchItem> items,
        Func<FileDownloadBatchItem, CancellationToken, Task<FileDownloadBatchAttempt>> download,
        CancellationToken cancellationToken)
    {
        if (Validate(items) != FileDownloadBatchValidationStatus.Valid)
        {
            throw new ArgumentException("The download batch is invalid.", nameof(items));
        }
        ArgumentNullException.ThrowIfNull(download);

        var completed = 0;
        var failed = 0;
        var cancelled = 0;
        var started = 0;
        foreach (var item in items)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            started++;
            FileDownloadBatchAttempt attempt;
            try
            {
                attempt = await download(item, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                attempt = new FileDownloadBatchAttempt(
                    FileDownloadBatchAttemptStatus.Cancelled,
                    StopBatch: true);
            }
            catch
            {
                attempt = new FileDownloadBatchAttempt(FileDownloadBatchAttemptStatus.Failed);
            }
            switch (attempt.Status)
            {
                case FileDownloadBatchAttemptStatus.Completed:
                    completed++;
                    break;
                case FileDownloadBatchAttemptStatus.Cancelled:
                    cancelled++;
                    break;
                case FileDownloadBatchAttemptStatus.Failed:
                    failed++;
                    break;
            }
            if (attempt.Status == FileDownloadBatchAttemptStatus.Cancelled || attempt.StopBatch)
            {
                break;
            }
        }
        return new FileDownloadBatchSummary(
            items.Count,
            completed,
            failed,
            cancelled,
            items.Count - started);
    }

    internal static bool IsValidLocalName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) ||
            !string.Equals(name, name.Trim(), StringComparison.Ordinal) ||
            name is "." or ".." ||
            name.EndsWith(".", StringComparison.Ordinal) ||
            name.Any(character => character < ' ') ||
            name.IndexOfAny(['<', '>', ':', '"', '/', '\\', '|', '?', '*', '\r', '\n', '\0']) >= 0)
        {
            return false;
        }

        var stem = name.Split('.')[0];
        return stem.Length == 0 || !ReservedDeviceNames.Contains(stem);
    }

    private static readonly HashSet<string> ReservedDeviceNames = new(
        ["CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5",
         "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4",
         "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"],
        StringComparer.OrdinalIgnoreCase);
}
