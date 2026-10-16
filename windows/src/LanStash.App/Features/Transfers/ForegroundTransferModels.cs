using LanStash.Domain;

namespace LanStash.App.Features.Transfers;

internal sealed record ForegroundSelectionDownloadFinished(string ProfileId, Guid ActivityId, int SelectedCount, FileDownloadBatchAttemptStatus Status);

internal enum ForegroundTransferItemState { Waiting, Running, Completed, Failed, Cancelled, ResultNeedsReview }
internal sealed record ForegroundTransferItemResult(string RelativePath, bool IsDirectory, ForegroundTransferItemState State, Guid? ActivityId = null);
internal sealed class ForegroundDownloadException(MutationErrorCategory category) : IOException("download.preflight-failed")
{
    public MutationErrorCategory Category { get; } = category;
}

internal enum ForegroundTransferDirection
{
    Download,
    Upload,
    NasOperation,
}

internal enum ForegroundTransferSource
{
    App,
    Nas,
    NasFileStation,
}

internal enum ForegroundTransferState
{
    Running,
    Paused,
    Completed,
    Cancelled,
    CancelledBeforeSubmission,
    ResultNeedsReview,
    EndedNeedsReview,
    Failed,
}

internal sealed record ForegroundTransferProgress(
    long BytesTransferred,
    long TotalBytes);

internal sealed record ForegroundTransferActivity(
    Guid Id,
    string ProfileId,
    ForegroundTransferSource Source,
    string? SourceIdentifier,
    string RemotePath,
    string DisplayName,
    ForegroundTransferDirection Direction,
    long BytesTransferred,
    long TotalBytes,
    ForegroundTransferState State,
    string? FailureMessage,
    FileBackgroundTaskKind? FileTaskKind = null,
    double? ProgressFraction = null)
{
    public bool CanPause { get; init; }
    public double BytesPerSecond { get; init; }
    public IReadOnlyList<ForegroundTransferItemResult> ItemResults { get; init; } = [];
    public MutationErrorCategory? FailureCategory { get; init; }
    public string? OriginalFolder => Source == ForegroundTransferSource.App && RemotePath.StartsWith('/') &&
        !RemotePath.StartsWith("//", StringComparison.Ordinal) && !RemotePath.Contains('\\') &&
        !RemotePath.Any(char.IsControl) && !RemotePath.Split('/').Any(p => p is "." or "..")
        ? Direction == ForegroundTransferDirection.Upload ? RemotePath : RemotePath[..Math.Max(0, RemotePath.LastIndexOf('/'))] : null;
}

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

internal sealed record ForegroundUploadBatchFinished(
    string ProfileId,
    string FolderPath,
    FileUploadBatchSummary Summary);

internal sealed record ForegroundUploadBatchStart(
    FileUploadBatchValidationStatus Status,
    int SelectedCount);

internal enum FolderUploadBatchStartStatus
{
    Started,
    Unsupported,
    Busy,
    NeedsReview,
    SourceChanged,
}

internal sealed record FolderUploadBatchStart(
    FolderUploadBatchStartStatus Status,
    Guid? BatchId = null);

internal sealed record FolderUploadBatchFinished(
    Guid BatchId,
    string ProfileId,
    string FolderPath,
    int DirectoryCount,
    int FileCount,
    FileUploadBatchSummary Summary);

internal sealed record ForegroundDownloadBatchStart(
    FileDownloadBatchValidationStatus Status,
    Guid? BatchId = null);

internal sealed record ForegroundDownloadBatchFinished(
    Guid BatchId,
    string ProfileId,
    FileDownloadBatchSummary Summary);
