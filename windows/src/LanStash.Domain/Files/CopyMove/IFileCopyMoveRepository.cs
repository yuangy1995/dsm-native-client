namespace LanStash.Domain;

public interface IFileCopyMoveRepository
{
    Guid ProfileId { get; }
    FileCopyMoveAvailability Availability { get; }
    CrossNasCopyMoveAvailability CrossNasAvailability { get; }

    Task<FileCopyMoveOutcome> CopyMoveAsync(
        FileCopyMoveRequest request,
        CancellationToken cancellationToken = default);

    Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(
        CrossNasCopyMoveRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default);
}
