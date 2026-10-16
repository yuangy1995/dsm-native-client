namespace LanStash.Domain;

public enum SynologyPhotoFolderAccess { Management, Invited, View, Download }
public sealed record SynologyPhotoFolderSharing(Guid ProfileId, SynologyPhotoFolder Folder,
    SynologyPhotoFolderAccess Access, bool ParentIsShared, bool AppliesToSubfolders, string Revision)
{
    public Uri? Url { get; init; }
    public bool? HasPassword { get; init; }
    public IReadOnlyList<SynologyPhotoShareGrant>? Members { get; init; }
    public int Depth => Folder.Path.Split('/', StringSplitOptions.RemoveEmptyEntries).Length;
    public bool InheritsManagementOnly => Depth == 2 && !ParentIsShared;
}
public sealed record SynologyPhotoFolderSharingEdit(SynologyPhotoFolderSharing Original, SynologyPhotoFolderAccess Access,
    bool AppliesToSubfolders)
{
    public IReadOnlyList<SynologyPhotoShareGrant>? Members { get; init; }
    public SynologyPhotoPasswordChange PasswordChange { get; init; }
    public string? Password { get; init; }
}
public enum SynologyPhotoFolderSharingStage { Permissions, DefaultOption, Finished }
public sealed record SynologyPhotoFolderSharingChange(Guid Id, long FolderId, SynologyPhotoFolderSharingStage Stage,
    SynologyPhotoChangeState State, SynologyPhotoFailure? Failure, bool Running, bool CanContinue,
    bool NeedsInput, bool PermissionsSaved, SynologyPhotoFolderSharing? Result)
{
    public bool Pending => State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview;
}
