using System.Globalization;
using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

public enum DownloadStationContentState
{
    Loading,
    Empty,
    FilteredEmpty,
    Error,
    Content,
    Unavailable,
}

public enum DownloadTaskFilter
{
    All,
    Active,
    Finished,
    Paused,
}

public enum DownloadTaskControlNoticeKind
{
    None,
    InProgress,
    Success,
    NeedsReview,
    Cancelled,
    Conflict,
    Permission,
    Unsupported,
    Failure,
}

public sealed record DownloadTaskItem(DownloadTask Task)
{
    public string Id => Task.Id;
    public string Title => Task.Title;
    public DownloadTaskState State => Task.State;
    public double ProgressPercent => (Task.Progress ?? 0) * 100;
    public bool IsProgressUnknown => Task.Progress is null;
    public string StatusText => LocalizationService.Current.Get(Task.State switch
    {
        DownloadTaskState.Waiting => "DownloadStationStatusWaiting",
        DownloadTaskState.Downloading => "DownloadStationStatusDownloading",
        DownloadTaskState.Paused => "DownloadStationStatusPaused",
        DownloadTaskState.Finished => "DownloadStationStatusFinished",
        DownloadTaskState.Checking => "DownloadStationStatusChecking",
        DownloadTaskState.Seeding => "DownloadStationStatusSeeding",
        DownloadTaskState.Error => "DownloadStationStatusError",
        _ => "DownloadStationStatusUnknown",
    });
    public string ProgressText => Task.Progress is { } progress
        ? LocalizationService.Current.Format(
            "DownloadStationProgressValue",
            progress.ToString("P0", CultureInfo.CurrentCulture))
        : LocalizationService.Current.Get("DownloadStationValueUnavailable");
    public string SizeText => FormatBytes(Task.Size);
    public string DownloadedText => FormatBytes(Task.Downloaded);
    public string UploadedText => FormatBytes(Task.Uploaded);
    public string DownloadSpeedText => FormatSpeed(Task.DownloadSpeed);
    public string UploadSpeedText => FormatSpeed(Task.UploadSpeed);
    public string PriorityText => Task.AdvancedDetails.Priority switch
    {
        DownloadTaskPriority.Low => LocalizationService.Current.Get("DownloadStationPriorityLow"),
        DownloadTaskPriority.Normal => LocalizationService.Current.Get("DownloadStationPriorityNormal"),
        DownloadTaskPriority.High => LocalizationService.Current.Get("DownloadStationPriorityHigh"),
        DownloadTaskPriority.Unknown => LocalizationService.Current.Get("DownloadStationPriorityUnknown"),
        _ => LocalizationService.Current.Get("DownloadStationValueUnavailable"),
    };
    public string FileCountText => FormatCount(
        Task.AdvancedDetails.FileCount,
        "DownloadStationAdvancedFileCount");
    public string TrackerCountText => FormatCount(
        Task.AdvancedDetails.TrackerCount,
        "DownloadStationAdvancedTrackerCount");
    public string PeerCountText => Task.AdvancedDetails.PeerCount is int connectedPeers
        ? LocalizationService.Current.Format(
            "DownloadStationAdvancedConnectedPeerCount",
            connectedPeers.ToString("N0", CultureInfo.CurrentCulture))
        : FormatCount(Task.AdvancedDetails.Peers, "DownloadStationAdvancedPeerCount");
    public string SeedsText => FormatCount(
        Task.AdvancedDetails.Seeds,
        "DownloadStationAdvancedSeedCount");
    public string LeechesText => FormatCount(
        Task.AdvancedDetails.Leeches,
        "DownloadStationAdvancedLeechCount");
    public string DestinationText => string.IsNullOrWhiteSpace(Task.Destination)
        ? LocalizationService.Current.Get("DownloadStationValueUnavailable")
        : Task.Destination;
    public string ErrorText => Task.State == DownloadTaskState.Error ||
        !string.IsNullOrWhiteSpace(Task.Error)
            ? LocalizationService.Current.Get("DownloadStationTaskNeedsAttention")
            : LocalizationService.Current.Get("DownloadStationNoTaskError");
    public string AutomationName => LocalizationService.Current.Format(
        "DownloadStationTaskAutomationName",
        Title,
        StatusText,
        ProgressText);

    internal static string FormatSpeed(long? bytesPerSecond) => bytesPerSecond is null
        ? LocalizationService.Current.Get("DownloadStationValueUnavailable")
        : LocalizationService.Current.Format(
            "DownloadStationSpeedValue",
            FormatBytes(bytesPerSecond));

    internal static string FormatBytes(long? bytes)
    {
        if (bytes is null)
        {
            return LocalizationService.Current.Get("DownloadStationValueUnavailable");
        }
        string[] unitKeys =
        [
            "DownloadStationByteValueB",
            "DownloadStationByteValueKB",
            "DownloadStationByteValueMB",
            "DownloadStationByteValueGB",
            "DownloadStationByteValueTB",
        ];
        var value = Math.Max(0, bytes.Value);
        var scaled = (double)value;
        var unit = 0;
        while (scaled >= 1024 && unit < unitKeys.Length - 1)
        {
            scaled /= 1024;
            unit++;
        }
        var format = unit == 0 ? "N0" : scaled >= 10 ? "N1" : "N2";
        return LocalizationService.Current.Format(
            unitKeys[unit],
            scaled.ToString(format, CultureInfo.CurrentCulture));
    }

    private static string FormatCount(int? count, string resourceKey) => count is null
        ? LocalizationService.Current.Get("DownloadStationValueUnavailable")
        : LocalizationService.Current.Format(
            resourceKey,
            count.Value.ToString("N0", CultureInfo.CurrentCulture));
}
