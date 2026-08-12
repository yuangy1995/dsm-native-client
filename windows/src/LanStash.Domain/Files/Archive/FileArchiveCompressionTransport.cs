namespace LanStash.Domain;

public sealed record FileArchiveCompressionStartTransportResult(
    FileMutationTransportStatus Status,
    string? TaskId = null,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

public enum FileArchiveCompressionTaskTransportStatus
{
    Running,
    Finished,
    ConfirmedFailure,
    Unsupported,
}

public sealed record FileArchiveCompressionTaskTransportResult(
    FileArchiveCompressionTaskTransportStatus Status,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

public sealed record FileArchiveCompressionStopTransportResult(
    FileMutationTransportStatus Status,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);
