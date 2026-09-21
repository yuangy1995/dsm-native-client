namespace LanStash.App.CloudDrive;

internal enum CloudDriveDeletionPhase { Prepared, Submitted, ServerVerified, Completed, Abandoned }
internal sealed record CloudDriveDeletionOperation(Guid Id, string ItemIdentity, string RemotePath, bool IsDirectory,
    long Length, DateTimeOffset? ModifiedAt, CloudDriveContentVersion? BaseVersion,
    CloudDriveDeletionPhase Phase, DateTimeOffset CreatedAt)
{
    internal bool IsPending => Phase is not (CloudDriveDeletionPhase.Completed or CloudDriveDeletionPhase.Abandoned);
}
