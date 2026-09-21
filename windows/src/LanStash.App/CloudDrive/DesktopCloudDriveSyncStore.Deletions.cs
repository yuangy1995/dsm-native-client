using LanStash.Domain;

namespace LanStash.App.CloudDrive;

internal sealed partial class DesktopCloudDriveSyncStore
{
    internal async Task<bool> IsDeletionEnabledAsync(DesktopDriveMapping mapping, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        return (await ReadAsync(mapping, token).ConfigureAwait(false)).DeletionEnabled;
    }

    internal async Task SetDeletionEnabledAsync(DesktopDriveMapping mapping, bool enabled, bool confirmed, CancellationToken token = default)
    {
        if (!confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        if (enabled && !state.WritebackEnabled) throw new InvalidOperationException("cloud.sync.read_only");
        if (!enabled && state.Deletions?.Any(item => item.IsPending) == true) throw new InvalidOperationException("cloud.delete.pending");
        await WriteAsync(mapping, WithDeletions(state) with { DeletionEnabled = enabled }, token).ConfigureAwait(false);
    }

    internal async Task<IReadOnlyList<CloudDriveDeletionOperation>> ReadDeletionOperationsAsync(DesktopDriveMapping mapping, CancellationToken token = default)
    {
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        return (await ReadAsync(mapping, token).ConfigureAwait(false)).Deletions?.ToArray() ?? [];
    }

    internal async Task AddDeletionOperationAsync(DesktopDriveMapping mapping, CloudDriveDeletionOperation operation, CancellationToken token = default)
    {
        ValidateDeletion(mapping, operation);
        if (operation.Phase != CloudDriveDeletionPhase.Prepared) throw new InvalidOperationException("cloud.delete.invalid_transition");
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        if (!state.WritebackEnabled || !state.DeletionEnabled) throw new InvalidOperationException("cloud.sync.read_only");
        if (state.Deletions?.Any(item => item.Id == operation.Id) == true) throw new InvalidOperationException("cloud.delete.duplicate_operation");
        CheckDeletionContent(state, operation.RemotePath);
        if (operation.IsDirectory && state.Deletions is { } previous)
        {
            // Shell 删除目录会先通知子项。尚未确认的子项合并到目录确认；已提交的操作绝不被吞并。
            state = state with { Deletions = previous.Select(item => item.Phase == CloudDriveDeletionPhase.Prepared &&
                item.RemotePath != operation.RemotePath && DesktopDrivePath.IsAncestorOrSame(operation.RemotePath, item.RemotePath)
                    ? item with { Phase = CloudDriveDeletionPhase.Abandoned } : item).ToList() };
        }
        CheckRelocationBlock(state, operation.RemotePath);
        await WriteAsync(mapping, WithDeletions(state) with { Deletions = [.. state.Deletions ?? [], operation] }, token).ConfigureAwait(false);
    }

    internal async Task UpdateDeletionOperationAsync(DesktopDriveMapping mapping, CloudDriveDeletionOperation expected,
        CloudDriveDeletionOperation replacement, CancellationToken token = default)
    {
        ValidateDeletion(mapping, replacement);
        var valid = (expected.Phase, replacement.Phase) is
            (CloudDriveDeletionPhase.Prepared, CloudDriveDeletionPhase.Submitted or CloudDriveDeletionPhase.Abandoned) or
            (CloudDriveDeletionPhase.Submitted, CloudDriveDeletionPhase.ServerVerified) or
            (CloudDriveDeletionPhase.ServerVerified, CloudDriveDeletionPhase.Completed);
        if (!valid || expected with { Phase = replacement.Phase } != replacement) throw new InvalidOperationException("cloud.delete.invalid_transition");
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        var operations = state.Deletions ?? throw new InvalidDataException("cloud.delete.operation_missing");
        var index = operations.FindIndex(item => item.Id == expected.Id);
        if (index < 0 || operations[index] != expected) throw new InvalidDataException("cloud.delete.state_changed");
        if (replacement.Phase == CloudDriveDeletionPhase.Submitted)
        {
            if (!state.WritebackEnabled || !state.DeletionEnabled) throw new InvalidOperationException("cloud.sync.read_only");
            CheckDeletionContent(state, expected.RemotePath);
        }
        operations[index] = replacement;
        await WriteAsync(mapping, state, token).ConfigureAwait(false);
    }

    private static Snapshot WithDeletions(Snapshot state) => state with
    {
        Version = Math.Max(8, state.Version), Deletions = state.Deletions ?? [], LocalNames = state.LocalNames ?? [],
        EmptyFileBaselines = state.EmptyFileBaselines ?? [], LocalCreations = state.LocalCreations ?? [],
        Relocations = state.Relocations ?? [], NamespaceOperations = state.NamespaceOperations ?? [],
    };

    internal async Task CompleteDeletionAsync(DesktopDriveMapping mapping, CloudDriveDeletionOperation expected,
        Func<CancellationToken, Task> finishLocalAndCatalog, CancellationToken token = default)
    {
        using var upload = await AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        using var lease = await AcquireAsync(mapping, token).ConfigureAwait(false);
        var state = await ReadAsync(mapping, token).ConfigureAwait(false);
        var operations = state.Deletions ?? throw new InvalidDataException("cloud.delete.operation_missing");
        var index = operations.FindIndex(item => item.Id == expected.Id);
        if (index < 0) throw new InvalidDataException("cloud.delete.operation_missing");
        if (operations[index] == expected with { Phase = CloudDriveDeletionPhase.Completed }) return;
        if (operations[index] != expected || expected.Phase != CloudDriveDeletionPhase.ServerVerified)
            throw new InvalidOperationException("cloud.delete.result_unknown");
        CheckDeletionContent(state, expected.RemotePath);
        token.ThrowIfCancellationRequested();
        await finishLocalAndCatalog(token).ConfigureAwait(false);
        // 本地失败/取消时保留 ServerVerified；重试只清理本地，不再次调用 NAS 删除。
        token.ThrowIfCancellationRequested();
        state.Versions.RemoveAll(item => DesktopDrivePath.IsAncestorOrSame(expected.RemotePath, item.RemotePath));
        foreach (var path in (state.EmptyFileBaselines ?? []).Keys.Where(path => DesktopDrivePath.IsAncestorOrSame(expected.RemotePath, path)).ToArray())
            state.EmptyFileBaselines!.Remove(path);
        operations[index] = expected with { Phase = CloudDriveDeletionPhase.Completed };
        await WriteAsync(mapping, state, token).ConfigureAwait(false);
    }

    private static void CheckDeletionContent(Snapshot state, string path)
    {
        if (state.Changes.Any(item => item.Phase != CloudDriveChangePhase.Verified && DesktopDrivePath.IsAncestorOrSame(path, item.RemotePath)) ||
            state.LocalCreations?.Keys.Any(item => DesktopDrivePath.IsAncestorOrSame(path, item)) == true)
            throw new InvalidOperationException("cloud.sync.pending_changes");
    }

    private static void CheckDeletionBlock(Snapshot state, string path)
    {
        if (state.Deletions?.Any(item => item.IsPending && (DesktopDrivePath.IsAncestorOrSame(item.RemotePath, path) ||
            DesktopDrivePath.IsAncestorOrSame(path, item.RemotePath))) == true) throw new InvalidOperationException("cloud.delete.pending");
    }

    private static void ValidateDeletion(DesktopDriveMapping mapping, CloudDriveDeletionOperation operation)
    {
        CloudDriveWriteScope.RequireWritable(mapping, operation.RemotePath);
        if (operation.Id == Guid.Empty || string.IsNullOrWhiteSpace(operation.ItemIdentity) || operation.Length < 0 || operation.ModifiedAt is null || !Enum.IsDefined(operation.Phase) ||
            operation.RemotePath.Split('/').Any(part => part.Equals("#recycle", StringComparison.OrdinalIgnoreCase)) ||
            operation.BaseVersion is { } version && (operation.IsDirectory || version.RemotePath != operation.RemotePath || version.Length != operation.Length))
            throw new InvalidDataException("cloud.delete.invalid_state");
        if (operation.BaseVersion is { } baseline) RequireVersion(baseline.Version, baseline.Length);
    }
}
