using System.Security.Cryptography;
using LanStash.Domain;

namespace LanStash.App.CloudDrive;

/// 复用现有上传/范围读取；状态先落盘、未知不重放、完整内容核查后才完成。
internal sealed class CloudDriveWritebackCoordinator(DesktopDriveMapping mapping, IDsmRepository repository, DesktopCloudDriveSyncStore store)
{
    internal async Task<CloudDriveRefreshCandidate?> ReadEditableCandidateAsync(string path, CancellationToken token = default)
    {
        RequireContext();
        CloudDriveWriteScope.RequireWritable(mapping, path);
        if (!await AncestorsSafeAsync(Parent(path), token).ConfigureAwait(false)) throw new UnauthorizedAccessException("cloud.sync.permission");
        var metadata = await repository.ReadFileMetadataAsync(path, token).ConfigureAwait(false);
        if (metadata is null) return null;
        if (metadata.Item.Path != path || metadata.Item.IsDirectory || !metadata.Item.CanWrite || !SafeMetadata(metadata))
            throw new UnauthorizedAccessException("cloud.sync.permission");
        return await CloudDriveRemoteRefresh.ReadCandidateAsync(metadata.Item, repository, token).ConfigureAwait(false);
    }

    internal async Task<CloudDrivePendingChange> RetryAsync(CloudDrivePendingChange expected, bool confirmed, CancellationToken token = default)
    {
        RequireContext();
        if (!confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
        CloudDrivePendingChange replacement;
        using (var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false))
        {
            var current = await FindAsync(expected.Id, token).ConfigureAwait(false);
            if (current != expected || current.Phase is not (CloudDriveChangePhase.Conflict or CloudDriveChangePhase.Rejected or CloudDriveChangePhase.KeptLocally))
                throw new InvalidOperationException("cloud.sync.invalid_transition");
            CloudDriveRefreshCandidate? target = null;
            if (current.Kind == CloudDriveChangeKind.CreateDirectory)
            {
                if (!await AncestorsSafeAsync(Parent(current.RemotePath), token).ConfigureAwait(false) ||
                    await repository.ReadFileMetadataAsync(current.RemotePath, token).ConfigureAwait(false) is not null)
                    throw new InvalidOperationException("cloud.sync.directory_conflict");
            }
            else target = await ReadEditableCandidateAsync(current.RemotePath, token).ConfigureAwait(false);
            if (target is { Item.Size: 0, Item.ModifiedAt: null }) throw new InvalidDataException("cloud.sync.baseline_missing");
            replacement = await store.PrepareRetryAsync(mapping, expected, target?.Version,
                target?.Item.Size == 0 ? target.Item.ModifiedAt : null, confirmed, token).ConfigureAwait(false);
        }
        return await SubmitAsync(replacement.Id, token).ConfigureAwait(false);
    }

    internal async Task<CloudDrivePendingChange> SubmitAsync(Guid operationId, CancellationToken token = default)
    {
        RequireContext();
        using var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        var change = await FindAsync(operationId, token).ConfigureAwait(false);
        await store.RequireNoRelocationAsync(mapping, change.RemotePath, token).ConfigureAwait(false);
        if (change.Phase == CloudDriveChangePhase.Submitted) return await ReviewCoreAsync(change, token).ConfigureAwait(false);
        if (change.Phase != CloudDriveChangePhase.Prepared) return change;
        if (!await store.IsWritebackEnabledAsync(mapping, token).ConfigureAwait(false)) throw new InvalidOperationException("cloud.sync.read_only");
        await RequireParentsReadyAsync(change.RemotePath, token).ConfigureAwait(false);
        var parent = Parent(change.RemotePath);
        if (!await AncestorsSafeAsync(parent, token).ConfigureAwait(false))
        {
            await store.MarkRejectedAsync(mapping, change.Id, token).ConfigureAwait(false);
            return await FindAsync(change.Id, token).ConfigureAwait(false);
        }
        var metadata = await repository.ReadFileMetadataAsync(change.RemotePath, token).ConfigureAwait(false);
        var current = metadata?.Item;
        if (!change.WasExisting)
        {
            if (metadata is not null)
                return await ConflictAsync(change, token).ConfigureAwait(false);
        }
        else
        {
            if (current is null || current.Path != change.RemotePath || current.IsDirectory) return await ConflictAsync(change, token).ConfigureAwait(false);
            if (!SafeMetadata(metadata!) || !current.CanWrite)
            {
                await store.MarkRejectedAsync(mapping, change.Id, token).ConfigureAwait(false);
                return await FindAsync(change.Id, token).ConfigureAwait(false);
            }
            if (change.EmptyBaseModifiedAt is not null)
            {
                if (current.Size != 0 || current.ModifiedAt != change.EmptyBaseModifiedAt) return await ConflictAsync(change, token).ConfigureAwait(false);
            }
            else
            {
                var candidate = await CloudDriveRemoteRefresh.ReadCandidateAsync(current, repository, token).ConfigureAwait(false);
                if (candidate.Version?.Version != change.BaseVersion) return await ConflictAsync(change, token).ConfigureAwait(false);
            }
        }
        if (change.Kind == CloudDriveChangeKind.CreateDirectory &&
            (repository is not IFileMutationRepository mutation || mutation.ProfileId != mapping.ProfileId || !mutation.FileMutationAvailability.CanCreateFolder))
        {
            await store.MarkRejectedAsync(mapping, change.Id, token).ConfigureAwait(false);
            return await FindAsync(change.Id, token).ConfigureAwait(false);
        }
        await using var content = await store.OpenContentAsync(mapping, change.Id, token).ConfigureAwait(false);
        if (!await store.TryMarkSubmittedAsync(mapping, change.Id, token).ConfigureAwait(false)) return await FindAsync(change.Id, token).ConfigureAwait(false);
        MutationResult result;
        try
        {
            var name = change.RemotePath[(change.RemotePath.LastIndexOf('/') + 1)..];
            result = change.Kind == CloudDriveChangeKind.CreateDirectory
                ? (await ((IFileMutationRepository)repository).CreateFolderAsync(new(mapping.ProfileId, parent, name), token).ConfigureAwait(false)).Result
                : await repository.UploadFileAsync(new(content, change.ContentLength, parent, name, overwrite: change.WasExisting),
                    cancellationToken: token).ConfigureAwait(false);
        }
        catch
        {
            // 无可靠回执时保留 Submitted；下次调用只能核查，不再上传。
            return change with { Phase = CloudDriveChangePhase.Submitted };
        }
        if (result.Status is MutationResultStatus.ConfirmedFailure or MutationResultStatus.PermissionDenied or
            MutationResultStatus.Unsupported or MutationResultStatus.CancelledBeforeSubmission)
        {
            await store.MarkRejectedAsync(mapping, change.Id, CancellationToken.None).ConfigureAwait(false);
            return await FindAsync(change.Id, CancellationToken.None).ConfigureAwait(false);
        }
        change = change with { Phase = CloudDriveChangePhase.Submitted };
        // 成功回执也必须内容回读；未知结果不伪装成功，下一次用户核查可继续只读验证。
        if (result.Status != MutationResultStatus.ConfirmedSuccess) return change;
        try { return await ReviewCoreAsync(change, token, acceptDirectory: true).ConfigureAwait(false); }
        catch { return change; }
    }

    internal async Task<CloudDrivePendingChange> ReviewAsync(Guid operationId, CancellationToken token = default, bool acceptDirectory = false)
    {
        RequireContext();
        using var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        var change = await FindAsync(operationId, token).ConfigureAwait(false);
        await store.RequireNoRelocationAsync(mapping, change.RemotePath, token).ConfigureAwait(false);
        return await ReviewCoreAsync(change, token, acceptDirectory).ConfigureAwait(false);
    }

    private async Task<CloudDrivePendingChange> ReviewCoreAsync(CloudDrivePendingChange change, CancellationToken token, bool acceptDirectory = false)
    {
        if (change.Phase != CloudDriveChangePhase.Submitted) return change;
        await RequireParentsReadyAsync(change.RemotePath, token).ConfigureAwait(false);
        if (!await AncestorsSafeAsync(Parent(change.RemotePath), token).ConfigureAwait(false)) return change;
        var metadata = await repository.ReadFileMetadataAsync(change.RemotePath, token).ConfigureAwait(false);
        if (change.Kind == CloudDriveChangeKind.CreateDirectory)
        {
            if (!acceptDirectory || metadata is null || metadata.Item.Path != change.RemotePath || !metadata.Item.IsDirectory ||
                !SafeMetadata(metadata) || metadata.MountPointType is null) return change;
            await store.ConfirmSavedAsync(mapping, change.Id, null, change.ContentHash, token).ConfigureAwait(false);
            return await FindAsync(change.Id, token).ConfigureAwait(false);
        }
        if (metadata is null || metadata.Item.Path != change.RemotePath || !SafeMetadata(metadata) || metadata.Item.IsDirectory || metadata.Item.Size != change.ContentLength) return change;
        var current = metadata.Item;
        var candidate = await CloudDriveRemoteRefresh.ReadCandidateAsync(current, repository, token).ConfigureAwait(false);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var offset = 0L;
        while (offset < change.ContentLength)
        {
            var length = Math.Min(4L * 1024 * 1024, change.ContentLength - offset);
            var range = await repository.ReadFileRangeResultAsync(change.RemotePath, offset, length,
                candidate.Version!.Version, change.ContentLength, token).ConfigureAwait(false);
            try
            {
                if (range.StatusCode != 206 || range.RequestedStart != offset || range.ResponseStart != offset ||
                    range.RequestedLength != length || range.ResponseLength != length || range.ActualByteCount != length ||
                    range.Bytes.LongLength != length || range.TotalLength != change.ContentLength || !range.CanSafelyReadInSegments ||
                    range.ServerContentVersion != candidate.Version.Version) return change;
                hash.AppendData(range.Bytes); offset += length;
            }
            finally { Array.Clear(range.Bytes); }
        }
        var actualHash = Convert.ToHexString(hash.GetHashAndReset());
        if (actualHash != change.ContentHash) return change;
        await store.ConfirmSavedAsync(mapping, change.Id, candidate.Version, actualHash, token,
            verifiedEmptyModifiedAt: change.ContentLength == 0 ? current.ModifiedAt : null).ConfigureAwait(false);
        return await FindAsync(change.Id, token).ConfigureAwait(false);
    }

    private async Task RequireParentsReadyAsync(string path, CancellationToken token)
    {
        var creations = await store.ReadLocalCreationsAsync(mapping, token).ConfigureAwait(false);
        var changes = await store.ReadChangesAsync(mapping, token).ConfigureAwait(false);
        if (creations.Keys.Any(parent => parent != path && DesktopDrivePath.IsAncestorOrSame(parent, path)) ||
            changes.Any(change => change.Kind == CloudDriveChangeKind.CreateDirectory && change.IsPending &&
                change.RemotePath != path && DesktopDrivePath.IsAncestorOrSame(change.RemotePath, path)))
            throw new InvalidOperationException("cloud.sync.parent_pending");
    }

    private async Task<bool> AncestorsSafeAsync(string parent, CancellationToken token)
    {
        for (var path = parent; path != "/"; path = Parent(path))
        {
            var metadata = await repository.ReadFileMetadataAsync(path, token).ConfigureAwait(false);
            if (metadata is null || metadata.Item.Path != path || !metadata.Item.IsDirectory || !SafeMetadata(metadata) ||
                metadata.MountPointType is null || path == parent && !metadata.Item.CanWrite) return false;
        }
        return true;
    }
    private static bool SafeMetadata(FileEntryMetadata metadata) => metadata.Type is { Length: > 0 } &&
        !metadata.Type.Contains("link", StringComparison.OrdinalIgnoreCase) &&
        (metadata.MountPointType is null || metadata.MountPointType.Equals("normal", StringComparison.OrdinalIgnoreCase) ||
            metadata.MountPointType.Equals("shared_folder", StringComparison.OrdinalIgnoreCase));
    private async Task<CloudDrivePendingChange> FindAsync(Guid id, CancellationToken token) =>
        (await store.ReadChangesAsync(mapping, token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == id)
        ?? throw new InvalidDataException("cloud.sync.operation_missing");
    private async Task<CloudDrivePendingChange> ConflictAsync(CloudDrivePendingChange change, CancellationToken token)
    {
        await store.MarkConflictAsync(mapping, change.Id, token).ConfigureAwait(false);
        return change with { Phase = CloudDriveChangePhase.Conflict };
    }
    private void RequireContext()
    {
        if (!CloudDriveWriteScope.CanEnable(mapping) ||
            repository is not IFilePreviewRepository preview || preview.ProfileId != mapping.ProfileId)
            throw new InvalidOperationException("cloud.sync.context_changed");
    }
    private static string Parent(string path) => path[..Math.Max(1, path.LastIndexOf('/'))];
}
