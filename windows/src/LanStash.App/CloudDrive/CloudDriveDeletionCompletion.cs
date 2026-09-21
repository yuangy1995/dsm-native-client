using LanStash.Domain;

namespace LanStash.App.CloudDrive;

internal sealed class CloudDriveDeletionCompletion(DesktopDriveMapping mapping, DesktopCloudDriveSyncStore sync,
    DesktopCloudDriveStore catalog, Func<IReadOnlyDictionary<string, string>, CancellationToken, Task> removeLocal)
{
    internal Task CompleteAsync(CloudDriveDeletionOperation expected, CancellationToken token = default) =>
        sync.CompleteDeletionAsync(mapping, expected, async cancellation =>
        {
            var paths = await catalog.LoadItemPathsAsync(mapping.Id).ConfigureAwait(false);
            if (!paths.TryGetValue(expected.ItemIdentity, out var original)) return;
            if (original != expected.RemotePath) throw new InvalidDataException("cloud.delete.identity_changed");
            var tree = paths.Where(item => DesktopDrivePath.IsAncestorOrSame(expected.RemotePath, item.Value))
                .ToDictionary(item => item.Key, item => item.Value, StringComparer.Ordinal);
            await removeLocal(tree, cancellation).ConfigureAwait(false);
            cancellation.ThrowIfCancellationRequested();
            await catalog.UnregisterItemPathAsync(mapping.Id, expected.RemotePath, expected.ItemIdentity).ConfigureAwait(false);
        }, token);
}
