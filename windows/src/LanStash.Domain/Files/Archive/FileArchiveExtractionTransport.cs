namespace LanStash.Domain;

public sealed record FileArchiveExtractionListedItem(
    string Name,
    bool IsDirectory);

public sealed record FileArchiveExtractionStartTransportResult(
    FileMutationTransportStatus Status,
    string? TaskId = null,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

public enum FileArchiveExtractionTaskTransportStatus
{
    Running,
    Finished,
    ConfirmedFailure,
    Unsupported,
}

public sealed record FileArchiveExtractionTaskTransportResult(
    FileArchiveExtractionTaskTransportStatus Status,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

public sealed record FileArchiveExtractionStopTransportResult(
    FileMutationTransportStatus Status,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);
