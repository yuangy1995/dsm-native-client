namespace LanStash.Domain;

public sealed record NasRegionSettingsSaveRequest(Guid ProfileId, NasRegionSettings Baseline,
    NasRegionSettings Desired, Guid RequestId, bool RiskConfirmed, DateTime? EditedNasTime = null);

public static class NasRegionSettingsRules
{
    public static NasRegionSettings Normalize(NasRegionSettings value) => value with
    {
        DateFormat = value.DateFormat?.Trim(), TimeFormat = value.TimeFormat?.Trim(),
        NtpServers = Array.AsReadOnly(value.NtpServers.Select(item => item.Trim()).Where(item => item.Length > 0).ToArray()),
        TimeZones = Array.AsReadOnly(value.TimeZones.ToArray()),
    };

    public static bool IsValid(NasRegionSettings value, DateTime? editedTime)
    {
        if (string.IsNullOrWhiteSpace(value.DateFormat) || string.IsNullOrWhiteSpace(value.TimeFormat) ||
            string.IsNullOrWhiteSpace(value.Timezone) || value.Mode is not (NasRegionTimeMode.Network or NasRegionTimeMode.Manual))
            return false;
        if (editedTime is { } clock && (value.Mode != NasRegionTimeMode.Manual ||
            clock.Kind != DateTimeKind.Unspecified || clock.Ticks % TimeSpan.TicksPerSecond != 0)) return false;
        return value.Mode != NasRegionTimeMode.Network || value.NtpServers.Count is > 0 and <= 3 &&
            value.NtpServers.All(IsTimeServer);
    }

    public static bool IsTimeServer(string value) =>
        value.Length is > 0 and <= 253 && value.All(character => char.IsAsciiLetterOrDigit(character) || character is '.' or '-' or ':') &&
        Uri.CheckHostName(value) != UriHostNameType.Unknown;
}
