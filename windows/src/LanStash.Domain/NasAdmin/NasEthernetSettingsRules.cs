using System.Net;
using System.Net.Sockets;

namespace LanStash.Domain;

public sealed record NasEthernetRecoveryInfo(string InterfaceId, bool RequiresSignIn, bool RequiresSameNasConfirmation);

public static class NasEthernetSettingsRules
{
    public static bool SafeId(string id) => id.StartsWith("eth", StringComparison.Ordinal) &&
        id.All(character => char.IsAsciiLetterOrDigit(character) || character is '_' or '-');
    public static bool IsComplete(NasEthernetInterface value) => SafeId(value.Id) &&
        value.IsDefaultGateway is not null && value.VlanEnabled is not null && value.Mtu is >= 576 and <= 9000 &&
        (value.VlanEnabled != true || value.VlanId is >= 1 and <= 4094) &&
        (value.DhcpEnabled || value.IpAddress is not null && value.SubnetMask is not null &&
            value.Gateway is not null && value.ReportedDns is not null);
    public static bool IsValid(NasEthernetInterface value)
    {
        if (!IsComplete(value)) return false;
        if (value.DhcpEnabled) return true;
        if (!IPv4(value.IpAddress!) || !Mask(value.SubnetMask!) ||
            value.Gateway!.Length > 0 && !IPv4(value.Gateway)) return false;
        return value.ReportedDns!.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).All(IPv4);
    }
    public static bool IPv4(string value) => value.Split('.').Length == 4 &&
        IPAddress.TryParse(value, out var address) && address.AddressFamily == AddressFamily.InterNetwork && address.ToString() == value;
    private static bool Mask(string value)
    {
        if (!IPv4(value)) return false;
        uint mask = 0;
        foreach (var item in IPAddress.Parse(value).GetAddressBytes()) mask = (mask << 8) | item;
        var inverse = ~mask;
        return mask != 0 && (inverse & (inverse + 1)) == 0;
    }
}
