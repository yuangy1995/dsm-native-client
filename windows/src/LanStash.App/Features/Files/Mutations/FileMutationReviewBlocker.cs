namespace LanStash.App.Features.Files.Mutations;

public enum FileMutationOperation
{
    CreateFolder,
    Rename,
}

public sealed record FileMutationReviewBlock(
    Guid ProfileId,
    FileMutationOperation Operation,
    string FrozenPath,
    string ProposedPath);

public sealed class FileMutationReviewBlocker
{
    private readonly object _sync = new();
    private readonly Dictionary<(Guid ProfileId, FileMutationOperation Operation, string FrozenPath),
        FileMutationReviewBlock> _blocked = [];

    public static FileMutationReviewBlocker Current { get; } = new();

    public FileMutationReviewBlock? Find(
        Guid profileId,
        FileMutationOperation operation,
        string frozenPath)
    {
        lock (_sync)
        {
            return _blocked.GetValueOrDefault((profileId, operation, frozenPath));
        }
    }

    public void Block(FileMutationReviewBlock review)
    {
        lock (_sync)
        {
            _blocked[(review.ProfileId, review.Operation, review.FrozenPath)] = review;
        }
    }
}
