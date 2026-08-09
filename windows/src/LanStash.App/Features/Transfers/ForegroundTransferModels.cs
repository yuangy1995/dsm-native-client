using LanStash.Domain;

namespace LanStash.App.Features.Transfers;

internal enum ForegroundTransferDirection
{
    Download,
    Upload,
}

internal enum ForegroundTransferState
{
    Running,
    Completed,
    Cancelled,
    CancelledBeforeSubmission,
    ResultNeedsReview,
    Failed,
}

internal sealed record ForegroundTransferProgress(
    long BytesTransferred,
    long TotalBytes);

internal sealed record ForegroundTransferActivity(
    Guid Id,
    string ProfileId,
    string RemotePath,
    string DisplayName,
    ForegroundTransferDirection Direction,
    long BytesTransferred,
    long TotalBytes,
    ForegroundTransferState State,
    string? FailureMessage);

internal sealed record ForegroundDownloadRequest(
    string ProfileId,
    string RemotePath,
    string DisplayName,
    long TotalBytes,
    Guid? OperationId = null);

internal delegate Task ForegroundDownloadOperation(
    IProgress<ForegroundTransferProgress> progress,
    CancellationToken cancellationToken);

internal sealed record ForegroundUploadRequest(
    string ProfileId,
    string FolderPath,
    string DisplayName,
    long TotalBytes,
    Guid OperationId);

internal delegate Task<MutationResult> ForegroundUploadOperation(
    IProgress<long> progress,
    CancellationToken cancellationToken);

internal sealed record ForegroundUploadFinished(
    string ProfileId,
    string FolderPath,
    MutationResult Result);
