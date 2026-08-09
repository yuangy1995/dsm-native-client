namespace LanStash.Domain;

public interface IDownloadStationRepository
{
    Guid ProfileId { get; }
    DownloadStationAvailability Availability { get; }

    Task<DownloadTaskPage> ListTasksAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken = default);

    Task<DownloadStationSnapshot> LoadSnapshotAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken = default);
}
