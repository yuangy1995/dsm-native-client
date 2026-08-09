namespace LanStash.Domain;

public enum FileMutationTransportStatus
{
    ResponseReceived,
    ConfirmedFailure,
    CancelledBeforeSubmission,
    CancellationRequestedAfterSubmission,
    SubmittedButUnverified,
    Unsupported,
}

public sealed record FileMutationTransportResult(
    FileMutationTransportStatus Status,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

public enum FilePermissionTransportStatus { Allowed, Denied, Cancelled, Failed, Unsupported }

public sealed record FilePermissionTransportResult(
    FilePermissionTransportStatus Status,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);
