using System.Text.Json.Nodes;

namespace LanStash.Domain;

public enum FileShareLinkTransportStatus
{
    ResponseReceived,
    ConfirmedFailure,
    CancelledBeforeSubmission,
    CancellationRequestedAfterSubmission,
    SubmittedButUnverified,
    Unsupported,
}

public sealed record FileShareLinkTransportResult(
    FileShareLinkTransportStatus Status,
    JsonNode? Data = null,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);
