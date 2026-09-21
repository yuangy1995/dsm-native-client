namespace LanStash.Domain;

public enum DownloadStationAvailabilityStatus
{
    Unavailable,
    Available,
}

public enum DownloadStationReadFeature
{
    Tasks,
    TaskAdvancedDetails,
    ActivitySummary,
    DefaultDestination,
    ServerSettings,
    RssSummary,
    BtSearch,
}

public sealed record DownloadStationAvailability(
    DownloadStationAvailabilityStatus Status,
    IReadOnlySet<DownloadStationReadFeature> SupportedFeatures)
{
    public bool SupportsCreateDestination { get; init; }
}

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

public enum DownloadTaskPriority
{
    Low,
    Normal,
    High,
    Unknown,
}

public sealed record DownloadTaskAdvancedDetails(
    DownloadTaskPriority? Priority,
    int? FileCount,
    int? TrackerCount,
    int? PeerCount,
    int? Seeds,
    int? Peers,
    int? Leeches)
{
    public static DownloadTaskAdvancedDetails Empty { get; } = new(
        null,
        null,
        null,
        null,
        null,
        null,
        null);
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

    public DownloadTaskAdvancedDetails AdvancedDetails { get; init; } =
        DownloadTaskAdvancedDetails.Empty;

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
            "checking" or "hash_checking" or "filehosting_waiting" or "extracting" =>
                DownloadTaskState.Checking,
            "seeding" or "uploading" => DownloadTaskState.Seeding,
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

public sealed record DownloadStationSettingsSummary(
    string? DefaultDestination,
    bool? IsEmuleEnabled,
    bool? IsAutoExtractEnabled,
    int? BtDownloadLimitKb,
    int? BtUploadLimitKb,
    int? HttpDownloadLimitKb,
    int? FtpDownloadLimitKb,
    int? NzbDownloadLimitKb,
    int? EmuleDownloadLimitKb,
    int? EmuleUploadLimitKb,
    bool? IsScheduleEnabled,
    bool? IsEmuleScheduleEnabled);

public sealed record DownloadStationSettingsSection(
    DownloadStationSectionStatus Status,
    DownloadStationSettingsSummary? Value);

public sealed record DownloadRssSummary(
    int SiteCount,
    int FeedCount);

public sealed record DownloadRssSection(
    DownloadStationSectionStatus Status,
    DownloadRssSummary? Value);

public sealed record DownloadStationSnapshot(
    Guid ProfileId,
    DownloadTaskPage Tasks,
    DownloadActivitySection Activity,
    DownloadDefaultDestinationSection DefaultDestination)
{
    public DownloadStationSettingsSection Settings { get; init; } =
        new(DownloadStationSectionStatus.Unavailable, null);

    public DownloadRssSection Rss { get; init; } =
        new(DownloadStationSectionStatus.Unavailable, null);
}

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
    public string? UnzipPassword { get; }

    public DownloadTaskFileCreateRequest(
        Guid profileId,
        Stream content,
        long length,
        string fileName,
        string? destination,
        string? unzipPassword = null)
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
        if (unzipPassword?.Contains('\0') == true) throw new ArgumentException("download.create.file.invalid_password", nameof(unzipPassword));
        UnzipPassword = string.IsNullOrEmpty(unzipPassword) ? null : unzipPassword;
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
    DownloadTask Task)
{
    /// <summary>结束任务并移出未完成文件；不是删除数据，调用方必须单独确认。</summary>
    public bool ForceComplete { get; init; }
}

public sealed record DownloadTaskDeleteOutcome(
    MutationResult Result,
    string TaskId);
