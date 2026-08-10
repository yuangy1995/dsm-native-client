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
    BtSearch,
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

/// <summary>
/// Download Station 任务文件创建请求。调用方拥有并负责关闭 Content。
/// </summary>
public sealed class DownloadTaskFileCreateRequest
{
    public const long MaximumLength = 100L * 1024 * 1024;

    public Guid ProfileId { get; }
    public Stream Content { get; }
    public long Length { get; }
    public string FileName { get; }
    public string? Destination { get; }

    public DownloadTaskFileCreateRequest(
        Guid profileId,
        Stream content,
        long length,
        string fileName,
        string? destination)
    {
        ArgumentNullException.ThrowIfNull(content);
        if (!content.CanRead)
        {
            throw new ArgumentException("download.create.file.stream_not_readable", nameof(content));
        }
        ArgumentOutOfRangeException.ThrowIfNegative(length);
        if (length > MaximumLength)
        {
            throw new ArgumentOutOfRangeException(nameof(length), "download.create.file.too_large");
        }
        if (!IsValidTaskFileName(fileName))
        {
            throw new ArgumentException("download.create.file.invalid_name", nameof(fileName));
        }
        var normalizedDestination = string.IsNullOrWhiteSpace(destination)
            ? null
            : destination.Trim();
        if (normalizedDestination is not null &&
            (normalizedDestination.Length == 0 || normalizedDestination.Any(char.IsControl)))
        {
            throw new ArgumentException("download.create.file.invalid_destination", nameof(destination));
        }

        ProfileId = profileId;
        Content = content;
        Length = length;
        FileName = fileName.Trim();
        Destination = normalizedDestination;
    }

    public override string ToString() => nameof(DownloadTaskFileCreateRequest);

    private static bool IsValidTaskFileName(string value)
    {
        var fileName = value.Trim();
        if (fileName.Length == 0 ||
            fileName is "." or ".." ||
            fileName.IndexOfAny(['/', '\\', '\r', '\n', '\0']) >= 0)
        {
            return false;
        }
        var extension = Path.GetExtension(fileName).ToLowerInvariant();
        return extension is ".torrent" or ".nzb" or ".txt";
    }
}

public sealed record DownloadTaskCreateOutcome(
    MutationResult Result,
    string? TaskId,
    DownloadTask? Task);

public sealed record DownloadBtSearchModule(
    string Id,
    string Title,
    bool IsEnabled);

public sealed record DownloadBtSearchCategory(
    string Id,
    string Title);

public sealed record DownloadBtSearchCatalog(
    IReadOnlyList<DownloadBtSearchModule> Modules,
    IReadOnlyList<DownloadBtSearchCategory> Categories);

public enum DownloadBtSearchModuleScope
{
    All,
    Enabled,
    Selected,
}

public enum DownloadBtSearchSort
{
    Title,
    Size,
    Date,
    Peers,
    Provider,
    Seeds,
    Leeches,
}

public enum DownloadBtSearchDirection
{
    Ascending,
    Descending,
}

public sealed record DownloadBtSearchRequest(
    Guid ProfileId,
    string Keyword,
    DownloadBtSearchModuleScope ModuleScope,
    IReadOnlySet<string> SelectedModuleIds,
    string? CategoryId,
    DownloadBtSearchSort Sort,
    DownloadBtSearchDirection Direction,
    string TitleFilter)
{
    public DownloadBtSearchRequest(
        Guid profileId,
        string keyword)
        : this(
            profileId,
            keyword,
            DownloadBtSearchModuleScope.Enabled,
            new HashSet<string>(StringComparer.Ordinal),
            null,
            DownloadBtSearchSort.Seeds,
            DownloadBtSearchDirection.Descending,
            string.Empty)
    {
    }
}

public sealed record DownloadBtSearchResult(
    string Title,
    long? Size,
    string? ListedAt,
    string DownloadUri,
    string? ExternalLink,
    int? Peers,
    int? Seeds,
    int? Leeches,
    string? Provider);

public enum DownloadTaskFileCreateTransportStatus
{
    Accepted,
    ConfirmedFailure,
    CancelledBeforeSubmission,
    CancellationRequestedAfterSubmission,
    SubmittedButUnverified,
    Unsupported,
}

public sealed record DownloadTaskFileCreateTransportResult(
    DownloadTaskFileCreateTransportStatus Status,
    string? TaskId = null,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

public sealed record DownloadTaskDeleteRequest(
    Guid ProfileId,
    DownloadTask Task);

public sealed record DownloadTaskDeleteOutcome(
    MutationResult Result,
    string TaskId);
