namespace LanStash.Domain;

public enum VirtualMachineManagerAvailabilityStatus
{
    Available,
    Unavailable,
}

public enum VirtualMachineManagerReadFeature
{
    Machines,
    Hosts,
    Storages,
    Networks,
    Images,
}

public sealed record VirtualMachineManagerAvailability(
    VirtualMachineManagerAvailabilityStatus Status,
    IReadOnlySet<VirtualMachineManagerReadFeature> Features);

public enum VirtualMachineManagerSectionStatus
{
    Available,
    Unavailable,
    Failed,
}

public sealed record VirtualMachineManagerSection<T>(
    VirtualMachineManagerSectionStatus Status,
    IReadOnlyList<T> Items)
{
    public static VirtualMachineManagerSection<T> Available(IReadOnlyList<T> items) =>
        new(VirtualMachineManagerSectionStatus.Available, items);

    public static VirtualMachineManagerSection<T> Unavailable { get; } =
        new(VirtualMachineManagerSectionStatus.Unavailable, Array.Empty<T>());

    public static VirtualMachineManagerSection<T> Failed { get; } =
        new(VirtualMachineManagerSectionStatus.Failed, Array.Empty<T>());
}

public enum VirtualMachineOperationalState
{
    Running,
    Stopped,
    Paused,
    Transitional,
    Error,
    Unknown,
}

public sealed record VirtualMachineSummary(
    string Id,
    string Name,
    VirtualMachineOperationalState State,
    int? CpuCount,
    long? MemoryBytes,
    long? StorageBytes,
    string? HostId,
    string? HostName);

public enum VirtualizationResourceKind
{
    Host,
    Storage,
    Network,
    Image,
}

public enum VirtualizationResourceHealth
{
    Healthy,
    Warning,
    Error,
    Offline,
    Unknown,
}

public sealed record VirtualizationResourceSummary(
    string Id,
    string Name,
    VirtualizationResourceKind Kind,
    VirtualizationResourceHealth Health,
    long? AllocatedBytes = null,
    long? CapacityBytes = null,
    string? Type = null);

public sealed record VirtualMachineManagerSnapshot(
    Guid ProfileId,
    VirtualMachineManagerSection<VirtualMachineSummary> Machines,
    VirtualMachineManagerSection<VirtualizationResourceSummary> Hosts,
    VirtualMachineManagerSection<VirtualizationResourceSummary> Storages,
    VirtualMachineManagerSection<VirtualizationResourceSummary> Networks,
    VirtualMachineManagerSection<VirtualizationResourceSummary> Images);
