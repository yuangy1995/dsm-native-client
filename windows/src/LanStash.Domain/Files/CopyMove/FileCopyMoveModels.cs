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
    long Size,
    DateTimeOffset? ModifiedAt,
    bool CanRead,
    bool CanDelete,
    bool IsRemote,
    bool IsVirtual,
    bool IsRecycle);

public sealed record FileCopyMoveRequest(
    FileCopyMoveTarget Target,
    string DestinationDirectoryPath,
    FileCopyMoveOperation Operation,
    bool DestinationCanWrite,
    bool DestinationIsRemote,
    bool DestinationIsVirtual,
    bool DestinationIsRecycle);

public sealed record FileCopyMoveOutcome(
    MutationResult Result,
    FileItem? ConfirmedItem = null);
