namespace LanStash.Domain;

public enum DownloadStationAvailabilityStatus
{
    Unavailable,
    Available,
}

public enum DownloadStationReadFeature
{
    Tasks,
    ActivitySummary,
    DefaultDestination,
}

public sealed record DownloadStationAvailability(
    DownloadStationAvailabilityStatus Status,
    IReadOnlySet<DownloadStationReadFeature> SupportedFeatures);

public enum DownloadTaskState
{
    Unknown,
    Waiting,
    Downloading,
    Paused,
    Finished,
    Checking,
    Seeding,
    Error,
}

public enum DownloadTaskControlAction
{
    Pause,
    Resume,
}

public sealed record DownloadTask(
    string Id,
    string Title,
    string RawStatus,
    DownloadTaskState State,
    long? Size,
    long? Downloaded,
    long? Uploaded,
    long? DownloadSpeed,
    long? UploadSpeed,
    string? Destination,
    string? Error)
{
    // 旧 Workspace 仍读取 Status；新 Download Station 功能使用 State 与 RawStatus。
    public string Status => RawStatus;

    public DownloadTask(
        string id,
        string title,
        string status,
        long? size,
        long? downloaded,
        long? downloadSpeed,
        long? uploadSpeed,
        string? destination,
        string? error)
        : this(
            id,
            title,
            status,
            ParseState(status),
            size,
            downloaded,
            null,
            downloadSpeed,
            uploadSpeed,
            destination,
            error)
    {
    }

    public double? Progress =>
        Size is > 0 && Downloaded is not null
            ? Math.Clamp((double)Downloaded.Value / Size.Value, 0, 1)
            : null;

    private static DownloadTaskState ParseState(string status) =>
        status.Trim().ToLowerInvariant() switch
        {
            "waiting" => DownloadTaskState.Waiting,
            "downloading" => DownloadTaskState.Downloading,
            "paused" => DownloadTaskState.Paused,
            "finished" => DownloadTaskState.Finished,
            "hash_checking" or "filehosting_waiting" or "extracting" =>
                DownloadTaskState.Checking,
            "seeding" => DownloadTaskState.Seeding,
            "error" => DownloadTaskState.Error,
            _ => DownloadTaskState.Unknown,
        };
}

public sealed record DownloadTaskPage(
    IReadOnlyList<DownloadTask> Tasks,
    int SourceOffset,
    int SourceRecordCount,
    int SourceTotal,
    int? NextOffset,
    bool HasMore);

public enum DownloadStationSectionStatus
{
    Unavailable,
    Available,
    Failed,
}

public sealed record DownloadActivitySummary(
    long DownloadSpeed,
    long UploadSpeed,
    long EmuleDownloadSpeed,
    long EmuleUploadSpeed);

public sealed record DownloadActivitySection(
    DownloadStationSectionStatus Status,
    DownloadActivitySummary? Value);

public sealed record DownloadDefaultDestinationSection(
    DownloadStationSectionStatus Status,
    string? Value);

public sealed record DownloadStationSnapshot(
    Guid ProfileId,
    DownloadTaskPage Tasks,
    DownloadActivitySection Activity,
    DownloadDefaultDestinationSection DefaultDestination);

public sealed record DownloadTaskControlRequest(
    Guid ProfileId,
    DownloadTask Task,
    DownloadTaskControlAction Action);

public sealed record DownloadTaskControlOutcome(
    MutationResult Result,
    string TaskId,
    DownloadTask? Task);

public sealed record DownloadTaskCreateRequest(
    Guid ProfileId,
    string Uri,
    string? Destination);

public sealed record DownloadTaskCreateOutcome(
    MutationResult Result,
    string? TaskId,
    DownloadTask? Task);

public sealed record DownloadTaskDeleteRequest(
    Guid ProfileId,
    DownloadTask Task);

public sealed record DownloadTaskDeleteOutcome(
    MutationResult Result,
    string TaskId);
