namespace LanStash.Domain;

public interface IDownloadStationRepository
{
    Guid ProfileId { get; }
    DownloadStationAvailability Availability { get; }

    bool CanFinishIncomplete => false;
    Task<IReadOnlyList<DownloadActionInfo>> LoadDownloadActionsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<DownloadActionInfo>>([]);
    Task<DownloadActionInfo> StartDownloadActionAsync(DownloadTaskActionRequest request, CancellationToken cancellationToken = default) =>
        Task.FromException<DownloadActionInfo>(new NotSupportedException("download.actions.unavailable"));
    Task<DownloadActionInfo> ReviewDownloadActionAsync(Guid id, CancellationToken cancellationToken = default) =>
        Task.FromException<DownloadActionInfo>(new NotSupportedException("download.actions.unavailable"));
    Task<DownloadActionInfo> ContinueDownloadActionAsync(Guid id, CancellationToken cancellationToken = default) =>
        Task.FromException<DownloadActionInfo>(new NotSupportedException("download.actions.unavailable"));
    Task<DownloadActionInfo> CancelDownloadActionRemainderAsync(Guid id, CancellationToken cancellationToken = default) =>
        Task.FromException<DownloadActionInfo>(new NotSupportedException("download.actions.unavailable"));
    Task<DownloadActionInfo> RefreshRssSiteAsync(DownloadRssSite site, CancellationToken cancellationToken = default) =>
        Task.FromException<DownloadActionInfo>(new NotSupportedException("download.rss.unavailable"));

    Task<DownloadTaskDetails> LoadTaskDetailsAsync(string taskId, CancellationToken cancellationToken = default) =>
        Task.FromException<DownloadTaskDetails>(new NotSupportedException("download.details.unavailable"));
    Task<IReadOnlyList<DownloadRssSite>> ListRssSitesAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<DownloadRssSite>>(new NotSupportedException("download.rss.unavailable"));
    Task<IReadOnlyList<DownloadRssFeed>> ListRssFeedsAsync(int siteId, CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<DownloadRssFeed>>(new NotSupportedException("download.rss.unavailable"));

    Task<DownloadSettingsSnapshot> LoadSettingsAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<DownloadSettingsSnapshot>(new NotSupportedException("download.settings.unavailable"));

    Task<DownloadSettingsSaveOutcome> SaveSettingsAsync(DownloadSettingsSaveRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(new DownloadSettingsSaveOutcome(new(1, MutationResultStatus.Unsupported, "downloadSettings", false, false,
            new(0, 1, 0), MutationErrorCategory.Unsupported), null, DownloadSettingsComponentState.Rejected, DownloadSettingsComponentState.Unchanged));

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

    Task<DownloadBtSearchCatalog> LoadBtSearchCatalogAsync(
        CancellationToken cancellationToken = default) =>
        throw new NotSupportedException("Download Station BT search is not supported.");

    Task<IReadOnlyList<DownloadBtSearchResult>> SearchBtAsync(
        DownloadBtSearchRequest request,
        CancellationToken cancellationToken = default) =>
        throw new NotSupportedException("Download Station BT search is not supported.");

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
