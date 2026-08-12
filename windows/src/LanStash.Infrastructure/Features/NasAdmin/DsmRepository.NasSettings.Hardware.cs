using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasHardwareSettings> LoadHardwareSettingsAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Supports("SYNO.Core.Hardware"))
        {
            return new NasHardwareSettings(null, null, null, null, null, null, null, null);
        }

        try
        {
            var data = await CallFirstAsync(
                "SYNO.Core.Hardware",
                ["get", "load"],
                parameters: null,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            var general = data.Object("general") ?? data;
            var beep = data.Object("beep_control") ?? data.Object("beep") ?? data;
            var fan = data.Object("fan") ?? data;
            var hdd = data.Object("hdd_sleep") ?? data.Object("hdd") ?? data;
            var ups = data.Object("ups") ?? data.Object("UPS") ?? data;

            return new NasHardwareSettings(
                PowerFailRestart: general.Bool("power_fail_restart")
                    ?? general.Bool("power_recovery"),
                LedBrightness: general.Int("led_brightness")
                    ?? general.Int("brightness_level"),
                FanMode: general.String("fan_mode")
                    ?? fan.String("mode"),
                BeepControl: beep.Bool("enable")
                    ?? beep.Bool("enabled"),
                HddSleepMinutes: hdd.Int("sleep_minutes")
                    ?? hdd.Int("hdd_sleep"),
                UpsEnabled: ups.Bool("enable")
                    ?? ups.Bool("enabled"),
                UpsMode: ups.String("mode"),
                UpsShutdownTime: ups.String("shutdown_time")
                    ?? ups.String("shutdowntime"));
        }
        catch (DsmException)
        {
            return new NasHardwareSettings(null, null, null, null, null, null, null, null);
        }
    }

    public Task<MutationResult> SaveHardwareSettingsAsync(
        NasHardwareSettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);

        var parameters = new Dictionary<string, string>(StringComparer.Ordinal);

        if (settings.PowerFailRestart is bool pfr)
        {
            parameters["power_fail_restart"] = pfr ? "true" : "false";
        }

        if (settings.LedBrightness is int led && led is >= 0 and <= 100)
        {
            parameters["led_brightness"] = led.ToString(
                System.Globalization.CultureInfo.InvariantCulture);
        }

        if (!string.IsNullOrWhiteSpace(settings.FanMode))
        {
            parameters["fan_mode"] = settings.FanMode;
        }

        if (settings.BeepControl is bool beep)
        {
            parameters["beep_control"] = beep ? "true" : "false";
        }

        if (settings.HddSleepMinutes is int sleep && sleep is >= 0 and <= 600)
        {
            parameters["hdd_sleep"] = sleep.ToString(
                System.Globalization.CultureInfo.InvariantCulture);
        }

        if (settings.UpsEnabled is bool upsEnabled)
        {
            parameters["ups_enable"] = upsEnabled ? "true" : "false";
        }

        if (!string.IsNullOrWhiteSpace(settings.UpsMode))
        {
            parameters["ups_mode"] = settings.UpsMode;
        }

        if (!string.IsNullOrWhiteSpace(settings.UpsShutdownTime))
        {
            parameters["ups_shutdown_time"] = settings.UpsShutdownTime;
        }

        return SaveSettingsAsync(
            "SYNO.Core.Hardware", "set", parameters, "saveHardware",
            ct => Task.CompletedTask,
            cancellationToken);
    }
}
