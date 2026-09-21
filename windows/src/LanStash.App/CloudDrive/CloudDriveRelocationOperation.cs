namespace LanStash.App.CloudDrive;

internal enum CloudDriveRelocationPhase { Prepared, Submitted, ReadyForNextStep, ServerVerified, Completed, Rejected, Abandoned }
internal sealed record CloudDriveRelocationStep(string Source, string Destination, bool Move);
internal sealed record CloudDriveRelocationOperation(Guid Id, string ItemIdentity, string Source, string Destination,
    string LocalName, bool IsDirectory, long Length, DateTimeOffset? ModifiedAt,
    IReadOnlyList<CloudDriveRelocationStep> Steps, int Step, CloudDriveRelocationPhase Phase, DateTimeOffset CreatedAt)
{
    internal bool IsPending => Phase is not (CloudDriveRelocationPhase.Completed or CloudDriveRelocationPhase.Abandoned);
}
