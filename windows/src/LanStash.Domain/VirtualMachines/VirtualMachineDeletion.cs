namespace LanStash.Domain;

public sealed record VirtualMachineDeleteRequest(Guid ProfileId, VirtualMachineSummary Baseline, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(VirtualMachineDeleteRequest);
}
public sealed record VirtualMachineDeleteRecovery(string Id, string Name)
{
    public override string ToString() => nameof(VirtualMachineDeleteRecovery);
}
public static class VirtualMachineDeletionRules
{
    public static bool CanRequest(VirtualMachineSummary target) => target is not null &&
        VirtualMachinePowerRules.ValidId(target.Id) && !string.IsNullOrWhiteSpace(target.Name) && !target.Name.Any(char.IsControl) &&
        target.State == VirtualMachineOperationalState.Stopped;
}

public sealed record VirtualMachineImageDeleteRequest(Guid ProfileId, VirtualizationResourceSummary Baseline, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(VirtualMachineImageDeleteRequest);
}
public static class VirtualMachineImageDeletionRules
{
    public static bool CanRequest(VirtualizationResourceSummary target) => target is { Kind: VirtualizationResourceKind.Image, Type: "disk" or "iso" or "vdsm" } &&
        VirtualMachinePowerRules.ValidId(target.Id) && !string.IsNullOrWhiteSpace(target.Name) && !target.Name.Any(char.IsControl);
}
