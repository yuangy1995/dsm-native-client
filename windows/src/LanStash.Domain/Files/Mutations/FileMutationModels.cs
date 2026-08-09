namespace LanStash.Domain;

public sealed record FileMutationAvailability(
    bool CanCreateFolder,
    bool CanRename,
    int? CreateFolderVersion = null,
    int? RenameVersion = null);

public sealed record FileMutationTarget(
    Guid ProfileId,
    string Path,
    string Name,
    bool IsDirectory,
    long Size,
    DateTimeOffset? ModifiedAt,
    bool CanWrite);

public sealed record CreateFolderRequest(Guid ProfileId, string ParentPath, string Name);

public sealed record RenameFileItemRequest(FileMutationTarget Target, string NewName);

public sealed record FileMutationOutcome(MutationResult Result, FileItem? ConfirmedItem = null);
