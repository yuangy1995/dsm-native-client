using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasPowerScheduleSnapshot> LoadPowerScheduleAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var capability = SecurityCapability("SYNO.Core.Hardware.PowerSchedule", 1) ??
            throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "load", cancellationToken: cancellationToken).ConfigureAwait(false);
        var root = PowerScheduleField(data, "schedules", "items");
        if (root is not JsonArray rows) throw InvalidNasServiceSettings();
        var entries = new List<NasPowerScheduleEntry>(); var ids = new HashSet<string>(StringComparer.Ordinal); var ignored = 0;
        for (var index = 0; index < Math.Min(rows.Count, 128); index++)
        {
            if (rows[index] is not JsonObject item) { ignored++; continue; }
            var hour = PowerScheduleInteger(item["hour"]); var minute = PowerScheduleInteger(item["minute"]);
            if (hour is not (>= 0 and <= 23) || minute is not (>= 0 and <= 59)) { ignored++; continue; }
            var rawId = PowerScheduleText(PowerScheduleField(item, "id", "schedule_id"));
            var id = rawId is { Length: > 0 and <= 128 } && rawId.All(c => char.IsLetterOrDigit(c) || "._-:".Contains(c)) ? rawId : $"snapshot-{index}";
            if (!ids.Add(id)) { ignored++; continue; }
            var action = PowerScheduleText(PowerScheduleField(item, "action", "type", "operation"))?.Trim().ToLowerInvariant() switch
            {
                "startup" or "start" or "poweron" or "power_on" or "boot" => NasPowerScheduleAction.Startup,
                "shutdown" or "stop" or "poweroff" or "power_off" => NasPowerScheduleAction.Shutdown,
                "restart" or "reboot" => NasPowerScheduleAction.Restart,
                _ => NasPowerScheduleAction.Unknown
            };
            bool? enabled = PowerScheduleField(item, "enabled", "is_enabled") is JsonValue flag && flag.TryGetValue<bool>(out var value) ? value : null;
            var (recurrence, date, days) = ParsePowerRecurrence(item);
            entries.Add(new(id, action, enabled, hour.Value, minute.Value, recurrence, date, days));
        }
        var total = PowerScheduleInteger(PowerScheduleField(data, "total", "total_count"));
        if (total is < 0 or > 1_000_000) total = null;
        var zone = PowerScheduleText(PowerScheduleField(data, "timezone", "time_zone"))?.Trim();
        if (zone is not { Length: > 0 and <= 128 } || !zone.All(c => char.IsLetterOrDigit(c) || "_/+-".Contains(c))) zone = null;
        return new(entries.AsReadOnly(), zone, Math.Max(rows.Count, total ?? rows.Count), rows.Count > 128 || total > rows.Count, ignored);
    }
    private static (NasPowerScheduleRecurrence, DateOnly?, IReadOnlyList<DayOfWeek>) ParsePowerRecurrence(JsonObject item)
    {
        var dateText = PowerScheduleText(PowerScheduleField(item, "date", "run_date"));
        if (DateOnly.TryParseExact(dateText, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) && date.Year >= 1970)
            return (NasPowerScheduleRecurrence.Once, date, Array.Empty<DayOfWeek>());
        var raw = PowerScheduleField(item, "weekdays", "days", "repeat");
        string[] tokens;
        if (raw is JsonArray array)
        {
            if (array.Any(node => PowerScheduleText(node) is null)) return (NasPowerScheduleRecurrence.Unknown, null, Array.Empty<DayOfWeek>());
            tokens = array.Select(node => PowerScheduleText(node)!).ToArray();
        }
        else tokens = PowerScheduleText(raw)?.Split([',', ' ', ';'], StringSplitOptions.RemoveEmptyEntries) ?? [];
        var days = tokens.Select(PowerScheduleWeekday).ToArray();
        if (days.Length == 0 || days.Any(day => day is null) || days.Distinct().Count() != days.Length)
            return (NasPowerScheduleRecurrence.Unknown, null, Array.Empty<DayOfWeek>());
        var sorted = Array.AsReadOnly(days.Select(day => day!.Value).OrderBy(day => day == DayOfWeek.Sunday ? 7 : (int)day).ToArray());
        return (days.Length == 7 ? NasPowerScheduleRecurrence.Daily : NasPowerScheduleRecurrence.Weekly, null, sorted);
    }
    private static DayOfWeek? PowerScheduleWeekday(string value) => value.Trim().ToLowerInvariant() switch
    {
        "mon" or "monday" => DayOfWeek.Monday, "tue" or "tues" or "tuesday" => DayOfWeek.Tuesday,
        "wed" or "wednesday" => DayOfWeek.Wednesday, "thu" or "thur" or "thurs" or "thursday" => DayOfWeek.Thursday,
        "fri" or "friday" => DayOfWeek.Friday, "sat" or "saturday" => DayOfWeek.Saturday, "sun" or "sunday" => DayOfWeek.Sunday, _ => null
    };
    private static int? PowerScheduleInteger(JsonNode? node)
    {
        if (node is JsonValue number)
        {
            if (number.TryGetValue<int>(out var value)) return value;
            if (number.TryGetValue<double>(out var real) && real == Math.Truncate(real) && real is >= int.MinValue and <= int.MaxValue) return (int)real;
        }
        return int.TryParse(PowerScheduleText(node), NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
    }
    private static string? PowerScheduleText(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
    private static JsonNode? PowerScheduleField(JsonObject data, params string[] names)
    {
        JsonNode? selected = null;
        foreach (var name in names)
        {
            if (data[name] is not { } value) continue;
            if (selected is not null && !JsonNode.DeepEquals(selected, value)) return null;
            selected = value;
        }
        return selected;
    }
}
