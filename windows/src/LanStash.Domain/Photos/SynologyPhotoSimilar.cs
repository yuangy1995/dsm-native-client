namespace LanStash.Domain;

public sealed record SynologyPhotoSimilarGroup(long Id, SynologyPhotoSpace Space, long TopPickId, IReadOnlyList<long> PhotoIds)
{
    public int Count => PhotoIds.Count;
    public bool Matches(SynologyPhotoSimilarGroup? other) => other is not null && Id == other.Id && Space == other.Space &&
        TopPickId == other.TopPickId && PhotoIds.ToHashSet().SetEquals(other.PhotoIds);
}
public sealed record SynologyPhotoSimilarDetail(SynologyPhotoSimilarGroup Group, IReadOnlyList<SynologyPhoto> Photos);
public sealed record SynologyPhotoSimilarStatus(int WaitingCount, string Stage, bool MigrationDone)
{
    public bool HasWork => WaitingCount > 0 || !MigrationDone;
    public bool Running => WaitingCount > 0 && Stage == "running";
}
public sealed record SynologyPhotoSimilarResult(Guid OperationId, long GroupId, SynologyPhotoChangeState State,
    SynologyPhotoSimilarGroup? Group, bool Accepted);
