namespace LanStash.Domain;

public enum FileLocationCompletion
{
    Complete,
    Truncated,
}

public enum FileLocationSectionStatus
{
    Available,
    Unavailable,
    Failed,
}

public sealed record FileLocationsAvailability(
    bool Favorites,
    bool RecycleBins,
    bool RemoteLocations);

public sealed record FileFavoriteLocation(
    Guid ProfileId,
    string Name,
    string Path);

public sealed record FileFavoriteSnapshot(
    IReadOnlyList<FileFavoriteLocation> Items,
    int Total,
    int SourceItemCount,
    FileLocationCompletion Completion,
    FileLocationSectionStatus Status,
    string? FailureDiagnosticTag = null);

public sealed record FileRecycleLocation(
    Guid ProfileId,
    string ShareName,
    string SharePath,
    string RecyclePath);

public sealed record FileRecycleSnapshot(
    IReadOnlyList<FileRecycleLocation> Items,
    int AttemptedShareCount,
    int NotFoundShareCount,
    int PermissionDeniedShareCount,
    bool IsPartial,
    FileLocationCompletion Completion,
    FileLocationSectionStatus Status,
    string? FailureDiagnosticTag = null);

public enum FileRemoteProtocol
{
    Cifs,
    Nfs,
    Iso,
}

public sealed record FileRemoteLocation(
    Guid ProfileId,
    string Id,
    string Name,
    string Path,
    FileRemoteProtocol Protocol,
    bool IsReadOnly);

public sealed record FileRemoteSnapshot(
    IReadOnlyList<FileRemoteLocation> Items,
    int Total,
    int SourceItemCount,
    IReadOnlyList<FileRemoteProtocol> UnavailableProtocols,
    bool IsPartial,
    FileLocationCompletion Completion,
    FileLocationSectionStatus Status,
    string? FailureDiagnosticTag = null);

public sealed record FileLocationsSnapshot(
    Guid ProfileId,
    FileLocationsAvailability Availability,
    FileFavoriteSnapshot Favorites,
    FileRecycleSnapshot RecycleBins,
    FileRemoteSnapshot RemoteLocations);
