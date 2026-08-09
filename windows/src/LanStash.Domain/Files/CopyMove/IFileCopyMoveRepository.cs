namespace LanStash.Domain;

public interface IFileCopyMoveRepository
{
    Guid ProfileId { get; }
    FileCopyMoveAvailability Availability { get; }

    Task<FileCopyMoveOutcome> CopyMoveAsync(
        FileCopyMoveRequest request,
        CancellationToken cancellationToken = default);
}
