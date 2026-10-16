namespace LanStash.Domain;

public enum SynologyPhotoTemporaryStage { Create, Configure, Copy, Close, Delete, Finished }
public sealed record SynologyPhotoTemporaryChange(Guid Id, long? AlbumId, long? CopyId,
    SynologyPhotoTemporaryStage Stage, SynologyPhotoChangeState State, SynologyPhotoFailure? Failure,
    bool FromCreation, bool KeepCopy, bool CancelRequested, bool Running, bool CanContinue, SynologyPhotoSharing? Result)
{
    public bool Pending => State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview;
    public bool CanConfigure => Stage == SynologyPhotoTemporaryStage.Configure && !CancelRequested && !Running;
}
