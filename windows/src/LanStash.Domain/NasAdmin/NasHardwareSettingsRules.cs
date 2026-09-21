namespace LanStash.Domain;

public static class NasHardwareSettingsRules
{
    public static readonly IReadOnlyList<string> FanModes = Array.AsReadOnly(new[] { "highfan", "lowfan", "fullfan", "coolfan", "quietfan", "quietstopfan" });
    public static Dictionary<string, object> Fields(NasHardwareSettings value, NasHardwareSections section)
    {
        var result = new Dictionary<string, object>(StringComparer.Ordinal);
        void Add(string key, object? item) { if (item is not null) result[key] = item; }
        switch (section)
        {
            case NasHardwareSections.PowerRecovery: Add("rc_power_config", value.PowerFailRestart); break;
            case NasHardwareSections.Led: Add("led_brightness", value.LedBrightness); break;
            case NasHardwareSections.Fan: Add("dual_fan_speed", value.FanMode); break;
            case NasHardwareSections.Beep:
                if (value.Beep is { } beep)
                {
                    Add("fan_fail", beep.FanFailure);
                    if (beep.VolumeFieldName is "volume_or_cache_crash" or "volume_crash") Add(beep.VolumeFieldName, beep.VolumeFailure);
                    Add("poweron_beep", beep.PowerOn); Add("poweroff_beep", beep.PowerOff); Add("reset_beep", beep.Reset);
                }
                break;
            case NasHardwareSections.Hibernation:
                if (value.Hibernation is { } sleep)
                {
                    Add("eunit_deep_sleep", sleep.ExternalDriveDeepSleep); Add("enable_log", sleep.WakeUpLog);
                    Add("sata_deep_sleep", sleep.SataSleep); Add("ignore_netbios_broadcast", sleep.IgnoreNetworkDiscovery);
                    Add("auto_poweroff_enable", sleep.AutomaticPowerOff);
                }
                break;
            case NasHardwareSections.Ups:
                if (value.Ups is { } ups)
                {
                    Add("enable", ups.Enabled); Add("mode", ups.Mode); Add("delay_time", ups.DelaySeconds);
                    Add("ups_set_safemode_until_lowbatt", ups.WaitForLowBattery); Add("shutdown_device", ups.ShutdownDevice);
                    Add("net_server_ip", ups.NetworkServer); Add("snmp_server_ip", ups.SnmpServer);
                }
                break;
        }
        return result;
    }
    public static bool IsValidChange(NasHardwareSettings baseline, NasHardwareSettings desired)
    {
        if (baseline.AvailableSections == NasHardwareSections.None || ((int)baseline.AvailableSections & ~63) != 0 ||
            baseline.AvailableSections != desired.AvailableSections || baseline.FailedSections != NasHardwareSections.None ||
            desired.FailedSections != NasHardwareSections.None || baseline.LedMinimum != desired.LedMinimum ||
            baseline.LedMaximum != desired.LedMaximum || baseline.Beep?.VolumeFieldName != desired.Beep?.VolumeFieldName ||
            baseline.BeepControl != desired.BeepControl || baseline.HddSleepMinutes != desired.HddSleepMinutes) return false;
        if ((baseline.Beep is null) != (desired.Beep is null) || (baseline.Hibernation is null) != (desired.Hibernation is null) ||
            (baseline.Ups is null) != (desired.Ups is null)) return false;
        if (baseline.Beep?.VolumeFailure != desired.Beep?.VolumeFailure &&
            baseline.Beep?.VolumeFieldName is not ("volume_or_cache_crash" or "volume_crash")) return false;
        if (desired.UpsEnabled != baseline.UpsEnabled && desired.UpsEnabled != desired.Ups?.Enabled ||
            desired.UpsMode != baseline.UpsMode && desired.UpsMode != desired.Ups?.Mode) return false;
        foreach (var section in Enum.GetValues<NasHardwareSections>().Where(item => item != NasHardwareSections.None))
        {
            var before = Fields(baseline, section); var after = Fields(desired, section);
            if (!before.Keys.ToHashSet(StringComparer.Ordinal).SetEquals(after.Keys)) return false;
            if (!baseline.AvailableSections.HasFlag(section) && before.Any(pair => !Equals(pair.Value, after[pair.Key]))) return false;
        }
        if (baseline.LedBrightness != desired.LedBrightness &&
            (desired.LedBrightness is not int brightness || baseline.LedMinimum is not int minimum ||
             baseline.LedMaximum is not int maximum || brightness < minimum || brightness > maximum)) return false;
        if (baseline.FanMode != desired.FanMode && !FanModes.Contains(desired.FanMode)) return false;
        if (desired.Ups is { } ups && baseline.Ups != desired.Ups)
        {
            if (ups.Mode is not ("USB" or "SNMP" or "SLAVE") || ups.DelaySeconds is < 0 or > 604800) return false;
            if (ups.Enabled && ups.Mode == "SLAVE" && string.IsNullOrWhiteSpace(ups.NetworkServer)) return false;
            if (ups.Enabled && ups.Mode == "SNMP" && string.IsNullOrWhiteSpace(ups.SnmpServer)) return false;
        }
        return true;
    }
}
