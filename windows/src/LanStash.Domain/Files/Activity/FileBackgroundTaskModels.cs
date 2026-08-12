namespace LanStash.Domain;

public enum FileBackgroundTaskKind
{
    CopyOrMove,
    Delete,
    Extract,
    Compress,
}

public enum FileBackgroundTaskState
{
    Active,
    // finished 只表示任务不再活动，不代表任务成功。
    Finished,
}

public sealed record FileBackgroundTaskSummary(
    string Id,
    FileBackgroundTaskKind Kind,
    FileBackgroundTaskState State,
    double? Progress,
    DateTimeOffset? CreatedAt,
    int? ProcessedItemCount,
    int? TotalItemCount,
    long? ProcessedBytes,
    long? TotalBytes);

public sealed record FileBackgroundTaskPage(
    IReadOnlyList<FileBackgroundTaskSummary> Tasks,
    int Offset,
    int NextOffset,
    int Total,
    bool HasMore);
