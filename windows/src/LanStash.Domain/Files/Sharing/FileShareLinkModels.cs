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

public sealed record FileShareLinkTarget(
    Guid ProfileId,
    string Path,
    string Name,
    bool IsDirectory,
    long Size,
    DateTimeOffset? ModifiedAt,
    string? Owner,
    bool CanWrite,
    bool CanDelete);

public sealed record CreateFileShareLinkRequest(
    FileShareLinkTarget Target,
    string? Password = null,
    DateOnly? ExpiresOn = null);

public sealed record FileShareLinkCreationOutcome(
    MutationResult Result,
    FileShareLink? Link = null);

public interface IFileShareLinkRepository
{
    Guid ProfileId { get; }
    FileShareLinkAvailability ShareLinkAvailability { get; }
    Task<FileShareLinkCreationOutcome> CreateFileShareLinkAsync(
        CreateFileShareLinkRequest request,
        CancellationToken cancellationToken = default);
}
