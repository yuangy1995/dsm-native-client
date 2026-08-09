namespace LanStash.Domain;

public sealed record FileCopyMoveStartTransportResult(
    FileMutationTransportStatus Status,
    string? TaskId = null,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

public enum FileCopyMoveTaskTransportStatus
{
    Running,
    Finished,
    ConfirmedFailure,
    Unsupported,
}

public sealed record FileCopyMoveTaskTransportResult(
    FileCopyMoveTaskTransportStatus Status,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);
