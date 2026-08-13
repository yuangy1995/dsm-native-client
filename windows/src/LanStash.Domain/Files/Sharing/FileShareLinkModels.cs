namespace LanStash.Domain;

public enum FileShareLinkAvailabilityStatus
{
    Available,
    Unavailable,
}

public sealed record FileShareLinkAvailability(
    FileShareLinkAvailabilityStatus Status,
    int? ResolvedVersion = null)
{
    public bool IsAvailable => Status == FileShareLinkAvailabilityStatus.Available;
}

public sealed record FileShareLink(
    string Id,
    string Path,
    Uri Url,
    bool HasPassword,
    DateOnly? ExpiresOn);

public enum FileShareLinkTargetBaseline
{
    FileBrowser,
    PhotoMedia,
}

public sealed record FileShareLinkTarget(
    Guid ProfileId,
    string Path,
    string Name,
    bool IsDirectory,
    long Size,
    DateTimeOffset? ModifiedAt,
    string? Owner,
    bool CanWrite,
    bool CanDelete,
    FileShareLinkTargetBaseline Baseline = FileShareLinkTargetBaseline.FileBrowser);

public sealed record CreateFileShareLinkRequest(
    FileShareLinkTarget Target,
    string? Password = null,
    DateOnly? ExpiresOn = null);

public sealed record FileShareLinkCreationOutcome(
    MutationResult Result,
    FileShareLink? Link = null);

public sealed record DeleteFileShareLinkRequest(FileShareLink Link);

public sealed record FileShareLinkDeletionOutcome(
    MutationResult Result,
    FileShareLink? Link = null);

public interface IFileShareLinkRepository
{
    Guid ProfileId { get; }
    FileShareLinkAvailability ShareLinkAvailability { get; }
    Task<IReadOnlyList<FileShareLink>> ListFileShareLinksAsync(
        CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<FileShareLink>>(
            new NotSupportedException("file.share.list.unsupported"));
    Task<FileShareLinkCreationOutcome> CreateFileShareLinkAsync(
        CreateFileShareLinkRequest request,
        CancellationToken cancellationToken = default);
    Task<FileShareLinkDeletionOutcome> DeleteFileShareLinkAsync(
        DeleteFileShareLinkRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileShareLinkDeletionOutcome(
            new MutationResult(
                1,
                MutationResultStatus.Unsupported,
                "shareLinkDelete",
                submitted: false,
                requiresRefresh: false,
                new MutationResultCounts(0, 1, 0),
                MutationErrorCategory.Unsupported,
                diagnosticTag: "file.share.delete.unsupported"),
            request.Link));
}
