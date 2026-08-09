namespace LanStash.Domain;

public sealed record FileRecycleAvailability(
    bool CanMoveToRecycle,
    bool CanRestore,
    int? DeleteVersion = null,
    int? CopyMoveVersion = null);

public sealed record FileRecycleTarget(
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

public sealed record FileRecycleLocationTarget(
    string SharePath,
    string RecyclePath);

public sealed record MoveToRecycleRequest(
    FileRecycleTarget Target,
    FileRecycleLocationTarget RecycleLocation);

public sealed record RestoreFromRecycleRequest(FileRecycleTarget Target);

public sealed record FileRecycleOutcome(
    MutationResult Result,
    string SourcePath,
    string DestinationPath,
    FileItem? ConfirmedItem = null);
