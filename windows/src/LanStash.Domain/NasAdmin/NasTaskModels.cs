using System.Text.Json.Serialization;

namespace LanStash.Domain;

public sealed record NasTaskEntry(int Id, string Name, string? Owner, string? RealOwner, string? Type, string? Action,
    bool? IsEnabled, string? NextTrigger, bool? RunAllowed, bool? EditAllowed)
{
    public bool CanRun => RunAllowed == true;
    public bool CanEditScript => EditAllowed == true && Type == "script";
    public override string ToString() => nameof(NasTaskEntry);
}
public sealed record NasTaskScheduleValues(int? DateType, string? WeekDays, string? Date, int? RepeatDate,
    IReadOnlyList<int>? MonthlyWeek, int? Hour, int? Minute, int? RepeatHour, int? RepeatMinute, int? LastWorkHour);
public sealed record NasTaskDetail(int? Id, string? RequestedRealOwner, string? Name, string? Owner, string? RealOwner,
    bool? IsEnabled, NasTaskScheduleValues? Schedule, [property: JsonIgnore] string? Script,
    bool? NotifyOnError, [property: JsonIgnore] string? NotificationEmails)
{
    public override string ToString() => nameof(NasTaskDetail);
}
public sealed record NasTaskResult(string Id, string TaskName, string? StartedAt, string? StoppedAt, string? ExitType, int? ExitCode, string? TriggerEvent)
{
    public override string ToString() => nameof(NasTaskResult);
}
public sealed record NasTaskResultOutput([property: JsonIgnore] string? Command, [property: JsonIgnore] string? Output)
{
    public override string ToString() => nameof(NasTaskResultOutput);
}
