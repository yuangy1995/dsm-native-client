namespace LanStash.Domain;

public interface IContainerManagerRepository
{
    Guid ProfileId { get; }
    ContainerManagerAvailability Availability { get; }

    Task<ContainerManagerSnapshot> LoadSnapshotAsync(
        CancellationToken cancellationToken = default);
}
