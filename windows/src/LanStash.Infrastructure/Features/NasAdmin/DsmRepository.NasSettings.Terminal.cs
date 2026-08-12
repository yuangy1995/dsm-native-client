using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasTerminalSettings> LoadTerminalSettingsAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Supports("SYNO.Core.Terminal"))
        {
            return new NasTerminalSettings(false, null, false, null);
        }

        try
        {
            var data = await CallFirstAsync(
                "SYNO.Core.Terminal",
                ["get", "load"],
                parameters: null,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            return new NasTerminalSettings(
                SshEnabled: data.Bool("enable_ssh") ?? data.Bool("ssh_enable") ?? false,
                SshPort: data.Int("ssh_port") ?? data.Int("port"),
                TelnetEnabled: data.Bool("enable_telnet") ?? data.Bool("telnet_enable") ?? false,
                TelnetPort: data.Int("telnet_port") ?? data.Int("telnet_port"));
        }
        catch (DsmException)
        {
            return new NasTerminalSettings(false, null, false, null);
        }
    }

    public Task<MutationResult> SaveTerminalSettingsAsync(
        NasTerminalSettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);

        var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["ssh_enable"] = settings.SshEnabled ? "true" : "false",
            ["telnet_enable"] = settings.TelnetEnabled ? "true" : "false",
        };

        if (settings.SshPort is int sshPort && sshPort is > 0 and <= 65535)
        {
            parameters["ssh_port"] = sshPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        if (settings.TelnetPort is int telnetPort && telnetPort is > 0 and <= 65535)
        {
            parameters["telnet_port"] = telnetPort.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        return SaveSettingsAsync(
            "SYNO.Core.Terminal", "set", parameters, "saveTerminal",
            ct => Task.CompletedTask,
            cancellationToken);
    }
}
