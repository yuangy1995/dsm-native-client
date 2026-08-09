namespace LanStash.Domain;

public sealed record FileRecycleStartTransportResult(
    FileMutationTransportStatus Status,
    string? TaskId = null,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

public enum FileRecycleTaskTransportStatus
{
    Running,
    Finished,
    ConfirmedFailure,
    Unsupported,
}

public sealed record FileRecycleTaskTransportResult(
    FileRecycleTaskTransportStatus Status,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);
