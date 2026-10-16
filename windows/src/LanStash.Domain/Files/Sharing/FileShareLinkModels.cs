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
    DateOnly? ExpiresOn)
{
    public DateOnly? AvailableOn { get; init; }
    public bool AvailabilityDateKnown { get; init; }
    public string? RawAvailableDate { get; init; }
    public string? RawExpiryDate { get; init; }
    public FileShareAdvancedDetails? Advanced { get; init; }
}

public enum FileSharePrincipalKind { User, Group }
public sealed record FileSharePrincipal(string Name, FileSharePrincipalKind Kind);
public enum FileShareProtection { None, Password, Users }
public sealed record FileShareAdvancedDetails(
    FileShareProtection Protection,
    IReadOnlyList<string> Users,
    IReadOnlyList<string> Groups,
    int MaximumAccesses,
    bool AllowsUpload,
    bool IsFileRequest,
    string RequestName,
    string RequestMessage);

public sealed record FileRequestConfiguration(string Name, string Message, bool UploadConfirmed);
public enum FileShareValueIntent { Keep, Replace, Clear }
public enum FileShareAudienceIntent { Keep, Anyone, Principals }
public sealed record FileShareAdvancedChange
{
    public FileShareAudienceIntent Audience { get; init; }
    public IReadOnlyList<FileSharePrincipal> Principals { get; init; } = [];
    public int? MaximumAccesses { get; init; }
    public string? RequestName { get; init; }
    public string? RequestMessage { get; init; }
    public bool AudienceChangeConfirmed { get; init; }
}

public sealed record EditFileShareLinkRequest(FileShareLink Link)
{
    public FileShareValueIntent PasswordIntent { get; init; }
    public string? Password { get; init; }
    public bool PasswordRemovalConfirmed { get; init; }
    public FileShareValueIntent AvailableDateIntent { get; init; }
    public DateOnly? AvailableOn { get; init; }
    public FileShareValueIntent ExpiryDateIntent { get; init; }
    public DateOnly? ExpiresOn { get; init; }
    public FileShareAdvancedChange? Advanced { get; init; }
    public override string ToString() => nameof(EditFileShareLinkRequest);
}

public sealed record FileShareLinkEditOutcome(MutationResult Result, FileShareLink? Link = null);

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
    DateOnly? ExpiresOn = null)
{
    public DateOnly? AvailableOn { get; init; }
    public FileRequestConfiguration? FileRequest { get; init; }
    public override string ToString() => nameof(CreateFileShareLinkRequest);
}

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
    Task<FileShareLinkCreationOutcome> ReviewFileShareLinkCreationAsync(
        string path, CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileShareLinkCreationOutcome(UnsupportedResult("shareLinkCreate")));
    Task<IReadOnlyList<FileSharePrincipal>> ListFileSharePrincipalsAsync(
        string prefix, CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<FileSharePrincipal>>(new NotSupportedException("file.share.members.unsupported"));
    Task<FileShareLinkEditOutcome> EditFileShareLinkAsync(
        EditFileShareLinkRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileShareLinkEditOutcome(UnsupportedResult("shareLinkEdit")));
    Task<FileShareLinkEditOutcome> ReviewFileShareLinkEditAsync(
        string id, CancellationToken cancellationToken = default) =>
        Task.FromResult(new FileShareLinkEditOutcome(UnsupportedResult("shareLinkEdit")));
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

    private static MutationResult UnsupportedResult(string operation) => new(
        1, MutationResultStatus.Unsupported, operation, false, false,
        new MutationResultCounts(0, 1, 0), MutationErrorCategory.Unsupported);
}
