using LanStash.Domain;

namespace LanStash.App.CloudDrive;

/// 移动与改名按固定顺序执行；步骤先落盘，未知回执不重新发送。
internal sealed class CloudDriveRelocationCoordinator(DesktopDriveMapping mapping, IDsmRepository repository, DesktopCloudDriveSyncStore store)
{
    internal async Task<CloudDriveRelocationOperation> StartAsync(string identity, string source, string destination,
        string localName, bool confirmed, CancellationToken token = default, bool? expectedDirectory = null)
    {
        RequireContext(source, destination);
        if (!confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
        using var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        if (!await store.IsWritebackEnabledAsync(mapping, token).ConfigureAwait(false)) throw new InvalidOperationException("cloud.sync.read_only");
        var steps = Plan(source, destination);
        RequireCapabilities(steps);
        var item = await ReadSourceAsync(source, token).ConfigureAwait(false);
        if (expectedDirectory is { } directory && item.IsDirectory != directory) throw new InvalidDataException("cloud.relocate.source_changed");
        if (!item.IsDirectory && await store.ReadVersionAsync(mapping, source, token).ConfigureAwait(false) is { } original)
        {
            var current = await CloudDriveRemoteRefresh.ReadCandidateAsync(item, repository, token).ConfigureAwait(false);
            if (current.Version != original) throw new InvalidDataException("cloud.sync.version_conflict");
        }
        foreach (var step in steps)
        {
            await RequireSafeAncestorsAsync(Parent(step.Destination), token).ConfigureAwait(false);
            if (await repository.ReadFileMetadataAsync(step.Destination, token).ConfigureAwait(false) is not null)
                throw new InvalidDataException("cloud.relocate.destination_exists");
        }
        var operation = new CloudDriveRelocationOperation(Guid.NewGuid(), identity, source, destination, localName,
            item.IsDirectory, item.Size, item.ModifiedAt, steps, 0, CloudDriveRelocationPhase.Prepared, DateTimeOffset.UtcNow);
        await store.AddRelocationOperationAsync(mapping, operation, token).ConfigureAwait(false);
        return await ExecuteAsync(operation, token).ConfigureAwait(false);
    }

    internal async Task<CloudDriveRelocationOperation> ContinueAsync(CloudDriveRelocationOperation expected, bool confirmed, CancellationToken token = default)
    {
        RequireContext(expected.Source, expected.Destination);
        if (!confirmed) throw new InvalidOperationException("cloud.sync.confirmation_required");
        using var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        var operation = await FindAsync(expected.Id, token).ConfigureAwait(false);
        if (!DesktopCloudDriveSyncStore.SameOperation(operation, expected)) throw new InvalidOperationException("cloud.relocate.state_changed");
        if (operation.Phase is CloudDriveRelocationPhase.Submitted or CloudDriveRelocationPhase.ServerVerified or CloudDriveRelocationPhase.Completed or CloudDriveRelocationPhase.Abandoned)
            return operation;
        return await ExecuteAsync(operation, token).ConfigureAwait(false);
    }

    internal async Task<CloudDriveRelocationOperation> ReviewAsync(Guid id, bool confirmedIdentity, CancellationToken token = default)
    {
        using var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        var operation = await FindAsync(id, token).ConfigureAwait(false);
        RequireContext(operation.Source, operation.Destination);
        if (operation.Phase != CloudDriveRelocationPhase.Submitted || !confirmedIdentity) return operation;
        // 路径消失/出现本身不能证明归属；用户核对后也只完成读取，不自动发出下一步写入。
        return await VerifyStepAsync(operation, token).ConfigureAwait(false);
    }

    internal async Task AbandonAsync(CloudDriveRelocationOperation expected, bool confirmed, CancellationToken token = default)
    {
        RequireContext(expected.Source, expected.Destination);
        if (!confirmed || expected.Step != 0 || expected.Phase is not (CloudDriveRelocationPhase.Prepared or CloudDriveRelocationPhase.Rejected))
            throw new InvalidOperationException("cloud.relocate.result_unknown");
        using var lease = await store.AcquireWritebackAsync(mapping, token).ConfigureAwait(false);
        await store.UpdateRelocationOperationAsync(mapping, expected, expected with { Phase = CloudDriveRelocationPhase.Abandoned }, token).ConfigureAwait(false);
    }

    private async Task<CloudDriveRelocationOperation> ExecuteAsync(CloudDriveRelocationOperation operation, CancellationToken token)
    {
        RequireCapabilities(operation.Steps);
        if (!await store.IsWritebackEnabledAsync(mapping, token).ConfigureAwait(false)) throw new InvalidOperationException("cloud.sync.read_only");
        while (operation.Step < operation.Steps.Count)
        {
            token.ThrowIfCancellationRequested();
            var step = operation.Steps[operation.Step];
            var source = await ReadSourceAsync(step.Source, token).ConfigureAwait(false);
            if (!Matches(source, operation)) throw new InvalidDataException("cloud.relocate.source_changed");
            await RequireSafeAncestorsAsync(Parent(step.Destination), token).ConfigureAwait(false);
            if (await repository.ReadFileMetadataAsync(step.Destination, token).ConfigureAwait(false) is not null)
                throw new InvalidDataException("cloud.relocate.destination_exists");
            if (step.Move && !source.CanDelete) throw new UnauthorizedAccessException("cloud.relocate.permission");
            var submitted = operation with { Phase = CloudDriveRelocationPhase.Submitted };
            await store.UpdateRelocationOperationAsync(mapping, operation, submitted, token).ConfigureAwait(false);
            operation = submitted;
            MutationResult result;
            try
            {
                if (step.Move)
                {
                    var request = new FileCopyMoveRequest(new(mapping.ProfileId, source.Path, source.Name, source.IsDirectory,
                        source.Size, source.ModifiedAt, true, source.CanDelete, false, false, false), Parent(step.Destination),
                        FileCopyMoveOperation.Move, true, false, false, false) { ConflictPolicy = FileCopyMoveConflictPolicy.Fail };
                    result = (await ((IFileCopyMoveRepository)repository).CopyMoveAsync(request, token).ConfigureAwait(false)).Result;
                }
                else
                    result = (await ((IFileMutationRepository)repository).RenameAsync(new(new(mapping.ProfileId, source.Path, source.Name,
                        source.IsDirectory, source.Size, source.ModifiedAt, source.CanWrite), Name(step.Destination)), token).ConfigureAwait(false)).Result;
            }
            catch { return operation; }
            if (result.Status is MutationResultStatus.ConfirmedFailure or MutationResultStatus.PermissionDenied or MutationResultStatus.Unsupported or MutationResultStatus.CancelledBeforeSubmission)
            {
                var rejected = operation with { Phase = CloudDriveRelocationPhase.Rejected };
                await store.UpdateRelocationOperationAsync(mapping, operation, rejected, CancellationToken.None).ConfigureAwait(false);
                return rejected;
            }
            if (result.Status != MutationResultStatus.ConfirmedSuccess) return operation;
            try { operation = await VerifyStepAsync(operation, token).ConfigureAwait(false); }
            catch { return operation; }
            if (operation.Phase != CloudDriveRelocationPhase.ReadyForNextStep) return operation;
        }
        return operation;
    }

    private async Task<CloudDriveRelocationOperation> VerifyStepAsync(CloudDriveRelocationOperation operation, CancellationToken token)
    {
        var step = operation.Steps[operation.Step];
        await RequireSafeAncestorsAsync(Parent(step.Destination), token).ConfigureAwait(false);
        if (await repository.ReadFileMetadataAsync(step.Source, token).ConfigureAwait(false) is not null) return operation;
        var target = await repository.ReadFileMetadataAsync(step.Destination, token).ConfigureAwait(false);
        if (target is null || !Safe(target) || target.Item.Path != step.Destination || !Matches(target.Item, operation)) return operation;
        var next = operation with { Step = operation.Step + 1,
            Phase = operation.Step + 1 == operation.Steps.Count ? CloudDriveRelocationPhase.ServerVerified : CloudDriveRelocationPhase.ReadyForNextStep };
        await store.UpdateRelocationOperationAsync(mapping, operation, next, token).ConfigureAwait(false);
        return next;
    }

    private async Task<FileItem> ReadSourceAsync(string path, CancellationToken token)
    {
        await RequireSafeAncestorsAsync(Parent(path), token).ConfigureAwait(false);
        var metadata = await repository.ReadFileMetadataAsync(path, token).ConfigureAwait(false);
        if (metadata is null || metadata.Item.Path != path || !metadata.Item.CanWrite || !Safe(metadata))
            throw new UnauthorizedAccessException("cloud.relocate.permission");
        return metadata.Item;
    }
    private async Task RequireSafeAncestorsAsync(string path, CancellationToken token)
    {
        var directParent = path;
        while (path != "/")
        {
            var metadata = await repository.ReadFileMetadataAsync(path, token).ConfigureAwait(false);
            if (metadata is null || metadata.Item.Path != path || !metadata.Item.IsDirectory || metadata.MountPointType is null ||
                !Safe(metadata) || path == directParent && !metadata.Item.CanWrite) throw new UnauthorizedAccessException("cloud.relocate.permission");
            path = Parent(path);
        }
    }
    private static bool Safe(FileEntryMetadata metadata) => metadata.Type is { Length: > 0 } && !metadata.Type.Contains("link", StringComparison.OrdinalIgnoreCase) &&
        (metadata.MountPointType is null || metadata.MountPointType.Equals("normal", StringComparison.OrdinalIgnoreCase) || metadata.MountPointType.Equals("shared_folder", StringComparison.OrdinalIgnoreCase));
    private static bool Matches(FileItem item, CloudDriveRelocationOperation operation) => item.IsDirectory == operation.IsDirectory &&
        (item.IsDirectory || item.Size == operation.Length && item.ModifiedAt == operation.ModifiedAt);
    private async Task<CloudDriveRelocationOperation> FindAsync(Guid id, CancellationToken token) =>
        (await store.ReadRelocationOperationsAsync(mapping, token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == id)
        ?? throw new InvalidDataException("cloud.relocate.operation_missing");
    private void RequireCapabilities(IReadOnlyList<CloudDriveRelocationStep> steps)
    {
        if (steps.Any(step => step.Move) && (repository is not IFileCopyMoveRepository move || move.ProfileId != mapping.ProfileId || !move.Availability.CanMove) ||
            steps.Any(step => !step.Move) && (repository is not IFileMutationRepository rename || rename.ProfileId != mapping.ProfileId || !rename.FileMutationAvailability.CanRename))
            throw new NotSupportedException("cloud.relocate.unsupported");
    }
    private void RequireContext(string source, string destination)
    {
        if (!CloudDriveWriteScope.CanWrite(mapping, source) || !CloudDriveWriteScope.CanWrite(mapping, destination) ||
            DesktopDrivePath.IsAncestorOrSame(source, destination) || repository is not IFilePreviewRepository preview || preview.ProfileId != mapping.ProfileId ||
            new[] { source, destination }.Any(path => path.Split('/').Any(part => part.Equals("#recycle", StringComparison.OrdinalIgnoreCase))))
            throw new InvalidDataException("cloud.relocate.invalid_path");
    }
    private static IReadOnlyList<CloudDriveRelocationStep> Plan(string source, string destination)
    {
        var steps = new List<CloudDriveRelocationStep>(); var current = source;
        if (Parent(source) != Parent(destination)) { var intermediate = Parent(destination) + "/" + Name(source); steps.Add(new(current, intermediate, true)); current = intermediate; }
        if (current != destination) steps.Add(new(current, destination, false));
        return steps;
    }
    private static string Parent(string path) => path[..Math.Max(1, path.LastIndexOf('/'))];
    private static string Name(string path) => path[(path.LastIndexOf('/') + 1)..];
}
