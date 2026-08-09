using System.Globalization;
using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public enum VirtualMachineManagerContentState
{
    Loading,
    Empty,
    Error,
    Content,
    Unavailable,
}

public sealed record VirtualMachineItem(VirtualMachineSummary Machine)
{
    public string Id => Machine.Id;
    public string Name => string.IsNullOrWhiteSpace(Machine.Name)
        ? LocalizationService.Current.Get("VirtualMachineManagerUnnamedMachine")
        : Machine.Name.Trim();
    public string StatusText => LocalizationService.Current.Get(Machine.State switch
    {
        VirtualMachineOperationalState.Running => "VirtualMachineManagerStatusRunning",
        VirtualMachineOperationalState.Stopped => "VirtualMachineManagerStatusStopped",
        VirtualMachineOperationalState.Paused => "VirtualMachineManagerStatusPaused",
        VirtualMachineOperationalState.Transitional => "VirtualMachineManagerStatusChanging",
        VirtualMachineOperationalState.Error => "VirtualMachineManagerStatusNeedsAttention",
        _ => "VirtualMachineManagerStatusUnknown",
    });
    public string CpuText => Machine.CpuCount is int count
        ? LocalizationService.Current.Format(
            "VirtualMachineManagerCpuValue",
            count.ToString("N0", CultureInfo.CurrentCulture))
        : UnavailableValue;
    public string MemoryText => FormatBytes(Machine.MemoryBytes);
    public string StorageText => FormatBytes(Machine.StorageBytes);
    public string HostText => string.IsNullOrWhiteSpace(Machine.HostName)
        ? UnavailableValue
        : Machine.HostName.Trim();
    public string AutomationName => LocalizationService.Current.Format(
        "VirtualMachineManagerMachineAutomationName",
        Name,
        StatusText);

    private static string UnavailableValue =>
        LocalizationService.Current.Get("VirtualMachineManagerValueUnavailable");

    internal static string FormatBytes(long? bytes)
    {
        if (bytes is null)
        {
            return UnavailableValue;
        }
        string[] unitKeys =
        [
            "VirtualMachineManagerByteValueB",
            "VirtualMachineManagerByteValueKB",
            "VirtualMachineManagerByteValueMB",
            "VirtualMachineManagerByteValueGB",
            "VirtualMachineManagerByteValueTB",
        ];
        var scaled = (double)Math.Max(0, bytes.Value);
        var unit = 0;
        while (scaled >= 1024 && unit < unitKeys.Length - 1)
        {
            scaled /= 1024;
            unit++;
        }
        var format = unit == 0 ? "N0" : scaled >= 10 ? "N1" : "N2";
        return LocalizationService.Current.Format(
            unitKeys[unit],
            scaled.ToString(format, CultureInfo.CurrentCulture));
    }
}

public sealed record VirtualizationResourceItem(VirtualizationResourceSummary Resource)
{
    public string Id => Resource.Id;
    public string Name => string.IsNullOrWhiteSpace(Resource.Name)
        ? LocalizationService.Current.Get("VirtualMachineManagerUnnamedResource")
        : Resource.Name.Trim();
    public string HealthText => LocalizationService.Current.Get(Resource.Health switch
    {
        VirtualizationResourceHealth.Healthy => "VirtualMachineManagerHealthHealthy",
        VirtualizationResourceHealth.Warning => "VirtualMachineManagerHealthWarning",
        VirtualizationResourceHealth.Error => "VirtualMachineManagerHealthError",
        VirtualizationResourceHealth.Offline => "VirtualMachineManagerHealthOffline",
        _ => "VirtualMachineManagerHealthUnknown",
    });
    public string UsageText => Resource.AllocatedBytes is long allocated &&
        Resource.CapacityBytes is long capacity
            ? LocalizationService.Current.Format(
                "VirtualMachineManagerResourceUsageValue",
                VirtualMachineItem.FormatBytes(allocated),
                VirtualMachineItem.FormatBytes(capacity))
            : LocalizationService.Current.Get("VirtualMachineManagerValueUnavailable");
    public string AutomationName => LocalizationService.Current.Format(
        "VirtualMachineManagerResourceAutomationName",
        Name,
        HealthText);
}
