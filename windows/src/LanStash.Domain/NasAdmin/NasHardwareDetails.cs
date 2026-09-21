namespace LanStash.Domain;

[Flags]
public enum NasHardwareSections { None = 0, PowerRecovery = 1, Led = 2, Fan = 4, Beep = 8, Hibernation = 16, Ups = 32 }
public sealed record NasBeepSettings(bool? FanFailure, bool? VolumeFailure, bool? PowerOn, bool? PowerOff, bool? Reset, string? VolumeFieldName);
public sealed record NasHibernationSettings(bool? ExternalDriveDeepSleep, bool? WakeUpLog, bool? SataSleep, bool? IgnoreNetworkDiscovery, bool? AutomaticPowerOff);
public sealed record NasUpsSettings(bool Enabled, string Mode, int? DelaySeconds, bool? WaitForLowBattery,
    bool? ShutdownDevice, string? NetworkServer, string? SnmpServer);
