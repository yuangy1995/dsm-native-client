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
    Protection,
    Events,
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

public enum VirtualMachineApiSource { Public, Internal }

public sealed record VirtualMachineSummary(
    string Id,
    string Name,
    VirtualMachineOperationalState State,
    int? CpuCount,
    long? MemoryBytes,
    long? StorageBytes,
    string? HostId,
    string? HostName)
{
    public VirtualMachineApiSource Source { get; init; } = VirtualMachineApiSource.Public;
}

public enum VirtualizationResourceKind
{
    Host,
    Storage,
    Network,
    Image,
    ProtectionPlan,
    ProtectionSchedule,
    ProtectionRetention,
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
    string? Type = null)
{
    public VirtualMachineApiSource Source { get; init; } = VirtualMachineApiSource.Public;
    public string? Detail { get; init; }
    public bool? IsFrozen { get; init; }
    public bool? IsInUse { get; init; }
    public IReadOnlyList<VirtualMachineImageReplica>? ImageReplicas { get; init; }
}

public sealed record VirtualMachineImageReplica(string StorageId, string HostId, string Status, string StatusType)
{
    public override string ToString() => nameof(VirtualMachineImageReplica);
}

public sealed record VirtualMachineManagerSnapshot(
    Guid ProfileId,
    VirtualMachineManagerSection<VirtualMachineSummary> Machines,
    VirtualMachineManagerSection<VirtualizationResourceSummary> Hosts,
    VirtualMachineManagerSection<VirtualizationResourceSummary> Storages,
    VirtualMachineManagerSection<VirtualizationResourceSummary> Networks,
    VirtualMachineManagerSection<VirtualizationResourceSummary> Images,
    VirtualMachineManagerSection<VirtualizationResourceSummary> Protection,
    VirtualMachineManagerSection<ServiceEventSummary> Events);
