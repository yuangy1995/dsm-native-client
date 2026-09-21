using LanStash.Domain;

namespace LanStash.App.CloudDrive;

/// 本机已经位于目标且身份匹配后，依次更新两个既有存储；中断后依赖回执和稳定身份继续。
internal sealed class CloudDriveRelocationCompletion(DesktopDriveMapping mapping, DesktopCloudDriveSyncStore sync,
    DesktopCloudDriveStore catalog, Func<CloudDriveRelocationOperation, bool> verifyLocal)
{
    internal async Task<CloudDriveRelocationOperation> CompleteAsync(Guid id, CancellationToken token = default)
    {
        var operation = (await sync.ReadRelocationOperationsAsync(mapping, token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == id)
            ?? throw new InvalidDataException("cloud.relocate.operation_missing");
        if (operation.Phase == CloudDriveRelocationPhase.Completed) return operation;
        if (operation.Phase != CloudDriveRelocationPhase.ServerVerified) throw new InvalidOperationException("cloud.relocate.result_unknown");
        var paths = await catalog.LoadItemPathsAsync(mapping.Id).ConfigureAwait(false);
        if (!paths.TryGetValue(operation.ItemIdentity, out var current) || current != operation.Source && current != operation.Destination)
            throw new InvalidDataException("cloud.relocate.identity_changed");
        token.ThrowIfCancellationRequested();
        if (!verifyLocal(operation)) throw new InvalidDataException("cloud.relocate.local_unverified");
        await sync.RelocatePathsAsync(mapping, new(operation.Id, operation.Source, operation.Destination, operation.LocalName), token,
            paths.Values.ToArray()).ConfigureAwait(false);
        if (current == operation.Source)
            await catalog.RelocateItemPathsAsync(mapping.Id, operation.Source, operation.Destination).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        if (!verifyLocal(operation)) throw new InvalidDataException("cloud.relocate.local_unverified");
        var complete = operation with { Phase = CloudDriveRelocationPhase.Completed };
        await sync.UpdateRelocationOperationAsync(mapping, operation, complete, token).ConfigureAwait(false);
        return complete;
    }
}
