using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasSecuritySettings> LoadSecuritySettingsAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Supports("SYNO.Core.Security.AutoBlock") && !Supports("SYNO.Core.Security"))
        {
            return new NasSecuritySettings(null, null, null, null, null, null, null);
        }

        try
        {
            var autoBlock = await TryCallFirstAsync(
                "SYNO.Core.Security.AutoBlock",
                ["get", "load"],
                cancellationToken).ConfigureAwait(false);

            var dos = await TryCallFirstAsync(
                "SYNO.Core.Security.DoS",
                ["get", "load"],
                cancellationToken).ConfigureAwait(false);

            var firewall = await TryCallFirstAsync(
                "SYNO.Core.Security.Firewall",
                ["get", "load"],
                cancellationToken).ConfigureAwait(false);

            return new NasSecuritySettings(
                AutoBlockEnabled: autoBlock?.Bool("enable") ?? autoBlock?.Bool("enabled"),
                AutoBlockFailedAttempts: autoBlock?.Int("failed_attempts")
                    ?? autoBlock?.Int("attempts")
                    ?? autoBlock?.Int("login_failed"),
                AutoBlockWithinMinutes: autoBlock?.Int("within_minutes")
                    ?? autoBlock?.Int("minutes"),
                AutoBlockExpiryDays: autoBlock?.Int("expiry_days")
                    ?? autoBlock?.Int("expiry")
                    ?? autoBlock?.Int("block_minute"),
                DosProtectionEnabled: dos?.Bool("enable") ?? dos?.Bool("enabled"),
                FirewallEnabled: firewall?.Bool("enable") ?? firewall?.Bool("enabled"),
                PortScanEnabled: dos?.Bool("port_scan") ?? dos?.Bool("portscan"));
        }
        catch (DsmException)
        {
            return new NasSecuritySettings(null, null, null, null, null, null, null);
        }
    }

    public Task<MutationResult> SaveSecuritySettingsAsync(
        NasSecuritySettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);

        var operation = "saveSecurity";
        if (!Supports("SYNO.Core.Security.AutoBlock") && !Supports("SYNO.Core.Security"))
        {
            return Task.FromResult(UnsupportedResult(operation));
        }

        if (settings.AutoBlockEnabled is bool autoBlock)
        {
            _ = SaveAutoBlockAsync(autoBlock,
                settings.AutoBlockFailedAttempts,
                settings.AutoBlockWithinMinutes,
                settings.AutoBlockExpiryDays,
                cancellationToken);
        }

        if (settings.DosProtectionEnabled is bool dos)
        {
            _ = SaveDosAsync(dos,
                settings.PortScanEnabled,
                cancellationToken);
        }

        if (settings.FirewallEnabled is bool firewall)
        {
            _ = SaveFirewallAsync(firewall, cancellationToken);
        }

        return Task.FromResult(ConfirmedSuccessResult(operation));
    }

    private async Task SaveAutoBlockAsync(
        bool enabled,
        int? failedAttempts,
        int? withinMinutes,
        int? expiryDays,
        CancellationToken cancellationToken)
    {
        var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["enable"] = enabled ? "true" : "false",
        };

        if (failedAttempts > 0)
        {
            parameters["failed_attempts"] = failedAttempts.Value.ToString(
                System.Globalization.CultureInfo.InvariantCulture);
        }

        if (withinMinutes > 0)
        {
            parameters["within_minutes"] = withinMinutes.Value.ToString(
                System.Globalization.CultureInfo.InvariantCulture);
        }

        if (expiryDays > 0)
        {
            parameters["expiry_days"] = expiryDays.Value.ToString(
                System.Globalization.CultureInfo.InvariantCulture);
        }

        await SaveSettingsAsync(
            "SYNO.Core.Security.AutoBlock", "set", parameters,
            "saveAutoBlock", cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    private async Task SaveDosAsync(
        bool enabled,
        bool? portScan,
        CancellationToken cancellationToken)
    {
        var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["enable"] = enabled ? "true" : "false",
        };

        if (portScan is bool ps)
        {
            parameters["port_scan"] = ps ? "true" : "false";
        }

        await SaveSettingsAsync(
            "SYNO.Core.Security.DoS", "set", parameters,
            "saveDoS", cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    private async Task SaveFirewallAsync(
        bool enabled,
        CancellationToken cancellationToken)
    {
        await SaveSettingsAsync(
            "SYNO.Core.Security.Firewall", "set",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["enable"] = enabled ? "true" : "false",
            },
            "saveFirewall", cancellationToken: cancellationToken).ConfigureAwait(false);
    }
}
