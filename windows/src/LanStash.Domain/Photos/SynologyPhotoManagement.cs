namespace LanStash.Domain;

public enum SynologyPhotoEditKind { Description, Rating, Date, ShiftDates, AddTags, RemoveTags, CreateTag, Rotate }
public enum SynologyPhotoChangeState { Ready, Submitting, PendingReview, Completed, Failed, Cancelled }

/// <summary>界面提交的固定快照；文字只在当前进程内用于明确发起的写入。</summary>
public sealed record SynologyPhotoEdit(SynologyPhotoEditKind Kind, IReadOnlyList<SynologyPhoto> Photos)
{
    public SynologyPhotoSpace Space { get; init; }
    public string? Text { get; init; }
    public long? Value { get; init; }
    public IReadOnlyList<long> TagIds { get; init; } = [];
}
public sealed record SynologyPhotoChangeItem(SynologyPhoto Original, SynologyPhotoChangeState State,
    SynologyPhoto? Updated = null, SynologyPhotoFailure? Failure = null);
public sealed record SynologyPhotoChange(Guid Id, SynologyPhotoEditKind Kind, SynologyPhotoSpace Space,
    IReadOnlyList<SynologyPhotoChangeItem> Items, SynologyPhotoChangeState TagState,
    SynologyPhotoChoice? CreatedTag, bool Running, bool CanContinue)
{
    public bool Pending => TagState is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview ||
        Items.Any(item => item.State is SynologyPhotoChangeState.Submitting or SynologyPhotoChangeState.PendingReview);
    public bool Completed => (Kind != SynologyPhotoEditKind.CreateTag || TagState == SynologyPhotoChangeState.Completed) &&
        Items.All(item => item.State == SynologyPhotoChangeState.Completed);
}
