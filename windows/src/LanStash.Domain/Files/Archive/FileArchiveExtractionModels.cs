namespace LanStash.Domain;

public sealed record FileArchiveExtractionSource(
    FileItem Item,
    FileArchiveCompressionSourceKind SourceKind = FileArchiveCompressionSourceKind.Local,
    bool CanRead = true);

public sealed record FileArchiveExtractionAvailability(
    bool CanExtract,
    int? ExtractVersion = null,
    int? ListVersion = null)
{
    public bool IsAvailable => CanExtract;
}

public sealed record FileArchiveExtractionRequest(
    Guid ProfileId,
    FileArchiveExtractionSource Source,
    string DestinationFolder);

public sealed record FileArchiveExtractionOutcome(
    MutationResult Result,
    IReadOnlyList<FileItem>? ConfirmedItems = null);
