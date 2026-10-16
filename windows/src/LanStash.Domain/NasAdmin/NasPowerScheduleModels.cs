namespace LanStash.Domain;

public enum NasPowerScheduleAction { Unknown, Startup, Shutdown, Restart }
public enum NasPowerScheduleRecurrence { Unknown, Once, Weekly, Daily }
// Id 仅用于本次本地草稿；保存始终发送完整双数组，不能将其作为服务端目标。
public sealed record NasPowerScheduleEntry(string Id, NasPowerScheduleAction Action, bool? IsEnabled, int Hour, int Minute,
    NasPowerScheduleRecurrence Recurrence, DateOnly? Date, IReadOnlyList<DayOfWeek> Weekdays);
public sealed record NasPowerScheduleSnapshot(IReadOnlyList<NasPowerScheduleEntry> Entries, string? TimeZoneIdentifier,
    int Total, bool IsTruncated, int IgnoredEntries)
{
    public bool SupportsEditing { get; init; }
    public bool CanEdit => SupportsEditing && !IsTruncated && IgnoredEntries == 0 && Total == Entries.Count &&
        NasPowerScheduleRules.IsValid(Entries);
}

public static class NasPowerScheduleRules
{
    public const int MaximumEntries = 200;
    public static IReadOnlyList<DayOfWeek> Days(NasPowerScheduleEntry entry) => entry.Recurrence == NasPowerScheduleRecurrence.Daily
        ? Enum.GetValues<DayOfWeek>() : entry.Weekdays.OrderBy(day => (int)day).ToArray();
    public static bool SemanticallyEqual(IReadOnlyList<NasPowerScheduleEntry> left, IReadOnlyList<NasPowerScheduleEntry> right) =>
        left.Select(Key).Order().SequenceEqual(right.Select(Key).Order());
    private static (NasPowerScheduleAction Action, bool? Enabled, int Hour, int Minute, int Days) Key(NasPowerScheduleEntry entry) =>
        (entry.Action, entry.IsEnabled, entry.Hour, entry.Minute, Days(entry).Aggregate(0, (mask, day) => mask | 1 << (int)day));
    public static bool IsValid(IReadOnlyList<NasPowerScheduleEntry>? entries)
    {
        if (entries is null || entries.Count > MaximumEntries) return false;
        var occupied = new HashSet<(DayOfWeek Day, int Hour, int Minute)>();
        foreach (var entry in entries)
        {
            if (entry is null || entry.IsEnabled is null || entry.Action is not (NasPowerScheduleAction.Startup or NasPowerScheduleAction.Shutdown) ||
                entry.Hour is < 0 or > 23 || entry.Minute is < 0 or > 59 || entry.Date is not null ||
                entry.Recurrence is not (NasPowerScheduleRecurrence.Daily or NasPowerScheduleRecurrence.Weekly)) return false;
            var days = Days(entry);
            if (days.Count == 0 || days.Any(day => !Enum.IsDefined(day)) || days.Distinct().Count() != days.Count ||
                days.Any(day => !occupied.Add((day, entry.Hour, entry.Minute)))) return false;
        }
        return true;
    }
}
