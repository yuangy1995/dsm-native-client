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
    long? TotalBytes)
{
    // 仅来自当前读取的控制身份；旧缓存不据此获得写权限。
    [System.Text.Json.Serialization.JsonIgnore] public decimal? CreationTimestamp { get; init; }
    [System.Text.Json.Serialization.JsonIgnore] public int? ApiVersion { get; init; }
    [System.Text.Json.Serialization.JsonIgnore] public string? Method { get; init; }
    public bool SameIdentity(FileBackgroundTaskSummary other) => Id == other.Id && Kind == other.Kind &&
        CreationTimestamp is not null && CreationTimestamp == other.CreationTimestamp && ApiVersion == other.ApiVersion && Method == other.Method;
}

public enum FileBackgroundTaskAction { Stop, Clear }
public sealed record FileBackgroundTaskChange(Guid RequestId, Guid ProfileId, FileBackgroundTaskSummary Task, FileBackgroundTaskAction Action, bool Confirmed);
public sealed record FileBackgroundTaskProgress(FileBackgroundTaskChange Change, MutationResult Outcome);

public sealed record FileBackgroundTaskPage(
    IReadOnlyList<FileBackgroundTaskSummary> Tasks,
    int Offset,
    int NextOffset,
    int Total,
    bool HasMore);
