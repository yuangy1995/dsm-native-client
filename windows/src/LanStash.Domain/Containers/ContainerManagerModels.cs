namespace LanStash.Domain;

public enum ContainerManagerAvailabilityStatus
{
    InternalObserved,
    Unavailable,
}

public enum ContainerManagerReadFeature
{
    Containers,
    Images,
    Networks,
    Projects,
    Events,
}

public sealed record ContainerManagerAvailability(
    ContainerManagerAvailabilityStatus Status,
    IReadOnlySet<ContainerManagerReadFeature> Features);

public enum ContainerManagerSectionStatus
{
    Available,
    Unavailable,
    Failed,
}

public sealed record ContainerManagerSection<T>(
    ContainerManagerSectionStatus Status,
    IReadOnlyList<T> Items)
{
    public static ContainerManagerSection<T> Available(IReadOnlyList<T> items) =>
        new(ContainerManagerSectionStatus.Available, items);

    public static ContainerManagerSection<T> Unavailable { get; } =
        new(ContainerManagerSectionStatus.Unavailable, Array.Empty<T>());

    public static ContainerManagerSection<T> Failed { get; } =
        new(ContainerManagerSectionStatus.Failed, Array.Empty<T>());
}

public enum ContainerOperationalState
{
    Running,
    Stopped,
    Attention,
    Unknown,
}

public sealed record ContainerSummary(
    string Id,
    string Name,
    ContainerOperationalState State,
    string? Image);

public enum ContainerResourceKind
{
    Image,
    Network,
    Project,
}

public sealed record ContainerResourceSummary(
    string Id,
    string Name,
    ContainerResourceKind Kind,
    ContainerOperationalState State);

public enum ServiceEventLevel
{
    Information,
    Warning,
    Error,
    Unknown,
}

public sealed record ServiceEventSummary(
    string Id,
    DateTimeOffset? OccurredAt,
    ServiceEventLevel Level);

public sealed record ContainerManagerSnapshot(
    Guid ProfileId,
    ContainerManagerSection<ContainerSummary> Containers,
    ContainerManagerSection<ContainerResourceSummary> Images,
    ContainerManagerSection<ContainerResourceSummary> Networks,
    ContainerManagerSection<ContainerResourceSummary> Projects,
    ContainerManagerSection<ServiceEventSummary> Events);
