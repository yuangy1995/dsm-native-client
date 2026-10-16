using LanStash.App.Features.Files.Office;
using LanStash.Domain;

namespace LanStash.App.ViewModels;

public sealed partial class AppViewModel
{
    internal OfficeEditingCoordinator OfficeEdits { get; }
    internal bool OfficeRecoveryUnavailable => ActiveProfile is { } profile && _officeRecoveryUnavailable.Contains(profile.Id);
    private readonly HashSet<Guid> _officeRecoveryUnavailable = [];
    private readonly Dictionary<Guid, CancellationTokenSource> _officeConnectionReads = [];

    private async Task AttachOfficeRepositoryAsync(IOfficeEditingRepository repository)
    {
        if (_officeConnectionReads.Remove(repository.ProfileId, out var previous)) { previous.Cancel(); previous.Dispose(); }
        var cancellation = new CancellationTokenSource(); _officeConnectionReads[repository.ProfileId] = cancellation;
        try { await OfficeEdits.AttachAsync(repository, cancellation.Token).ConfigureAwait(true); _officeRecoveryUnavailable.Remove(repository.ProfileId); }
        catch (OperationCanceledException) { }
        catch { if (!cancellation.IsCancellationRequested) _officeRecoveryUnavailable.Add(repository.ProfileId); }
        finally
        {
            if (_officeConnectionReads.TryGetValue(repository.ProfileId, out var current) && ReferenceEquals(current, cancellation))
                _officeConnectionReads.Remove(repository.ProfileId);
            cancellation.Dispose();
        }
    }
    private void DisconnectOffice(Guid profileId)
    {
        if (_officeConnectionReads.TryGetValue(profileId, out var cancellation)) cancellation.Cancel();
        OfficeEdits.Disconnect(profileId);
    }

    internal async Task ValidateOfficeLocationAsync(Guid profileId, string remotePath, string localPath, CancellationToken token)
    {
        var target = Path.GetFullPath(localPath);
        foreach (var mapping in _cloudDrives.Mappings)
        {
            var root = Path.GetFullPath(_cloudDrives.MappingPath(mapping)).TrimEnd(Path.DirectorySeparatorChar);
            if (string.Equals(target, root, StringComparison.OrdinalIgnoreCase) ||
                target.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                throw new IOException("office.cloud-local-copy");
            if (profileId == Guid.Empty || mapping.ProfileId != profileId || !OfficeMappingContains(mapping, remotePath)) continue;
            var overview = await _cloudDrives.ReadWritebackAsync(mapping, token).ConfigureAwait(true);
            if (overview.Enabled || overview.Changes.Any(change => change.IsPending && change.RemotePath == remotePath) ||
                overview.Relocations?.Any(change => change.IsPending &&
                    (OfficePathsOverlap(change.Source, remotePath) || OfficePathsOverlap(change.Destination, remotePath))) == true ||
                overview.Deletions?.Any(change => change.IsPending && OfficePathsOverlap(change.RemotePath, remotePath)) == true)
                throw new IOException("office.cloud-writeback-conflict");
        }
    }

    private static bool OfficeMappingContains(DesktopDriveMapping mapping, string path) =>
        mapping.Scope.Kind == DesktopDriveScopeKind.AllShares || mapping.Scope.FolderPath is { } root &&
            (path == root || path.StartsWith(root.TrimEnd('/') + "/", StringComparison.Ordinal));
    private static bool OfficePathsOverlap(string a, string b) => a == b || a == "/" || b == "/" ||
        a.StartsWith(b.TrimEnd('/') + "/", StringComparison.Ordinal) || b.StartsWith(a.TrimEnd('/') + "/", StringComparison.Ordinal);
}
