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
