namespace LanStash.Domain;

public interface IFileRecycleRepository
{
    Guid ProfileId { get; }
    FileRecycleAvailability Availability { get; }

    bool SupportsRecycleReview => false;
    Task<IReadOnlyList<FileRecyclePendingReview>> GetRecycleReviewsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<FileRecyclePendingReview>>([]);
    Task<FileRecycleOutcome?> ReviewRecycleAsync(Guid reviewId, CancellationToken cancellationToken = default) =>
        Task.FromResult<FileRecycleOutcome?>(null);
    void AcknowledgeRecycleReview(Guid reviewId) { }

    Task<FileRecycleOutcome> MoveToRecycleAsync(
        MoveToRecycleRequest request,
        CancellationToken cancellationToken = default);

    Task<FileRecycleOutcome> RestoreFromRecycleAsync(
        RestoreFromRecycleRequest request,
        CancellationToken cancellationToken = default);
}
