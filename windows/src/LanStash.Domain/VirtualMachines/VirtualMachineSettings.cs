namespace LanStash.Domain;

public enum VirtualMachineAutoStart { Off = 0, PreviousState = 1, On = 2 }
public sealed record VirtualMachineConfiguration(string Name, string Description, int CpuCount, int MemoryMiB, VirtualMachineAutoStart AutoStart)
{
    public int? CpuWeight { get; init; }
    public override string ToString() => nameof(VirtualMachineConfiguration);
}
public sealed record VirtualMachineSettings(string Id, VirtualMachineOperationalState State, VirtualMachineConfiguration Configuration)
{
    public override string ToString() => nameof(VirtualMachineSettings);
}
public sealed record VirtualMachineSettingsRequest(Guid ProfileId, VirtualMachineSettings Baseline,
    VirtualMachineConfiguration Desired, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(VirtualMachineSettingsRequest);
}
public sealed record VirtualMachineSettingsRecovery(string Id, string Name)
{
    public override string ToString() => nameof(VirtualMachineSettingsRecovery);
}
public enum VirtualMachineSettingsValidation { None, Name, Description, Cpu, Memory, AutoStart, RequiresShutdown, State, Priority }
public static class VirtualMachineSettingsRules
{
    public static VirtualMachineSettingsValidation Validate(VirtualMachineSettings baseline, VirtualMachineConfiguration desired)
    {
        if (baseline is null || desired is null || baseline.Configuration is null || !VirtualMachinePowerRules.ValidId(baseline.Id) ||
            baseline.State is not (VirtualMachineOperationalState.Stopped or VirtualMachineOperationalState.Running)) return VirtualMachineSettingsValidation.State;
        if (desired.Name != baseline.Configuration.Name && (string.IsNullOrWhiteSpace(desired.Name) || desired.Name != desired.Name.Trim() || desired.Name.Length > 255 || desired.Name.Any(char.IsControl))) return VirtualMachineSettingsValidation.Name;
        if (desired.Description != baseline.Configuration.Description && (desired.Description is null || desired.Description.Length > 1024 || desired.Description.Contains('\0'))) return VirtualMachineSettingsValidation.Description;
        if (!Enum.IsDefined(desired.AutoStart)) return VirtualMachineSettingsValidation.AutoStart;
        if (desired.CpuWeight != baseline.Configuration.CpuWeight &&
            (baseline.Configuration.CpuWeight is null || desired.CpuWeight is not (8 or 64 or 256 or 512 or 1024))) return VirtualMachineSettingsValidation.Priority;
        if (desired.CpuCount != baseline.Configuration.CpuCount && desired.CpuCount is < 1 or > 64) return VirtualMachineSettingsValidation.Cpu;
        if (desired.MemoryMiB != baseline.Configuration.MemoryMiB && desired.MemoryMiB is < 128 or > 1048576) return VirtualMachineSettingsValidation.Memory;
        if (baseline.State != VirtualMachineOperationalState.Stopped && (desired.CpuCount != baseline.Configuration.CpuCount || desired.MemoryMiB != baseline.Configuration.MemoryMiB))
            return VirtualMachineSettingsValidation.RequiresShutdown;
        return VirtualMachineSettingsValidation.None;
    }
}
