namespace LanStash.Domain;

public interface IFileRecycleRepository
{
    Guid ProfileId { get; }
    FileRecycleAvailability Availability { get; }

    Task<FileRecycleOutcome> MoveToRecycleAsync(
        MoveToRecycleRequest request,
        CancellationToken cancellationToken = default);

    Task<FileRecycleOutcome> RestoreFromRecycleAsync(
        RestoreFromRecycleRequest request,
        CancellationToken cancellationToken = default);
}
