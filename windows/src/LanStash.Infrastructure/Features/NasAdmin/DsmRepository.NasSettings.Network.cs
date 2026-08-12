using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<IReadOnlyList<NasEthernetInterface>> LoadEthernetInterfacesAsync(
        CancellationToken cancellationToken = default)
    {
        if (!Supports("SYNO.Core.Network.Ethernet"))
        {
            return [];
        }

        try
        {
            var data = await CallFirstAsync(
                "SYNO.Core.Network.Ethernet",
                ["list", "get"],
                parameters: null,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            return data.Array("interfaces").OfType<JsonObject>()
                .Select(item => new NasEthernetInterface(
                    item.String("id") ?? item.String("name") ?? "unknown",
                    item.String("name") ?? item.String("id") ?? "unknown",
                    DhcpEnabled: item.Bool("dhcp") ?? item.Bool("is_dhcp") ?? true,
                    IpAddress: item.String("ip") ?? item.String("ipv4"),
                    SubnetMask: item.String("mask") ?? item.String("subnet") ?? item.String("netmask"),
                    Gateway: item.String("gateway") ?? item.String("gw"),
                    DnsServers: ParseDnsServers(item.String("dns") ?? item.String("dns_servers")),
                    Mtu: item.Int("mtu"),
                    VlanId: item.Int("vlan_id") ?? item.Int("vlan")))
                .ToArray();
        }
        catch (DsmException)
        {
            return [];
        }
    }

    private static IReadOnlyList<string> ParseDnsServers(string? dnsList)
    {
        if (string.IsNullOrWhiteSpace(dnsList))
        {
            return [];
        }

        return dnsList.Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(entry => entry.Trim())
            .Where(entry => !string.IsNullOrWhiteSpace(entry))
            .ToArray();
    }

    public Task<MutationResult> SaveEthernetInterfaceAsync(
        string interfaceId,
        bool dhcp,
        string? ip,
        string? subnet,
        string? gateway,
        IReadOnlyList<string>? dns,
        int? mtu,
        int? vlan,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(interfaceId))
        {
            return Task.FromResult(ConfirmedFailureResult(
                "saveNetwork", MutationErrorCategory.Validation, "network.save.validation"));
        }

        var parameters = new Dictionary<string, string>(StringComparer.Ordinal)
        {
            ["id"] = interfaceId,
            ["dhcp"] = dhcp ? "true" : "false",
        };

        if (!dhcp && !string.IsNullOrWhiteSpace(ip))
        {
            parameters["ip"] = ip;
            if (!string.IsNullOrWhiteSpace(subnet))
            {
                parameters["mask"] = subnet;
            }
            if (!string.IsNullOrWhiteSpace(gateway))
            {
                parameters["gateway"] = gateway;
            }
        }

        if (dns is { Count: > 0 })
        {
            parameters["dns"] = string.Join(",", dns);
        }

        if (mtu is int mtuValue && mtuValue is >= 576 and <= 9000)
        {
            parameters["mtu"] = mtuValue.ToString(
                System.Globalization.CultureInfo.InvariantCulture);
        }

        if (vlan is int vlanValue && vlanValue is >= 1 and <= 4094)
        {
            parameters["vlan"] = vlanValue.ToString(
                System.Globalization.CultureInfo.InvariantCulture);
        }

        return SaveSettingsAsync(
            "SYNO.Core.Network.Ethernet", "set", parameters, "saveNetwork",
            ct => Task.CompletedTask,
            cancellationToken);
    }
}
