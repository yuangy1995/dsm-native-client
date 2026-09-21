namespace LanStash.App.CloudDrive;

internal sealed record CloudDriveWritebackOverview(bool Enabled, IReadOnlyList<CloudDrivePendingChange> Changes,
    IReadOnlyList<CloudDriveRelocationOperation>? Relocations = null, bool DeletionEnabled = false,
    IReadOnlyList<CloudDriveDeletionOperation>? Deletions = null);
internal sealed record CloudDriveWritebackPreparation(int Ready, int Unavailable);
internal enum CloudDriveRecoveryAction { Review, Save, Retry, KeepLocal }
internal enum CloudDriveRelocationRecoveryAction { Review, Continue, CompleteLocal, Abandon }
internal enum CloudDriveDeletionRecoveryAction { Confirm, Review, CompleteLocal, Abandon }
