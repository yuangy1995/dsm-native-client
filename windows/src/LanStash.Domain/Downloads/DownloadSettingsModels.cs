namespace LanStash.Domain;

/// <summary>完整管理员设置快照。计划读取独立降级，不把未知开关当成关闭。</summary>
public sealed record DownloadSettingsSnapshot(Guid ProfileId, DownloadStationSettingsSummary Value,
    bool CanEditDestination, DownloadStationSectionStatus ScheduleStatus);

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
    public bool CanContinue => !RequiresReview && Basic == DownloadSettingsComponentState.Confirmed && Schedule == DownloadSettingsComponentState.NotStarted;
}
