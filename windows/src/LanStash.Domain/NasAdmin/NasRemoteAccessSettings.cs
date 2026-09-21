namespace LanStash.Domain;

[Flags]
public enum NasRemoteAccessParts { None = 0, Relay = 1, Router = 2 }
public sealed record NasRemoteAccessSettings(bool? RelayEnabled, bool? RouterConfigurationEnabled, bool CanDisableRelay,
    NasRemoteAccessParts AvailableParts = NasRemoteAccessParts.None, NasRemoteAccessParts FailedParts = NasRemoteAccessParts.None);

public static class NasRemoteAccessRules
{
    public static bool IsValidChange(NasRemoteAccessSettings baseline, NasRemoteAccessSettings desired)
    {
        if (baseline.CanDisableRelay != desired.CanDisableRelay || baseline.AvailableParts != desired.AvailableParts || baseline.FailedParts != desired.FailedParts ||
            (baseline.AvailableParts & ~(NasRemoteAccessParts.Relay | NasRemoteAccessParts.Router)) != 0 ||
            (baseline.FailedParts & ~(NasRemoteAccessParts.Relay | NasRemoteAccessParts.Router)) != 0) return false;
        var changes = 0;
        foreach (var part in new[] { NasRemoteAccessParts.Relay, NasRemoteAccessParts.Router })
        {
            var before = Value(baseline, part); var after = Value(desired, part);
            if (before == after) continue;
            if (before is null || after is null || !baseline.AvailableParts.HasFlag(part) || baseline.FailedParts.HasFlag(part)) return false;
            if (part == NasRemoteAccessParts.Relay && after == false && !baseline.CanDisableRelay) return false;
            changes++;
        }
        return changes > 0;
    }
    public static bool? Value(NasRemoteAccessSettings value, NasRemoteAccessParts part) => part == NasRemoteAccessParts.Relay ? value.RelayEnabled : value.RouterConfigurationEnabled;
}
