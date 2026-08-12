namespace LanStash.Domain;

public enum FileArchiveCompressionSourceKind
{
    Local,
    Remote,
    Virtual,
    Recycle,
}

public sealed record FileArchiveCompressionSource(
    FileItem Item,
    FileArchiveCompressionSourceKind SourceKind = FileArchiveCompressionSourceKind.Local,
    bool CanRead = true);

public sealed record FileArchiveCompressionAvailability(
    bool CanCompress,
    int? CompressVersion = null,
    int? ListVersion = null,
    int? CheckPermissionVersion = null)
{
    public bool IsAvailable => CanCompress;
}

public sealed record FileArchiveCompressionRequest(
    Guid ProfileId,
    IReadOnlyList<FileArchiveCompressionSource> Sources,
    string DestinationName);

public sealed record FileArchiveCompressionOutcome(
    MutationResult Result,
    FileItem? ConfirmedItem = null);
