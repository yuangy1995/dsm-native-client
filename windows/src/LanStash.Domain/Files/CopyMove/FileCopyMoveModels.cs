namespace LanStash.Domain;

public enum FileCopyMoveOperation
{
    Copy,
    Move,
}

public sealed record FileCopyMoveAvailability(
    bool CanCopy,
    bool CanMove,
    int? ResolvedVersion);

public sealed record FileCopyMoveTarget(
    Guid ProfileId,
    string Path,
    string Name,
    bool IsDirectory,
    long Size,
    DateTimeOffset? ModifiedAt,
    bool CanRead,
    bool CanDelete,
    bool IsRemote,
    bool IsVirtual,
    bool IsRecycle);

public enum FileCopyMoveConflictPolicy { Fail, Skip, Overwrite }

// 只暴露当前连接内的核对身份与冻结目标，不携带认证资料或可重放请求。
public sealed record FileCopyMovePendingReview(
    Guid Id, Guid ProfileId, FileCopyMoveOperation Operation,
    string SourcePath, string DestinationPath, string Name, bool IsDirectory, long Size);

public sealed record FileCopyMoveRequest(
    FileCopyMoveTarget Target,
    string DestinationDirectoryPath,
    FileCopyMoveOperation Operation,
    bool DestinationCanWrite,
    bool DestinationIsRemote,
    bool DestinationIsVirtual,
    bool DestinationIsRecycle)
{
    // 旧调用保留遇同名失败；覆盖只能由已确认的入口显式选择。
    public FileCopyMoveConflictPolicy ConflictPolicy { get; init; } = FileCopyMoveConflictPolicy.Fail;
}

public sealed record FileCopyMoveOutcome(
    MutationResult Result,
    FileItem? ConfirmedItem = null)
{
    public bool SkippedExisting { get; init; }
}
