namespace LanStash.Domain;

public enum SynologyPhotoFileAction { Copy, Move, Delete }
public enum SynologyPhotoFileDuplicate { Skip, Overwrite }
public enum SynologyPhotoFileState { Ready, Submitting, PendingReview, Completed, Partial, Failed, Cancelled }
/// <summary>尚待专用 NAS 验收的破坏性能力分别保护，不按版本名单判断。</summary>
public sealed record SynologyPhotoFileSafety(bool ExtendedDeletion = false, bool CrossSpaceMove = false, bool Overwrite = false);
/// <summary>单一来源的固定原件与目录选择；带目录时必须来自同一父目录。</summary>
public sealed record SynologyPhotoFileCommand(SynologyPhotoFileAction Action, SynologyPhotoSpace Space,
    IReadOnlyList<SynologyPhoto> Photos, IReadOnlyList<SynologyPhotoFolder> Folders)
{
    public SynologyPhotoFolder? Destination { get; init; }
    public SynologyPhotoFileDuplicate Duplicate { get; init; }
}
public sealed record SynologyPhotoFileCounts(long Total, long Completion, long Error, long Skip, long Overwrite)
{
    public long Succeeded => Math.Max(0, Completion - Error);
}
public sealed record SynologyPhotoFileChange(Guid Id, SynologyPhotoFileCommand Command, SynologyPhotoFileState State,
    SynologyPhotoFileCounts? Counts, SynologyPhotoFailure? Failure, bool Running, bool CanContinue)
{
    public bool Pending => State is SynologyPhotoFileState.Submitting or SynologyPhotoFileState.PendingReview;
}
