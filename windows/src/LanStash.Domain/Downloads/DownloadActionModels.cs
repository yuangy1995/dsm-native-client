namespace LanStash.Domain;

public enum DownloadActionKind { CreateLink, CreateFile, Pause, Resume, Remove, FinishIncomplete, EditDestination, RefreshRss, Settings }
public enum DownloadActionStage { NotStarted, Unknown, Accepted, Confirmed, Rejected, Cancelled }
public sealed record DownloadActionItem(string TargetId, DownloadActionStage Stage, MutationErrorCategory? Error,
    DownloadTask? Task = null)
{
    public bool WasSubmitted { get; init; }
}
public sealed record DownloadActionInfo(Guid Id, Guid ProfileId, DownloadActionKind Kind, DateTimeOffset CreatedAt,
    IReadOnlyList<DownloadActionItem> Items)
{
    public bool CancellationRequestedAfterSubmission { get; init; }
    public bool RequiresReview => Items.Any(item => item.Stage == DownloadActionStage.Unknown);
    public bool CanContinue => !RequiresReview && Items.Any(item => item.Stage == DownloadActionStage.NotStarted);
    public bool CanCancelRemaining => Items.Any(item => item.Stage == DownloadActionStage.NotStarted);
    public bool IsPending => RequiresReview || CanCancelRemaining;
}
public sealed record DownloadTaskActionRequest(Guid ProfileId, Guid Id, DownloadActionKind Kind,
    IReadOnlyList<DownloadTask> Tasks, string? Destination = null);
