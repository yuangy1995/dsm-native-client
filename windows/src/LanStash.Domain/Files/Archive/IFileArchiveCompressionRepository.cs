namespace LanStash.Domain;

public interface IFileArchiveCompressionRepository
{
    Guid ProfileId { get; }
    FileArchiveCompressionAvailability Availability { get; }

    Task<FileArchiveCompressionOutcome> CompressAsync(
        FileArchiveCompressionRequest request,
        CancellationToken cancellationToken = default);
}
