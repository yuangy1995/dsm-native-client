namespace LanStash.Domain;

public sealed record SynologyPhotoAlbum(long Id, long OwnerUserId, long CurrentUserId, string Name,
    bool Conditional, bool Frozen, string Revision)
{
    public Guid ProfileId { get; init; }
    public int? ItemCount { get; init; }
    public bool? Shared { get; init; }
    public bool CanContribute { get; init; }
    public SynologyPhotoSort? Sort { get; init; }
    public long? CoverId { get; init; }
    public bool IsOwner => OwnerUserId == CurrentUserId;
    public SynologyPhotoCollection Collection => new(Id, Name, Count: ItemCount)
        { IsConditional = Conditional, IsFrozen = Frozen };
}

public enum SynologyPhotoAlbumListScope { Albums, WithMe, ByMe }
public enum SynologyPhotoAlbumListField { Name, Type, StartTime, Created, Sharing, ShareModified }
public enum SynologyPhotoAlbumDisplay { All, Mine }
public sealed record SynologyPhotoAlbumListSort(SynologyPhotoAlbumListField Field, bool Descending = false);
public sealed record SynologyPhotoAlbumSafety(bool Delete = false, bool Unfreeze = false, bool Rebuild = false);
public enum SynologyPhotoAlbumEditKind { Create, Rename, Delete, AddMembers, RemoveMembers, Cover, Sort, ListSort, ListDisplay, CreateCondition, Condition, Unfreeze, Rebuild }

/// <summary>相册意图不包含分享口令；正文只用于当前进程内显式提交。</summary>
public sealed record SynologyPhotoAlbumEdit(SynologyPhotoAlbumEditKind Kind)
{
    public SynologyPhotoAlbum? Album { get; init; }
    public string? Name { get; init; }
    public IReadOnlyList<SynologyPhoto> Photos { get; init; } = [];
    public SynologyPhotoSort? Sort { get; init; }
    public SynologyPhotoAlbumListScope Scope { get; init; }
    public SynologyPhotoAlbumListSort? OriginalListSort { get; init; }
    public SynologyPhotoAlbumListSort? ListSort { get; init; }
    public SynologyPhotoAlbumDisplay? OriginalDisplay { get; init; }
    public SynologyPhotoAlbumDisplay? Display { get; init; }
    public SynologyPhotoCondition? Condition { get; init; }
    public SynologyPhotoSpace? ConditionSpace { get; init; }
    public string? OriginalConditionRevision { get; init; }
}
public sealed record SynologyPhotoAlbumMemberChange(SynologyPhoto Photo, SynologyPhotoChangeState State);
public sealed record SynologyPhotoAlbumChange(Guid Id, SynologyPhotoAlbumEdit Edit, SynologyPhotoChangeState State,
    IReadOnlyList<SynologyPhotoAlbumMemberChange> Members, SynologyPhotoAlbum? Result, SynologyPhotoFailure? Failure,
    bool Running, bool CanContinue)
{
    public bool Pending => State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview;
    public bool ReplacementCreated { get; init; }
}
