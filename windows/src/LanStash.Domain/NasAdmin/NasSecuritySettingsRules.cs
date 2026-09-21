namespace LanStash.Domain;

public static class NasSecuritySettingsRules
{
    public static bool IsValidChange(NasSecuritySettings baseline, NasSecuritySettings desired)
    {
        if (baseline.AvailableSections == NasSecuritySections.None ||
            ((int)baseline.AvailableSections & ~15) != 0 || baseline.AvailableSections != desired.AvailableSections ||
            baseline.FailedSections != NasSecuritySections.None || desired.FailedSections != NasSecuritySections.None ||
            baseline.FirewallProfileName != desired.FirewallProfileName) return false;
        if (desired.AvailableSections.HasFlag(NasSecuritySections.AutoBlock))
        {
            if (desired.AutoBlockEnabled is null || desired.AutoBlockFailedAttempts is not > 0 ||
                desired.AutoBlockWithinMinutes is not > 0 || desired.AutoBlockExpiryDays is not >= 0) return false;
        }
        else if (baseline.AutoBlockEnabled != desired.AutoBlockEnabled || baseline.AutoBlockFailedAttempts != desired.AutoBlockFailedAttempts ||
            baseline.AutoBlockWithinMinutes != desired.AutoBlockWithinMinutes || baseline.AutoBlockExpiryDays != desired.AutoBlockExpiryDays) return false;
        if (desired.AvailableSections.HasFlag(NasSecuritySections.Firewall))
        {
            if (desired.FirewallEnabled is null) return false;
            if (desired.FirewallEnabled == true && baseline.FirewallEnabled != true && string.IsNullOrWhiteSpace(baseline.FirewallProfileName)) return false;
        }
        else if (baseline.FirewallEnabled != desired.FirewallEnabled) return false;
        if (desired.AvailableSections.HasFlag(NasSecuritySections.PortScan))
        {
            if (desired.PortScanEnabled is null) return false;
        }
        else if (baseline.PortScanEnabled != desired.PortScanEnabled) return false;
        var original = baseline.DosProtection.OrderBy(item => item.Id, StringComparer.Ordinal).ToArray();
        var target = desired.DosProtection.OrderBy(item => item.Id, StringComparer.Ordinal).ToArray();
        if (original.Length != target.Length || target.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() != target.Length ||
            target.Any(item => string.IsNullOrWhiteSpace(item.Id) || !item.Id.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '-'))) return false;
        for (var index = 0; index < original.Length; index++)
            if (original[index].Id != target[index].Id || !desired.AvailableSections.HasFlag(NasSecuritySections.Dos) &&
                original[index].Enabled != target[index].Enabled) return false;
        return desired.DosProtectionEnabled == Aggregate(desired.DosProtection);
    }
    public static bool? Aggregate(IReadOnlyList<NasDoSProtectionSetting> rows) =>
        rows.Count == 0 || rows.Any(item => item.Enabled != rows[0].Enabled) ? null : rows[0].Enabled;
}
