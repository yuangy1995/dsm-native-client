using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasProxySettings> LoadProxySettingsAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Supports("SYNO.Core.Network.Proxy"))
        {
            return new NasProxySettings(false, null, null);
        }

        try
        {
            var data = await CallFirstAsync(
                "SYNO.Core.Network.Proxy",
                ["get", "load"],
                parameters: null,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            return new NasProxySettings(
                Enabled: data.Bool("enable") ?? data.Bool("enabled") ?? false,
                Host: data.String("server") ?? data.String("host") ?? data.String("proxy_server"),
                Port: data.Int("port") ?? data.Int("proxy_port"));
        }
        catch (DsmException)
        {
            return new NasProxySettings(false, null, null);
        }
    }

    public Task<MutationResult> SaveProxySettingsAsync(
        NasProxySettings settings,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);

        var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["enable"] = settings.Enabled ? "true" : "false",
        };

        if (!string.IsNullOrWhiteSpace(settings.Host))
        {
            parameters["server"] = settings.Host;
        }

        if (settings.Port is int port && port is > 0 and <= 65535)
        {
            parameters["port"] = port.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        return SaveSettingsAsync(
            "SYNO.Core.Network.Proxy", "set", parameters, "saveProxy",
            ct => Task.CompletedTask,
            cancellationToken);
    }
}
