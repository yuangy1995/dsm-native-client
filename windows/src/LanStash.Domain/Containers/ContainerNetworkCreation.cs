using System.Globalization;
using System.Net;
using System.Net.Sockets;

namespace LanStash.Domain;

public enum ContainerNetworkValidationIssue { None, Name, Ipv4, Ipv6, OutsideSubnet }
public sealed record ContainerNetworkCreation(string Name, bool UsesManualIpv4 = false, string Subnet = "", string IpRange = "", string Gateway = "",
    bool IsIpv6Enabled = false, string Ipv6Subnet = "", string Ipv6Range = "", string Ipv6Gateway = "", bool DisableMasquerade = false)
{
    public ContainerNetworkValidationIssue ValidationIssue
    {
        get
        {
            if (string.IsNullOrEmpty(Name) || !char.IsAsciiLetterOrDigit(Name[0]) || Name.Any(c => !char.IsAsciiLetterOrDigit(c) && !"_.-".Contains(c))) return ContainerNetworkValidationIssue.Name;
            if (UsesManualIpv4 && ValidateNetwork(Subnet, IpRange, Gateway, false) is var v4 && v4 != ContainerNetworkValidationIssue.None) return v4;
            if (IsIpv6Enabled && ValidateNetwork(Ipv6Subnet, Ipv6Range, Ipv6Gateway, true) is var v6 && v6 != ContainerNetworkValidationIssue.None) return v6;
            return ContainerNetworkValidationIssue.None;
        }
    }
    public override string ToString() => nameof(ContainerNetworkCreation);
    private static ContainerNetworkValidationIssue ValidateNetwork(string subnet, string range, string gateway, bool ipv6)
    {
        var invalid = ipv6 ? ContainerNetworkValidationIssue.Ipv6 : ContainerNetworkValidationIssue.Ipv4;
        if (range is null) return invalid;
        var network = Cidr(subnet, ipv6); var address = Address(gateway, ipv6);
        if (network is null || address is null || !ipv6 && address[0] is not (>= 1 and <= 223)) return invalid;
        if (!Contains(address, network.Value)) return ContainerNetworkValidationIssue.OutsideSubnet;
        if (!string.IsNullOrEmpty(range))
        {
            var pool = Cidr(range, ipv6);
            if (pool is null) return invalid;
            if (pool.Value.Prefix < network.Value.Prefix || !Contains(pool.Value.Bytes, network.Value)) return ContainerNetworkValidationIssue.OutsideSubnet;
        }
        return ContainerNetworkValidationIssue.None;
    }
    private static byte[]? Address(string text, bool ipv6)
    {
        if (string.IsNullOrEmpty(text) || text.Any(char.IsWhiteSpace) || text.IndexOfAny(['%', '[', ']']) >= 0) return null;
        if (!ipv6)
        {
            var parts = text.Split('.');
            if (parts.Length != 4 || parts.Any(part => !byte.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out var value) || value.ToString(CultureInfo.InvariantCulture) != part)) return null;
        }
        return IPAddress.TryParse(text, out var address) && address.AddressFamily == (ipv6 ? AddressFamily.InterNetworkV6 : AddressFamily.InterNetwork) ? address.GetAddressBytes() : null;
    }
    private static (byte[] Bytes, int Prefix)? Cidr(string text, bool ipv6)
    {
        if (text is null) return null;
        var parts = text.Split('/');
        if (parts.Length != 2 || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var prefix) ||
            prefix.ToString(CultureInfo.InvariantCulture) != parts[1] || prefix > (ipv6 ? 128 : 32) || Address(parts[0], ipv6) is not { } bytes) return null;
        return (bytes, prefix);
    }
    private static bool Contains(byte[] address, (byte[] Bytes, int Prefix) network)
    {
        for (var index = 0; index < address.Length; index++)
        {
            var bits = Math.Clamp(network.Prefix - index * 8, 0, 8); var mask = bits == 0 ? 0 : (255 << (8 - bits)) & 255;
            if ((address[index] & mask) != (network.Bytes[index] & mask)) return false;
        }
        return true;
    }
    public static bool EquivalentIpv4Cidr(string left, string right)
    {
        var a = Cidr(left, false); var b = Cidr(right, false);
        return a is not null && b is not null && a.Value.Prefix == b.Value.Prefix && Contains(a.Value.Bytes, b.Value);
    }
}
public sealed record ContainerNetworkCreateRequest(Guid ProfileId, ContainerNetworkCreation Configuration, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(ContainerNetworkCreateRequest);
}
public sealed record ContainerNetworkCreationRecovery(string Name)
{
    public override string ToString() => nameof(ContainerNetworkCreationRecovery);
}
