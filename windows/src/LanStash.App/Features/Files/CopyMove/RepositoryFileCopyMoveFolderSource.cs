using LanStash.App.Features.Files;
using LanStash.Domain;

namespace LanStash.App.Features.Files.CopyMove;

public sealed class RepositoryFileCopyMoveFolderSource : IFileCopyMoveFolderSource
{
    private const int PageSize = 200;
    private const int MaximumItems = 5000;
    private readonly IFileBrowserDataSource _browser;
    private readonly IFileLocationsRepository _locations;
    private readonly SemaphoreSlim _initializeGate = new(1, 1);
    private IReadOnlyList<string>? _readOnlyRoots;

    public RepositoryFileCopyMoveFolderSource(Guid profileId, IFileBrowserDataSource browser,
        IFileLocationsRepository locations)
    {
        if (locations.ProfileId != profileId)
            throw new ArgumentException("file.copy-move.profile-mismatch", nameof(locations));
        ProfileId = profileId;
        _browser = browser ?? throw new ArgumentNullException(nameof(browser));
        _locations = locations;
    }

    public Guid ProfileId { get; }

    public bool IsReadOnlyPath(string path) => ContainsRecycle(path) ||
        _readOnlyRoots?.Any(root => IsEqualOrDescendant(path, root)) == true;

    public async Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(
        string path, CancellationToken cancellationToken)
    {
        await EnsureConstraintsAsync(cancellationToken);
        if (IsReadOnlyPath(path))
            throw new InvalidOperationException("file.copy-move.read-only-path");

        var result = new List<FileCopyMoveFolder>();
        var offset = 0;
        int? total = null;
        while (offset < MaximumItems)
        {
            var requested = Math.Min(PageSize, MaximumItems - offset);
            var page = await _browser.LoadPageAsync(path, offset, requested,
                new FileListOptions(TypeFilter: FileListTypeFilter.Folders), cancellationToken);
            if (page.Offset != offset || page.Total < 0 || (total is not null && total != page.Total) ||
                page.Items.Count > requested || checked(offset + page.Items.Count) > page.Total)
                throw new InvalidDataException("file.copy-move.invalid-folder-page");
            total ??= page.Total;
            if (page.Items.Any(item => !item.IsDirectory))
                throw new InvalidDataException("file.copy-move.non-folder-item");
            foreach (var item in page.Items)
            {
                if (!ContainsRecycle(item.Path) && !IsReadOnlyPath(item.Path))
                    result.Add(new(item.Path, item.Name, item.CanWrite));
            }
            if (page.Items.Count == 0 || offset + page.Items.Count == page.Total) break;
            offset = checked(offset + page.Items.Count);
        }
        if (total > MaximumItems)
            throw new InvalidDataException("file.copy-move.folder-list-truncated");
        return result;
    }

    private async Task EnsureConstraintsAsync(CancellationToken cancellationToken)
    {
        if (_readOnlyRoots is not null) return;
        await _initializeGate.WaitAsync(cancellationToken);
        try
        {
            if (_readOnlyRoots is not null) return;
            var snapshot = await _locations.LoadSnapshotAsync(cancellationToken);
            if (snapshot.ProfileId != ProfileId ||
                (snapshot.Availability.RemoteLocations && snapshot.RemoteLocations.Status != FileLocationSectionStatus.Available) ||
                (snapshot.Availability.RecycleBins && snapshot.RecycleBins.Status != FileLocationSectionStatus.Available) ||
                snapshot.RemoteLocations.Items.Any(item => item.ProfileId != ProfileId) ||
                snapshot.RecycleBins.Items.Any(item => item.ProfileId != ProfileId))
                throw new InvalidDataException("file.copy-move.invalid-location-snapshot");
            _readOnlyRoots = snapshot.RemoteLocations.Items.Select(item => item.Path)
                .Concat(snapshot.RecycleBins.Items.Select(item => item.RecyclePath))
                .Where(FileCopyMoveViewModel.IsDestination).Distinct(StringComparer.Ordinal).ToArray();
        }
        finally { _initializeGate.Release(); }
    }

    private static bool IsEqualOrDescendant(string path, string root) =>
        string.Equals(path, root, StringComparison.Ordinal) ||
        path.StartsWith(root + "/", StringComparison.Ordinal);
    private static bool ContainsRecycle(string path) => path.Split('/', StringSplitOptions.RemoveEmptyEntries)
        .Any(segment => string.Equals(segment, "#recycle", StringComparison.OrdinalIgnoreCase));
}
