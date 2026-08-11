namespace LanStash.Domain;

public sealed record SystemOverview(
    string ServerName,
    string? Model,
    string? Version,
    long? UptimeSeconds,
    string? CpuModel,
    long? MemoryBytes);

public sealed record NasSettingsSnapshot(
    SystemOverview? System,
    IReadOnlyList<ResourceItem> Volumes,
    IReadOnlyList<ResourceItem> Pools,
    IReadOnlyList<ResourceItem> Disks,
    IReadOnlyList<ResourceItem> Packages,
    IReadOnlyList<ResourceItem> Accounts,
    IReadOnlyList<ResourceItem> Groups,
    IReadOnlyList<LogEntry> Logs,
    IReadOnlyList<ResourceItem> Connections,
    IReadOnlyList<ResourceItem> Networks,
    IReadOnlyList<ResourceItem> Security);

public enum NasDetailsReadFeature
{
    SystemOverview,
    StorageHealth,
    SystemUpdate,
    ShareAccess,
    SystemActivity,
    Packages,
    ScheduledTasks,
    Logs,
    Connections,
}

public sealed record NasSystemHealthSummary(
    string? Model,
    string? Version,
    long? UptimeSeconds,
    string? CpuModel,
    int? CpuCoreCount,
    int? CpuClockMhz,
    long? MemoryBytes,
    double? TemperatureCelsius,
    bool HasTemperatureWarning);

public enum NasStorageItemKind
{
    Pool,
    Volume,
    Drive,
}

public sealed record NasStorageHealthSummary(
    string Id,
    NasStorageItemKind Kind,
    int Ordinal,
    string? Status,
    ResourceState State,
    long? TotalBytes,
    long? UsedBytes = null,
    string? FileSystem = null,
    string? RaidType = null,
    string? SmartStatus = null,
    double? TemperatureCelsius = null,
    bool IsSsd = false,
    bool IsEncrypted = false);

public sealed record NasSystemUpdateSummary(
    bool IsUpdateAvailable,
    string? CurrentVersion,
    string? LatestVersion,
    string? ReleaseNotes);

public enum NasShareAccessLevel
{
    ReadWrite,
    ReadOnly,
    Unknown,
}

public sealed record NasShareAccessSummary(
    string Id,
    string Name,
    NasShareAccessLevel AccessLevel,
    bool CanDelete);

public sealed record NasSystemProcessSummary(
    string Id,
    int ProcessId,
    string Name,
    string? Status,
    string? GroupId);

public sealed record NasProcessGroupSummary(
    string Id,
    string Name,
    string? Status,
    int? ProcessCount);

public sealed record NasSystemActivitySummary(
    IReadOnlyList<NasSystemProcessSummary> Processes,
    IReadOnlyList<NasProcessGroupSummary> Groups,
    bool AreGroupsUnavailable);

public enum NasDetailsAvailabilityStatus
{
    Available,
    Unavailable,
}

public sealed record NasDetailsAvailability(
    NasDetailsAvailabilityStatus Status,
    IReadOnlySet<NasDetailsReadFeature> Features);

public enum NasDetailsSectionStatus
{
    Available,
    Unavailable,
    Failed,
}

public sealed record NasDetailsSection<T>(
    NasDetailsSectionStatus Status,
    IReadOnlyList<T> Items,
    bool IsTruncated = false,
    string? DiagnosticTag = null);

public sealed record NasPackageSummary(
    string Id,
    string Name,
    string? Version,
    string Status,
    ResourceState State);

public sealed record NasScheduledTaskSummary(
    string Id,
    string Name,
    bool? IsEnabled,
    string? NextRun);

public sealed record NasLogSummary(
    string Id,
    DateTimeOffset? Time,
    string Source,
    string Level);

public sealed record NasConnectionSummary(
    string Id,
    string Protocol,
    string Type,
    DateTimeOffset? ConnectedAt,
    bool IsCurrent);

public sealed record NasDetailsSnapshot(
    Guid ProfileId,
    NasDetailsSection<NasSystemHealthSummary> SystemOverview,
    NasDetailsSection<NasStorageHealthSummary> StorageHealth,
    NasDetailsSection<NasSystemUpdateSummary> SystemUpdate,
    NasDetailsSection<NasShareAccessSummary> ShareAccess,
    NasDetailsSection<NasSystemActivitySummary> SystemActivity,
    NasDetailsSection<NasPackageSummary> Packages,
    NasDetailsSection<NasScheduledTaskSummary> ScheduledTasks,
    NasDetailsSection<NasLogSummary> Logs,
    NasDetailsSection<NasConnectionSummary> Connections);

public interface INasDetailsRepository
{
    Guid ProfileId { get; }
    NasDetailsAvailability Availability { get; }

    Task<NasDetailsSnapshot> LoadDetailsAsync(
        CancellationToken cancellationToken = default);
}
