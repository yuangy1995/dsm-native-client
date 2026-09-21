namespace LanStash.Domain;

// 创建的 BaselineDetail 来自 get(-1, type=script)，编辑同时携带列表和详情快照。
public sealed record NasTaskSaveRequest(Guid ProfileId, NasTaskEntry? BaselineTask, NasTaskDetail BaselineDetail,
    NasTaskDetail Desired, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(NasTaskSaveRequest);
}
public sealed record NasTaskSaveRecoveryInfo(Guid RequestId, int? Id, string Name, string? RealOwner)
{
    public override string ToString() => nameof(NasTaskSaveRecoveryInfo);
}

public static class NasTaskSaveRules
{
    public static bool IsValid(NasTaskSaveRequest request)
    {
        var baseline = request.BaselineDetail; var desired = request.Desired;
        if (baseline is null || desired is null || desired.Id != baseline.Id || desired.RequestedRealOwner != baseline.RequestedRealOwner || desired.RealOwner != baseline.RealOwner ||
            !NameValid(desired.Name) || !NameValid(desired.Owner) || desired.Name != desired.Name!.Trim() || desired.Owner != desired.Owner!.Trim() ||
            desired.IsEnabled is null || string.IsNullOrEmpty(desired.Script) || desired.NotifyOnError is null || desired.NotificationEmails is null ||
            baseline.Owner is null || baseline.IsEnabled is null || baseline.Script is null || baseline.NotifyOnError is null || baseline.NotificationEmails is null) return false;
        if (request.BaselineTask is null ? baseline.Id is not null : request.BaselineTask.Id != baseline.Id || !request.BaselineTask.CanEditScript || baseline.Name != request.BaselineTask.Name) return false;
        if (request.BaselineTask is not null && (string.IsNullOrEmpty(baseline.RequestedRealOwner) ? null : baseline.RequestedRealOwner) !=
            (string.IsNullOrEmpty(request.BaselineTask.RealOwner) ? null : request.BaselineTask.RealOwner)) return false;
        var old = baseline.Schedule; var next = desired.Schedule;
        if (old is null || next is null || old.DateType is null || old.WeekDays is null || old.Hour is null || old.Minute is null ||
            old.RepeatDate is null || old.RepeatHour is null || old.RepeatMinute is null || old.LastWorkHour is null ||
            next.Hour is not (>= 0 and <= 23) || next.Minute is not (>= 0 and <= 59) || next.WeekDays is null ||
            next.DateType != old.DateType || next.RepeatDate != old.RepeatDate || next.Date != old.Date || next.RepeatHour != old.RepeatHour ||
            next.RepeatMinute != old.RepeatMinute || next.LastWorkHour != old.LastWorkHour || !SameArray(old.MonthlyWeek, next.MonthlyWeek)) return false;
        var days = next.WeekDays.Split(',');
        return days.Length > 0 && days.All(day => day.Length == 1 && day[0] is >= '0' and <= '6') && days.Distinct().Count() == days.Length;
    }
    private static bool NameValid(string? value) => !string.IsNullOrWhiteSpace(value) && !value.Any(char.IsControl);
    private static bool SameArray(IReadOnlyList<int>? left, IReadOnlyList<int>? right) => left is null ? right is null : right is not null && left.SequenceEqual(right);
}
