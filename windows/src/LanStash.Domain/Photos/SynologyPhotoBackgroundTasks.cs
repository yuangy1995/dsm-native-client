namespace LanStash.Domain;

public enum SynologyPhotoBackgroundStatus { Waiting, Processing, Aborting, Done, Unknown }
public enum SynologyPhotoBackgroundAction { Stop, Clear }
public enum SynologyPhotoBackgroundErrorKind { Item, Folder, Unknown }
public enum SynologyPhotoBackgroundErrorReason { Quota, Space, Subfolder, Missing, TargetMissing, Excluded, Unknown }
public sealed record SynologyPhotoBackgroundTask(Guid ProfileId, long UserId, long Id, string Operation,
    SynologyPhotoBackgroundStatus Status, long Total, long Completion, long Errors, long Skipped, long Overwritten,
    double CreatedAt, long? TargetFolderId = null, long? TargetOwnerId = null)
{
    public bool IsTransfer => Operation is "copy" or "move";
    public bool CanStop => IsTransfer && Status is SynologyPhotoBackgroundStatus.Waiting or SynologyPhotoBackgroundStatus.Processing;
    public bool CanClear => IsTransfer && Status == SynologyPhotoBackgroundStatus.Done;
    public bool WasStopped => Status == SynologyPhotoBackgroundStatus.Done && Completion < Total;
    public long SuccessfulCount => Completion - Errors;
    public SynologyPhotoSpace? TargetSpace => TargetOwnerId == 0 ? SynologyPhotoSpace.Shared : TargetOwnerId == UserId ? SynologyPhotoSpace.Personal : null;
    /// <summary>进度可推进，创建时间保留小数；同编号的另一任务不能接管原操作。</summary>
    public bool SameIdentity(SynologyPhotoBackgroundTask other) => ProfileId == other.ProfileId && UserId == other.UserId && Id == other.Id &&
        Operation == other.Operation && CreatedAt == other.CreatedAt && Total == other.Total && TargetFolderId == other.TargetFolderId && TargetOwnerId == other.TargetOwnerId;
}
public sealed record SynologyPhotoBackgroundError(SynologyPhotoBackgroundErrorKind Kind, long ItemId,
    SynologyPhotoBackgroundErrorReason Reason, string? Name = null, string? FolderPath = null);
public sealed record SynologyPhotoBackgroundCommand(SynologyPhotoBackgroundAction Action, IReadOnlyList<SynologyPhotoBackgroundTask> Targets);
