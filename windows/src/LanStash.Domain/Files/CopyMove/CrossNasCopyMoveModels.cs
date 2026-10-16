namespace LanStash.Domain;

public sealed record CrossNasCopyMoveAvailability(
    bool CanCrossCopy,
    bool CanCrossMove);

public enum CrossNasCopyMoveOperation
{
    Copy,
    Move,
}

public sealed record CrossNasCopyMoveRequest(
    Guid SourceProfileId,
    Guid TargetProfileId,
    string SourcePath,
    string SourceName,
    bool IsDirectory,
    long FileSize,
    string DestinationFolderPath,
    bool Overwrite,
    CrossNasCopyMoveOperation Operation = CrossNasCopyMoveOperation.Copy,
    Guid OperationId = default)
{
    public string? TargetIdentity { get; init; }
    public DateTimeOffset? SourceModifiedAt { get; init; }
}

public sealed record CrossNasCopyMoveOutcome(
    MutationResult Result,
    string SourcePath,
    string DestinationPath,
    FileItem? ConfirmedItem = null)
{
    public Guid OperationId { get; init; }
    public IReadOnlyList<CrossNasTransferItemResult> Items { get; init; } = [];
    public bool CanContinue { get; init; }
    public bool IsRunning { get; init; }
    public bool RequiresReadOnlyRecovery { get; init; }
    public bool RecoveryStorageUnavailable { get; init; }
    public bool CanDeleteSources { get; init; }
    public CrossNasSourceDeletionOutcome? SourceDeletion { get; init; }
}

public enum CrossNasSourceDeletionState { NotStarted, Deleting, Deleted, Failed, ResultUnavailable }
public sealed record CrossNasSourceDeletionItem(string SourcePath, bool IsDirectory, CrossNasSourceDeletionState State);
public sealed record CrossNasSourceDeletionOutcome(MutationResult Result, IReadOnlyList<CrossNasSourceDeletionItem> Items);

public enum CrossNasTransferItemState { NotStarted, Copying, Copied, Failed, ResultUnavailable, Cancelled }

public sealed record CrossNasTransferItemResult(
    string SourcePath, string DestinationPath, bool IsDirectory,
    CrossNasTransferItemState State, MutationResult? Result);

// 当前连接的恢复身份；刷新不携带可重放请求或认证信息。
public sealed record CrossNasTransferSummary(
    Guid Id, Guid SourceProfileId, Guid TargetProfileId, string SourcePath,
    string DestinationFolderPath, string Name, bool IsDirectory, long Size,
    CrossNasCopyMoveOutcome Outcome);
