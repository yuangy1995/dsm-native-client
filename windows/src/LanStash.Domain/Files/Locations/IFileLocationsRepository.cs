namespace LanStash.Domain;

public interface IFileLocationsRepository
{
    Guid ProfileId { get; }
    FileLocationsAvailability Availability { get; }

    Task<FileLocationsSnapshot> LoadSnapshotAsync(
        CancellationToken cancellationToken = default);
}
