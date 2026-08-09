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

    Task<DownloadTaskControlOutcome> ControlTaskAsync(
        DownloadTaskControlRequest request,
        CancellationToken cancellationToken = default);

    Task<DownloadTaskCreateOutcome> CreateTaskAsync(
        DownloadTaskCreateRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new DownloadTaskCreateOutcome(
            new MutationResult(
                1,
                MutationResultStatus.Unsupported,
                "downloadCreate",
                submitted: false,
                requiresRefresh: false,
                new MutationResultCounts(0, 1, 0),
                MutationErrorCategory.Unsupported,
                "download-station.create.unsupported",
                "download-station.create.unsupported"),
            null,
            null));

    Task<DownloadTaskCreateOutcome> CreateTaskFromFileAsync(
        DownloadTaskFileCreateRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new DownloadTaskCreateOutcome(
            new MutationResult(
                1,
                MutationResultStatus.Unsupported,
                "downloadCreate",
                submitted: false,
                requiresRefresh: false,
                new MutationResultCounts(0, 1, 0),
                MutationErrorCategory.Unsupported,
                "download-station.create.unsupported",
                "download-station.create.unsupported"),
            null,
            null));

    Task<DownloadTaskDeleteOutcome> DeleteTaskAsync(
        DownloadTaskDeleteRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new DownloadTaskDeleteOutcome(
            new MutationResult(
                1,
                MutationResultStatus.Unsupported,
                "downloadTaskDelete",
                submitted: false,
                requiresRefresh: false,
                new MutationResultCounts(0, 1, 0),
                MutationErrorCategory.Unsupported,
                "download-station.delete.unsupported",
                "download-station.delete.unsupported"),
            request.Task.Id));
}
