namespace LanStash.Domain;

public enum NasPowerScheduleAction { Unknown, Startup, Shutdown, Restart }
public enum NasPowerScheduleRecurrence { Unknown, Once, Weekly, Daily }
// Id 仅用于本次只读快照，不能作为任何写操作目标。
public sealed record NasPowerScheduleEntry(string Id, NasPowerScheduleAction Action, bool? IsEnabled, int Hour, int Minute,
    NasPowerScheduleRecurrence Recurrence, DateOnly? Date, IReadOnlyList<DayOfWeek> Weekdays);
public sealed record NasPowerScheduleSnapshot(IReadOnlyList<NasPowerScheduleEntry> Entries, string? TimeZoneIdentifier,
    int Total, bool IsTruncated, int IgnoredEntries);
