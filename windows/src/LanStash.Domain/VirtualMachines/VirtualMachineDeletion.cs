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
        VirtualMachinePowerRules.ValidId(target.Id) && Enum.IsDefined(target.Source) && !string.IsNullOrWhiteSpace(target.Name) && !target.Name.Any(char.IsControl) &&
        target.State == VirtualMachineOperationalState.Stopped;
}

public sealed record VirtualMachineImageDeleteRequest(Guid ProfileId, VirtualizationResourceSummary Baseline, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(VirtualMachineImageDeleteRequest);
}
public static class VirtualMachineImageDeletionRules
{
    public static bool SameSnapshot(VirtualizationResourceSummary left, VirtualizationResourceSummary right) =>
        (left with { Detail = null, ImageReplicas = null }) == (right with { Detail = null, ImageReplicas = null }) &&
        (left.ImageReplicas is null ? right.ImageReplicas is null : right.ImageReplicas is not null &&
            left.ImageReplicas.OrderBy(item => item.StorageId, StringComparer.Ordinal).ThenBy(item => item.HostId, StringComparer.Ordinal)
                .SequenceEqual(right.ImageReplicas.OrderBy(item => item.StorageId, StringComparer.Ordinal).ThenBy(item => item.HostId, StringComparer.Ordinal)));

    public static bool CanRequest(VirtualizationResourceSummary target) => target is { Kind: VirtualizationResourceKind.Image, Type: "disk" or "iso" or "vdsm" } &&
        VirtualMachinePowerRules.ValidId(target.Id) && Enum.IsDefined(target.Source) && !string.IsNullOrWhiteSpace(target.Name) && !target.Name.Any(char.IsControl) &&
        (target.Source == VirtualMachineApiSource.Public || target.IsFrozen == false && target.ImageReplicas is { Count: > 0 } replicas &&
            replicas.All(item => item.Status == "online" && item.StatusType == "healthy") && (target.Type != "iso" || target.IsInUse == false));
}
