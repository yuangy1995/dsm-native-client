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
    CrossNasCopyMoveOperation Operation = CrossNasCopyMoveOperation.Copy);

public sealed record CrossNasCopyMoveOutcome(
    MutationResult Result,
    string SourcePath,
    string DestinationPath,
    FileItem? ConfirmedItem = null);
