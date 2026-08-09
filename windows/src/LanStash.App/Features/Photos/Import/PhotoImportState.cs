using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Import;

internal enum PhotoImportMode
{
    Folder,
    Timeline,
}

internal enum PhotoImportPhase
{
    Idle,
    Choosing,
    Activity,
    Confirmed,
    ConfirmedElsewhere,
    NeedsReview,
    Cancelled,
    PermissionDenied,
    Unsupported,
    Failed,
}

internal sealed record PhotoMediaUploadStart(Guid ActivityId);

internal sealed record PhotoMediaUploadFinished(
    Guid ActivityId,
    string ProfileId,
    string FolderPath,
    MutationResult Result);

internal sealed record PhotoMediaUploadInterrupted(
    Guid ActivityId,
    string ProfileId,
    string FolderPath,
    bool IsCancelled);

internal interface IPhotoImportTransferService
{
    event Action<PhotoMediaUploadFinished>? MediaUploadFinished;
    event Action<PhotoMediaUploadInterrupted>? MediaUploadInterrupted;

    Task<PhotoMediaUploadStart?> PickAndStartMediaUploadAsync(
        string profileId,
        string folderPath,
        Guid activityId);
}

internal sealed record PhotoImportContext(
    Guid ProfileId,
    object RepositoryIdentity,
    PhotoSpace Space,
    string CurrentPath,
    PhotoImportMode Mode);

internal sealed record PhotoImportTarget(
    Guid ProfileId,
    object RepositoryIdentity,
    string SpaceId,
    string SpaceRootPath,
    string FolderPath,
    PhotoImportMode Mode,
    long ContextGeneration)
{
    internal static PhotoImportTarget? Create(
        PhotoImportContext? context,
        long contextGeneration)
    {
        if (context is null ||
            context.ProfileId == Guid.Empty ||
            context.RepositoryIdentity is null ||
            context.Space.Id is not (PhotoSpaceIds.Personal or PhotoSpaceIds.Shared) ||
            !IsCanonicalAbsolutePath(context.Space.RootPath) ||
            ContainsRecycleSegment(context.Space.RootPath))
        {
            return null;
        }

        var targetPath = context.Mode == PhotoImportMode.Timeline
            ? context.Space.RootPath
            : context.CurrentPath;
        if (!IsCanonicalAbsolutePath(targetPath) ||
            ContainsRecycleSegment(targetPath) ||
            !ContainsOrEquals(context.Space.RootPath, targetPath))
        {
            return null;
        }

        return new PhotoImportTarget(
            context.ProfileId,
            context.RepositoryIdentity,
            context.Space.Id,
            context.Space.RootPath,
            targetPath,
            context.Mode,
            contextGeneration);
    }

    private static bool ContainsOrEquals(string root, string path) =>
        string.Equals(root, path, StringComparison.Ordinal) ||
        path.StartsWith(root + "/", StringComparison.Ordinal);

    private static bool IsCanonicalAbsolutePath(string value)
    {
        if (string.IsNullOrEmpty(value) || value[0] != '/' || value == "/" ||
            value.Contains('\\') || value.Contains("//", StringComparison.Ordinal) ||
            value.EndsWith("/", StringComparison.Ordinal))
        {
            return false;
        }

        return value.Split('/').Skip(1).All(segment =>
            segment.Length > 0 && segment is not "." and not "..");
    }

    private static bool ContainsRecycleSegment(string path) =>
        path.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => string.Equals(segment, "#recycle", StringComparison.OrdinalIgnoreCase));
}
