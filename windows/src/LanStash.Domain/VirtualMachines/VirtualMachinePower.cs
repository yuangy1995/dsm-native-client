namespace LanStash.Domain;

public enum VirtualMachinePowerAction { PowerOn, Shutdown, PowerOff }

public sealed record VirtualMachinePowerRequest(Guid ProfileId, VirtualMachineSummary Baseline,
    VirtualMachinePowerAction Action, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(VirtualMachinePowerRequest);
}
public sealed record VirtualMachinePowerRecovery(string Id, string Name, VirtualMachinePowerAction Action)
{
    public override string ToString() => nameof(VirtualMachinePowerRecovery);
}
public static class VirtualMachinePowerRules
{
    public static bool CanRequest(VirtualMachineSummary target, VirtualMachinePowerAction action) => target is not null &&
        ValidId(target.Id) && !string.IsNullOrWhiteSpace(target.Name) && !target.Name.Any(char.IsControl) && action switch
        {
            VirtualMachinePowerAction.PowerOn => target.State == VirtualMachineOperationalState.Stopped,
            VirtualMachinePowerAction.Shutdown or VirtualMachinePowerAction.PowerOff => target.State == VirtualMachineOperationalState.Running,
            _ => false
        };
    public static bool ValidId(string? id) => !string.IsNullOrWhiteSpace(id) && id == id.Trim() &&
        !id.Any(char.IsControl) && id.IndexOfAny([',', '\\']) < 0;
}
