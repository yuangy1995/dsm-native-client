namespace LanStash.Domain;

public enum SynologyPhotoLinkAccess { Disabled, Invited, View, Download }
public enum SynologyPhotoPasswordChange { Keep, Replace, Clear }
/// <summary>保留 NAS 返回的数字/字符串身份，不将照片用户编号作为系统成员编号。</summary>
public sealed record SynologyPhotoShareIdentity(string Type, string Value, bool Numeric = false);
public sealed record SynologyPhotoShareRecipient(SynologyPhotoShareIdentity Id, string Name);
public sealed record SynologyPhotoShareGrant(SynologyPhotoShareRecipient Recipient, string Role)
{
    public SynologyPhotoShareIdentity Id => Recipient.Id;
}
public sealed record SynologyPhotoSharing(SynologyPhotoAlbum Album, SynologyPhotoLinkAccess Access, string Revision)
{
    public Uri? Url { get; init; }
    public bool? HasPassword { get; init; }
    public long? Expiration { get; init; }
    public bool? Temporary { get; init; }
    public SynologyPhotoLinkAccess? ConfiguredAccess { get; init; }
    public IReadOnlyList<SynologyPhotoShareGrant>? Members { get; init; }
}
public sealed record SynologyPhotoSharingEdit(SynologyPhotoSharing Original, SynologyPhotoLinkAccess Access)
{
    public IReadOnlyList<SynologyPhotoShareGrant>? Members { get; init; }
    public long? Expiration { get; init; }
    public SynologyPhotoPasswordChange PasswordChange { get; init; }
    public string? Password { get; init; }
    public bool ExpandsAccess
    {
        get
        {
            if (Access == SynologyPhotoLinkAccess.Disabled) return false;
            if (Access > Original.Access || PasswordChange == SynologyPhotoPasswordChange.Clear && Original.HasPassword != false ||
                Expiration is { } expiry && (Original.Expiration is null || Original.Expiration > 0 && (expiry == 0 || expiry > Original.Expiration))) return true;
            return Members?.Any(member =>
            {
                var old = Original.Members?.SingleOrDefault(value => value.Id == member.Id);
                return old is null || old.Role != member.Role && (RoleRank(old.Role) < 0 || RoleRank(member.Role) > RoleRank(old.Role));
            }) == true;
        }
    }
    private static int RoleRank(string? role) => role switch { null => 0, "view" => 1, "download" => 2, "upload" => 3, "manage" => 4, _ => -1 };
}
public sealed record SynologyPhotoSharingSafety(bool Publish = false, bool TemporaryCleanup = false, bool Requests = false, bool FolderPermissions = false);
public enum SynologyPhotoSharingStage { Close, Configure, Open, Finished }
public sealed record SynologyPhotoSharingChange(Guid Id, long AlbumId, SynologyPhotoLinkAccess Access,
    SynologyPhotoSharingStage Stage, SynologyPhotoChangeState State, SynologyPhotoFailure? Failure,
    bool Running, bool CanContinue, bool NeedsInput, SynologyPhotoSharing? Result)
{
    public bool Pending => State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview;
}
