namespace LanStash.Domain;

/// <summary>字段按实际存在性提供。计划读取独立降级，管理权限未知时只读。</summary>
public sealed record DownloadSettingsSnapshot(Guid ProfileId, DownloadStationSettingsSummary Value,
    bool CanEditDestination, DownloadStationSectionStatus ScheduleStatus)
{
    public bool? IsManager { get; init; }
}

public sealed record DownloadSettingsSaveRequest(Guid ProfileId, DownloadSettingsSnapshot Expected,
    DownloadStationSettingsSummary Desired, Guid ClientRequestId)
{
    /// <summary>仅用于明确确认后继续未开始组件；结果核对不发送新的写入。</summary>
    public bool ContinueRemaining { get; init; }
}

public enum DownloadSettingsComponentState { Unchanged, NotStarted, Unknown, Confirmed, Rejected }

public sealed record DownloadSettingsSaveOutcome(MutationResult Result, DownloadSettingsSnapshot? Confirmed,
    DownloadSettingsComponentState Basic, DownloadSettingsComponentState Schedule)
{
    public bool RequiresReview => Basic == DownloadSettingsComponentState.Unknown || Schedule == DownloadSettingsComponentState.Unknown;
    public Guid? ActionId { get; init; }
    public bool CanContinue => !RequiresReview && (Basic == DownloadSettingsComponentState.NotStarted || Schedule == DownloadSettingsComponentState.NotStarted);
}
