using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasHardwareSettings> LoadHardwareSettingsAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var result = new NasHardwareSettings(null, null, null, null, null, null, null, null);
        var any = false;
        foreach (var (api, section) in HardwareReadGroups)
        {
            if (!_capabilities.ContainsKey(api)) continue;
            any = true;
            try
            {
                var data = await ReadNasServiceSettingsAsync(api, 1, cancellationToken).ConfigureAwait(false);
                switch (section)
                {
                    case NasHardwareSections.PowerRecovery:
                        result = result with { PowerFailRestart = data.Bool("rc_power_config") };
                        if (result.PowerFailRestart is null) throw InvalidNasServiceSettings();
                        break;
                    case NasHardwareSections.Led:
                        result = result with { LedBrightness = data.Int("led_brightness") };
                        var limits = await _api.CallReadJsonObjectAsync(_profile, _session, _capabilities[api], 1, "get_static_data",
                            cancellationToken: cancellationToken).ConfigureAwait(false);
                        var min = limits.Int("min"); var max = limits.Int("max");
                        if (min is null || max is null || min > max || result.LedBrightness is null ||
                            result.LedBrightness < min || result.LedBrightness > max) throw InvalidNasServiceSettings();
                        result = result with { LedMinimum = min, LedMaximum = max };
                        break;
                    case NasHardwareSections.Fan:
                        result = result with { FanMode = data.String("dual_fan_speed") };
                        if (string.IsNullOrWhiteSpace(result.FanMode)) throw InvalidNasServiceSettings();
                        break;
                    case NasHardwareSections.Beep:
                        var volume = data.ContainsKey("volume_or_cache_crash") ? "volume_or_cache_crash" :
                            data.ContainsKey("volume_crash") ? "volume_crash" : null;
                        var beep = new NasBeepSettings(data.Bool("fan_fail"), volume is null ? null : data.Bool(volume),
                            data.Bool("poweron_beep"), data.Bool("poweroff_beep"), data.Bool("reset_beep"), volume);
                        result = result with { Beep = beep };
                        if (new[] { beep.FanFailure, beep.VolumeFailure, beep.PowerOn, beep.PowerOff, beep.Reset }.All(value => value is null))
                            throw InvalidNasServiceSettings();
                        break;
                    case NasHardwareSections.Hibernation:
                        var hibernation = new NasHibernationSettings(data.Bool("eunit_deep_sleep"), data.Bool("enable_log"),
                            data.Bool("sata_deep_sleep"), data.Bool("ignore_netbios_broadcast"), data.Bool("auto_poweroff_enable"));
                        result = result with { Hibernation = hibernation };
                        if (new[] { hibernation.ExternalDriveDeepSleep, hibernation.WakeUpLog, hibernation.SataSleep,
                                hibernation.IgnoreNetworkDiscovery, hibernation.AutomaticPowerOff }.All(value => value is null))
                            throw InvalidNasServiceSettings();
                        break;
                    case NasHardwareSections.Ups:
                        var enabled = data.Bool("enable"); var mode = data.String("mode"); var delay = data.Int("delay_time");
                        if (enabled is null || mode is not ("USB" or "SNMP" or "SLAVE")) throw InvalidNasServiceSettings();
                        var ups = new NasUpsSettings(enabled.Value, mode, delay is >= 0 ? delay : null,
                            data.Bool("ups_set_safemode_until_lowbatt"), data.Bool("shutdown_device"),
                            data.String("net_server_ip"), data.String("snmp_server_ip"));
                        result = result with { Ups = ups, UpsEnabled = enabled, UpsMode = mode,
                            UpsShutdownTime = ups.DelaySeconds?.ToString(CultureInfo.InvariantCulture) };
                        break;
                }
                result = result with { AvailableSections = result.AvailableSections | section };
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (DsmException error) when (error.AuthenticationFailure) { throw; }
            catch (Exception) { result = result with { FailedSections = result.FailedSections | section }; }
        }
        if (!any) throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        return result;
    }

    public Task<MutationResult> SaveHardwareSettingsAsync(NasHardwareSettings settings, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return Task.FromResult(UnsupportedResult("saveHardware")); // 旧签名不能完成六组可信字段/LED update 的保存闭环。
    }
    private static readonly (string Api, NasHardwareSections Section)[] HardwareReadGroups =
    [
        ("SYNO.Core.Hardware.PowerRecovery", NasHardwareSections.PowerRecovery),
        ("SYNO.Core.Hardware.Led.Brightness", NasHardwareSections.Led),
        ("SYNO.Core.Hardware.FanSpeed", NasHardwareSections.Fan),
        ("SYNO.Core.Hardware.BeepControl", NasHardwareSections.Beep),
        ("SYNO.Core.Hardware.Hibernation", NasHardwareSections.Hibernation),
        ("SYNO.Core.ExternalDevice.UPS", NasHardwareSections.Ups),
    ];
}
