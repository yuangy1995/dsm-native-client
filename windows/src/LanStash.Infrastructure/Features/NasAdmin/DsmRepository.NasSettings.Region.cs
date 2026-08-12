using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasRegionSettings> LoadRegionSettingsAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Supports("SYNO.Core.Region"))
        {
            return new NasRegionSettings(null, null, null, [], null);
        }

        try
        {
            var data = await CallFirstAsync(
                "SYNO.Core.Region",
                ["get", "load"],
                parameters: null,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            var ntpServers = new List<string>();
            var ntpData = await TryCallFirstAsync(
                "SYNO.Core.NTP",
                ["get", "list"],
                cancellationToken).ConfigureAwait(false);
            if (ntpData is not null)
            {
                foreach (var server in ntpData.Array("servers").OfType<JsonObject>())
                {
                    var host = server.String("host") ?? server.String("server");
                    if (!string.IsNullOrWhiteSpace(host))
                    {
                        ntpServers.Add(host);
                    }
                }
            }

            return new NasRegionSettings(
                DateFormat: data.String("date_format")
                    ?? data.String("date_fmt")
                    ?? data.String("dformat"),
                TimeFormat: data.String("time_format")
                    ?? data.String("time_fmt")
                    ?? data.String("tformat"),
                Timezone: data.String("timezone")
                    ?? data.String("tz")
                    ?? data.String("time_zone"),
                NtpServers: ntpServers,
                ManualDate: data.String("manual_date")
                    ?? data.String("date"));
        }
        catch (DsmException)
        {
            return new NasRegionSettings(null, null, null, [], null);
        }
    }

    public Task<MutationResult> SaveRegionSettingsAsync(
        NasRegionSettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);

        var parameters = new Dictionary<string, string>(StringComparer.Ordinal);

        if (!string.IsNullOrWhiteSpace(settings.DateFormat))
        {
            parameters["date_format"] = settings.DateFormat;
        }

        if (!string.IsNullOrWhiteSpace(settings.TimeFormat))
        {
            parameters["time_format"] = settings.TimeFormat;
        }

        if (!string.IsNullOrWhiteSpace(settings.Timezone))
        {
            parameters["timezone"] = settings.Timezone;
        }

        if (settings.NtpServers is { Count: > 0 })
        {
            parameters["ntp_servers"] = string.Join(",", settings.NtpServers);
        }

        if (!string.IsNullOrWhiteSpace(settings.ManualDate))
        {
            parameters["manual_date"] = settings.ManualDate;
        }

        return SaveSettingsAsync(
            "SYNO.Core.Region", "set", parameters, "saveRegion",
            ct => Task.CompletedTask,
            cancellationToken);
    }
}
