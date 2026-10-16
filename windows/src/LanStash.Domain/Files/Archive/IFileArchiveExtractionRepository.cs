namespace LanStash.Domain;

public interface IFileArchiveExtractionRepository
{
    Guid ProfileId { get; }
    FileArchiveExtractionAvailability Availability { get; }

    Task<FileArchiveExtractionPreview> PreviewAsync(
        FileArchiveExtractionRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromException<FileArchiveExtractionPreview>(new NotSupportedException());

    Task<FileArchiveExtractionOutcome> ExtractAsync(
        FileArchiveExtractionRequest request,
        CancellationToken cancellationToken = default);
}
