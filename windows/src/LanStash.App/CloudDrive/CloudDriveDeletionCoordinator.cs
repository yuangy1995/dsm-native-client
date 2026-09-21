using LanStash.Domain;

namespace LanStash.App.CloudDrive;

/// 删除必须先确认冻结的对象；提交前落盘，未知结果仅核查，不能再次删除同名新对象。
internal sealed class CloudDriveDeletionCoordinator(DesktopDriveMapping mapping, IDsmRepository repository, DesktopCloudDriveSyncStore store)
{
    internal async Task<CloudDriveDeletionOperation> PrepareAsync(string identity, string path, CancellationToken token = default)
    {
        RequireContext(path); RequireDeleteCapability();
        using var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        if (!await store.IsDeletionEnabledAsync(mapping, token).ConfigureAwait(false)) throw new InvalidOperationException("cloud.sync.read_only");
        var item = await ReadTargetAsync(path, token).ConfigureAwait(false);
        CloudDriveContentVersion? version = null;
        if (!item.IsDirectory)
        {
            version = (await CloudDriveRemoteRefresh.ReadCandidateAsync(item, repository, token).ConfigureAwait(false)).Version;
            if (await store.ReadVersionAsync(mapping, path, token).ConfigureAwait(false) is { } original && original != version)
                throw new InvalidDataException("cloud.sync.version_conflict");
            if (await store.ReadEmptyFileBaselineAsync(mapping, path, token).ConfigureAwait(false) is { } empty &&
                (item.Size != 0 || item.ModifiedAt != empty)) throw new InvalidDataException("cloud.sync.version_conflict");
        }
        var operation = new CloudDriveDeletionOperation(Guid.NewGuid(), identity, path, item.IsDirectory, item.Size, item.ModifiedAt,
            version, CloudDriveDeletionPhase.Prepared, DateTimeOffset.UtcNow);
        await store.AddDeletionOperationAsync(mapping, operation, token).ConfigureAwait(false);
        return operation;
    }

    internal async Task<CloudDriveDeletionOperation> ConfirmAsync(CloudDriveDeletionOperation expected, bool confirmed, CancellationToken token = default)
    {
        RequireContext(expected.RemotePath);
        if (!confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
        using var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        var operation = await FindAsync(expected.Id, token).ConfigureAwait(false);
        if (operation != expected) throw new InvalidDataException("cloud.delete.state_changed");
        if (operation.Phase != CloudDriveDeletionPhase.Prepared) return operation;
        RequireDeleteCapability();
        if (!await store.IsDeletionEnabledAsync(mapping, token).ConfigureAwait(false)) throw new InvalidOperationException("cloud.sync.read_only");
        var current = await ReadTargetAsync(operation.RemotePath, token).ConfigureAwait(false);
        if (current.IsDirectory != operation.IsDirectory || current.Size != operation.Length || current.ModifiedAt != operation.ModifiedAt)
            throw new InvalidDataException("cloud.delete.target_changed");
        if (operation.BaseVersion is { } version &&
            (await CloudDriveRemoteRefresh.ReadCandidateAsync(current, repository, token).ConfigureAwait(false)).Version != version)
            throw new InvalidDataException("cloud.sync.version_conflict");
        if (operation.IsDirectory) await CheckChildrenAsync(operation.RemotePath, token).ConfigureAwait(false);
        token.ThrowIfCancellationRequested();
        var submitted = operation with { Phase = CloudDriveDeletionPhase.Submitted };
        await store.UpdateDeletionOperationAsync(mapping, operation, submitted, token).ConfigureAwait(false);
        try
        {
            await repository.DeleteFilesAsync([operation.RemotePath], token).ConfigureAwait(false);
            // 旧适配器的列表轮询不是最终证据；必须精确回读目标和可访问的父目录。
            return await VerifyAsync(submitted, token).ConfigureAwait(false);
        }
        catch { return submitted; }
    }

    internal async Task<CloudDriveDeletionOperation> ReviewAsync(Guid id, CancellationToken token = default)
    {
        using var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        var operation = await FindAsync(id, token).ConfigureAwait(false); RequireContext(operation.RemotePath);
        return operation.Phase == CloudDriveDeletionPhase.Submitted ? await VerifyAsync(operation, token).ConfigureAwait(false) : operation;
    }

    internal async Task AbandonAsync(CloudDriveDeletionOperation expected, bool confirmed, CancellationToken token = default)
    {
        RequireContext(expected.RemotePath);
        if (!confirmed || expected.Phase != CloudDriveDeletionPhase.Prepared) throw new InvalidOperationException("cloud.delete.result_unknown");
        using var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        await store.UpdateDeletionOperationAsync(mapping, expected, expected with { Phase = CloudDriveDeletionPhase.Abandoned }, token).ConfigureAwait(false);
    }

    private async Task<CloudDriveDeletionOperation> VerifyAsync(CloudDriveDeletionOperation operation, CancellationToken token)
    {
        await RequireParentsAsync(operation.RemotePath, false, token).ConfigureAwait(false);
        if (await repository.ReadFileMetadataAsync(operation.RemotePath, token).ConfigureAwait(false) is not null) return operation;
        var verified = operation with { Phase = CloudDriveDeletionPhase.ServerVerified };
        await store.UpdateDeletionOperationAsync(mapping, operation, verified, token).ConfigureAwait(false);
        return verified;
    }

    private async Task<FileItem> ReadTargetAsync(string path, CancellationToken token)
    {
        await RequireParentsAsync(path, true, token).ConfigureAwait(false);
        var metadata = await repository.ReadFileMetadataAsync(path, token).ConfigureAwait(false);
        if (metadata is null || metadata.Item.Path != path || !metadata.Item.CanDelete || metadata.Item.ModifiedAt is null || !Safe(metadata))
            throw new UnauthorizedAccessException("cloud.delete.permission");
        return metadata.Item;
    }

    private async Task RequireParentsAsync(string path, bool requireWrite, CancellationToken token)
    {
        var directParent = Parent(path);
        for (var parent = directParent; parent != "/"; parent = Parent(parent))
        {
            var metadata = await repository.ReadFileMetadataAsync(parent, token).ConfigureAwait(false);
            if (metadata is null || metadata.Item.Path != parent || !metadata.Item.IsDirectory || metadata.MountPointType is null || !Safe(metadata, Parent(parent) == "/") ||
                requireWrite && parent == directParent && !metadata.Item.CanWrite) throw new UnauthorizedAccessException("cloud.delete.permission");
        }
    }

    private async Task CheckChildrenAsync(string root, CancellationToken token)
    {
        var folders = new Queue<string>(); folders.Enqueue(root);
        var seen = new HashSet<string>(StringComparer.Ordinal) { root };
        while (folders.TryDequeue(out var folder))
        {
            var offset = 0;
            while (true)
            {
                var page = await repository.ListFilesAsync(folder, offset, 200, token).ConfigureAwait(false);
                if (page.Offset != offset || page.Total < offset + page.Items.Count || page.Items.Count == 0 && offset < page.Total)
                    throw new InvalidDataException("cloud.delete.incomplete_directory");
                foreach (var child in page.Items)
                {
                    RequireContext(child.Path);
                    if (Parent(child.Path) != folder || !seen.Add(child.Path)) throw new InvalidDataException("cloud.delete.invalid_child");
                    var current = await ReadTargetAsync(child.Path, token).ConfigureAwait(false);
                    if (current.IsDirectory != child.IsDirectory) throw new InvalidDataException("cloud.delete.target_changed");
                    if (current.IsDirectory) folders.Enqueue(child.Path);
                }
                offset = checked(offset + page.Items.Count);
                if (offset == page.Total) break;
            }
        }
    }

    private static bool Safe(FileEntryMetadata metadata, bool allowShare = false) => metadata.Type is { Length: > 0 } &&
        !metadata.Type.Contains("link", StringComparison.OrdinalIgnoreCase) &&
        (metadata.MountPointType is null || metadata.MountPointType.Equals("normal", StringComparison.OrdinalIgnoreCase) ||
            allowShare && metadata.MountPointType.Equals("shared_folder", StringComparison.OrdinalIgnoreCase));
    private static string Parent(string path) => path[..Math.Max(1, path.LastIndexOf('/'))];
    private void RequireDeleteCapability()
    {
        // 复用已有适配器公布的 Delete v2 能力；不据此宣称 NAS 已启用回收站或删除可恢复。
        if (repository is not IFileRecycleRepository recycle || recycle.ProfileId != mapping.ProfileId ||
            !recycle.Availability.CanMoveToRecycle || recycle.Availability.DeleteVersion != 2)
            throw new NotSupportedException("cloud.delete.unsupported");
    }
    private async Task<CloudDriveDeletionOperation> FindAsync(Guid id, CancellationToken token) =>
        (await store.ReadDeletionOperationsAsync(mapping, token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == id)
        ?? throw new InvalidDataException("cloud.delete.operation_missing");
    private void RequireContext(string path)
    {
        if (!CloudDriveWriteScope.CanWrite(mapping, path) ||
            repository is not IFilePreviewRepository preview || preview.ProfileId != mapping.ProfileId)
            throw new InvalidOperationException("cloud.delete.invalid_context");
    }
}
