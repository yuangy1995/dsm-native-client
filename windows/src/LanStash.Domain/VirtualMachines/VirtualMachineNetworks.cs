namespace LanStash.Domain;

public sealed record VirtualMachineNetworkInterface(string HostId, string Id);
public sealed record VirtualMachineNetworkGuest(string Id, string Name, bool Running, bool PrefersSriov, bool UsesVirtualFunction);
public sealed record VirtualMachineNetwork(string Id, string Name, string Type, string HostId, int VlanId,
    IReadOnlyList<VirtualMachineNetworkInterface> Interfaces, IReadOnlyList<VirtualMachineNetworkGuest> Guests)
{
    public override string ToString() => nameof(VirtualMachineNetwork);
}
public sealed record VirtualMachineNetworkInventory(bool IsFrozen, IReadOnlyList<VirtualMachineNetwork> Networks);
public enum VirtualMachineNetworkAction { Rename, Delete }
public sealed record VirtualMachineNetworkRequest(Guid ProfileId, VirtualMachineNetwork Baseline,
    VirtualMachineNetworkAction Action, string? NewName, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(VirtualMachineNetworkRequest);
}
public sealed record VirtualMachineNetworkRecovery(string Id, string Name, VirtualMachineNetworkAction Action)
{
    public override string ToString() => nameof(VirtualMachineNetworkRecovery);
}

public static class VirtualMachineNetworkRules
{
    public static bool ValidName(string? name) => !string.IsNullOrWhiteSpace(name) && name == name.Trim() &&
        name.Length <= 127 && !name.Any(char.IsControl);
    public static VirtualMachineNetwork Freeze(VirtualMachineNetwork value) => value with
    {
        Interfaces = Array.AsReadOnly(value.Interfaces.OrderBy(item => item.HostId, StringComparer.Ordinal).ThenBy(item => item.Id, StringComparer.Ordinal).ToArray()),
        Guests = Array.AsReadOnly(value.Guests.OrderBy(item => item.Id, StringComparer.Ordinal).ToArray()),
    };
    public static bool Same(VirtualMachineNetwork left, VirtualMachineNetwork right) =>
        left.Id == right.Id && left.Name == right.Name && left.Type == right.Type && left.HostId == right.HostId &&
        left.VlanId == right.VlanId && left.Interfaces.SequenceEqual(right.Interfaces) && left.Guests.SequenceEqual(right.Guests);
    public static bool Valid(VirtualMachineNetwork network) => network is not null && VirtualMachinePowerRules.ValidId(network.Id) &&
        ValidName(network.Name) && network.Type is "external" or "private" && network.VlanId is >= 0 and <= 4094 &&
        network.HostId is not null && (network.Type != "private" || VirtualMachinePowerRules.ValidId(network.HostId)) &&
        network.Interfaces is not null && network.Guests is not null &&
        network.Interfaces.All(item => item is not null && VirtualMachinePowerRules.ValidId(item.HostId) && VirtualMachinePowerRules.ValidId(item.Id)) &&
        network.Interfaces.Distinct().Count() == network.Interfaces.Count &&
        network.Guests.All(item => item is not null && VirtualMachinePowerRules.ValidId(item.Id) && !string.IsNullOrWhiteSpace(item.Name)) &&
        network.Guests.Select(item => item.Id).Distinct(StringComparer.Ordinal).Count() == network.Guests.Count;
}
