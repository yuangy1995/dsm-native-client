namespace LanStash.Domain;

public interface IFileCopyMoveRepository
{
    Guid ProfileId { get; }
    FileCopyMoveAvailability Availability { get; }
    CrossNasCopyMoveAvailability CrossNasAvailability { get; }

    bool SupportsCopyMoveReview => false;
    Task<IReadOnlyList<FileCopyMovePendingReview>> GetCopyMoveReviewsAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<FileCopyMovePendingReview>>([]);
    Task<FileCopyMoveOutcome?> ReviewCopyMoveAsync(Guid reviewId, CancellationToken cancellationToken = default) =>
        Task.FromResult<FileCopyMoveOutcome?>(null);
    // 仅确认已展示的本地成功证据；不发送 NAS 请求。
    void AcknowledgeCopyMoveReview(Guid reviewId) { }

    Task<FileCopyMoveOutcome> CopyMoveAsync(
        FileCopyMoveRequest request,
        CancellationToken cancellationToken = default);

    Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(
        CrossNasCopyMoveRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default);
}
