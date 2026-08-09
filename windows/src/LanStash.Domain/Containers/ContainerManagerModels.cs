namespace LanStash.Domain;

public enum ContainerManagerAvailabilityStatus
{
    InternalObserved,
    Unavailable,
}

public sealed record ContainerManagerAvailability(
    ContainerManagerAvailabilityStatus Status);

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

public sealed record ContainerManagerSnapshot(
    Guid ProfileId,
    IReadOnlyList<ContainerSummary> Containers);
