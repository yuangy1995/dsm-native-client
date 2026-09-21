using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // DSM 内部区域/时间接口；读取不会触发 set 或 sync。
    public async Task<NasRegionSettings> LoadRegionSettingsAsync(CancellationToken cancellationToken = default)
    {
        const string name = "SYNO.Core.Region.NTP";
        cancellationToken.ThrowIfCancellationRequested();
        if (!_capabilities.TryGetValue(name, out var capability) || capability.Name != name ||
            capability.MinVersion != 1 || capability.MaxVersion < 3 ||
            !(capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) ||
              capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)))
            throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 3, "get",
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var dateFormat = data.String("date_format");
        var timeFormat = data.String("time_format");
        var timezone = data.String("timezone");
        var mode = data.String("enable_ntp")?.ToLowerInvariant() switch
        {
            "ntp" or "true" or "yes" or "1" or "enabled" => NasRegionTimeMode.Network,
            "manual" or "false" or "no" or "0" or "disabled" => NasRegionTimeMode.Manual,
            _ => NasRegionTimeMode.Unknown,
        };
        if (string.IsNullOrWhiteSpace(dateFormat) || string.IsNullOrWhiteSpace(timeFormat) ||
            string.IsNullOrWhiteSpace(timezone) || mode == NasRegionTimeMode.Unknown) throw InvalidNasServiceSettings();
        var zoneData = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "listzone",
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (zoneData["zonedata"] is not JsonArray entries) throw InvalidNasServiceSettings();
        var zones = new List<NasTimeZoneOption>();
        foreach (var entry in entries)
        {
            if (entry is not JsonObject zone || string.IsNullOrWhiteSpace(zone.String("value"))) throw InvalidNasServiceSettings();
            var id = zone.String("value")!;
            if (zones.Any(item => item.Id == id)) throw InvalidNasServiceSettings();
            zones.Add(new(id, zone.String("display") ?? id));
        }
        if (!zones.Any(zone => zone.Id == timezone)) throw InvalidNasServiceSettings();
        var servers = (data.String("server") ?? string.Empty).Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        DateTime? clock = null;
        var hour = data.Int("hour"); var minute = data.Int("minute"); var second = data.Int("second");
        if (DateOnly.TryParseExact(data.String("date"), "yyyy/M/d", CultureInfo.InvariantCulture,
                DateTimeStyles.None, out var date) && hour is >= 0 and <= 23 &&
            minute is >= 0 and <= 59 && second is >= 0 and <= 59)
            clock = date.ToDateTime(new TimeOnly(hour.Value, minute.Value, second.Value), DateTimeKind.Unspecified);
        return new(dateFormat, timeFormat, timezone, Array.AsReadOnly(servers), data.String("date"))
        {
            Mode = mode, NasLocalTime = clock, TimeZones = zones.AsReadOnly(),
        };
    }

    public Task<MutationResult> SaveRegionSettingsAsync(NasRegionSettings settings, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        // 无基线/手动时间编辑意图的旧签名不得执行改时或校时。
        return Task.FromResult(UnsupportedResult("saveRegion"));
    }
}
