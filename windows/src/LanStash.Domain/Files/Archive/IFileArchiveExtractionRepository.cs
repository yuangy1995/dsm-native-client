namespace LanStash.Domain;

public interface IFileArchiveExtractionRepository
{
    Guid ProfileId { get; }
    FileArchiveExtractionAvailability Availability { get; }

    Task<FileArchiveExtractionOutcome> ExtractAsync(
        FileArchiveExtractionRequest request,
        CancellationToken cancellationToken = default);
}
