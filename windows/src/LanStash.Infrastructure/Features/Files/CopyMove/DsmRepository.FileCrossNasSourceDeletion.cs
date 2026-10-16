using System.Security.Cryptography;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<CrossNasCopyMoveOutcome?> DeleteCrossNasSourcesAsync(Guid operationId, bool confirmed,
        CancellationToken cancellationToken = default)
    {
        var transfer = FindCrossNasTransfer(operationId);
        if (transfer is null) return null;
        if (!confirmed || !CrossNasSnapshot(transfer).CanDeleteSources) return CrossNasSnapshot(transfer);
        if (!await transfer.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return CrossNasSnapshot(transfer);
        FileMutationSessionState? sourceOwner = null, targetOwner = null;
        HashSet<string>? sourcePaths = null, targetPaths = null;
        try
        {
            if (!CrossNasSnapshot(transfer).CanDeleteSources) return CrossNasSnapshot(transfer);
            transfer.Running = true;
            CrossNasExecuting.Value = transfer.Id;
            transfer.DeletionStarted = true;
            transfer.DeletionError = null;
            var target = ResolveCrossNasTarget(transfer);
            sourcePaths = transfer.Items.Select(item => item.Source.Item.Path).ToHashSet(StringComparer.Ordinal);
            targetPaths = transfer.Items.Select(item => item.DestinationPath).ToHashSet(StringComparer.Ordinal);
            sourceOwner = ReserveCrossNasDeletionPaths(this, sourcePaths);
            targetOwner = ReserveCrossNasDeletionPaths(target, targetPaths);
            await VerifyCrossNasRemainingSourcesAsync(transfer, cancellationToken).ConfigureAwait(false);
            await VerifyCrossNasTargetAsync(transfer, target, cancellationToken, updateCopyResults: false).ConfigureAwait(false);
            if (transfer.Items.Any(item => item.State != CrossNasTransferItemState.Copied))
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.target-content-changed");

            // 文件先于空目录；目录从深到浅，永远不让 Delete 递归处理未冻结的内容。
            var remaining = transfer.Items.Where(item => item.DeletionState == CrossNasSourceDeletionState.NotStarted)
                .OrderBy(item => item.Source.Item.IsDirectory ? 1 : 0)
                .ThenByDescending(item => item.Source.Item.Path.Count(value => value == '/')).ToArray();
            foreach (var item in remaining)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await VerifyCrossNasDeleteItemAsync(transfer, item, target, cancellationToken).ConfigureAwait(false);
                var marker = new FileMutationReview("crossNasDelete", MutationParent(item.Source.Item.Path),
                    item.Source.Item.Path, item.Source.Item.Path, item.Source.Item.IsDirectory, [item.Source.Item.Path]);
                item.DeleteMarker = marker; item.DeleteOwner = sourceOwner;
                lock (sourceOwner.Sync) sourceOwner.Reviews[marker.Key] = marker;
                item.DeleteTargetMarker = new FileMutationReview("crossNasDeleteTarget", MutationParent(item.DestinationPath),
                    item.DestinationPath, item.DestinationPath, item.Source.Item.IsDirectory, [item.DestinationPath]);
                item.DeleteTargetOwner = targetOwner;
                lock (targetOwner.Sync) targetOwner.Reviews[item.DeleteTargetMarker.Key] = item.DeleteTargetMarker;
                item.DeletionState = CrossNasSourceDeletionState.Deleting;
                // 先记下提交边界。任何传输异常都不能回到可重发状态。
                item.DeleteSubmitted = true;
                try { await SaveCrossNasAsync(transfer).ConfigureAwait(false); }
                catch { item.DeleteSubmitted = false; item.DeletionState = CrossNasSourceDeletionState.NotStarted; ClearCrossNasDeleteMarker(item); throw; }
                try
                {
                    var response = await _api.StartNonRecursiveFileDeleteAsync(_profile, _session,
                        _capabilities["SYNO.FileStation.Delete"], item.Source.Item.Path, cancellationToken).ConfigureAwait(false);
                    switch (response.Status)
                    {
                        case FileMutationTransportStatus.ResponseReceived when !string.IsNullOrWhiteSpace(response.TaskId):
                            item.DeleteTaskId = response.TaskId;
                            await SaveCrossNasAsync(transfer).ConfigureAwait(false);
                            item.DeletionState = CrossNasSourceDeletionState.ResultUnavailable;
                            await ReviewCrossNasDeleteItemAsync(item, cancellationToken, attempts: 10).ConfigureAwait(false);
                            break;
                        case FileMutationTransportStatus.CancelledBeforeSubmission:
                            item.DeleteSubmitted = false;
                            item.DeletionState = CrossNasSourceDeletionState.NotStarted;
                            ClearCrossNasDeleteMarker(item);
                            break;
                        case FileMutationTransportStatus.ConfirmedFailure:
                        case FileMutationTransportStatus.Unsupported:
                            item.DeleteSubmitted = false;
                            item.DeletionState = CrossNasSourceDeletionState.Failed;
                            transfer.DeletionError = UploadFailure(response.ErrorCategory ?? MutationErrorCategory.Server,
                                response.DiagnosticTag ?? "file.cross-nas.delete-rejected");
                            ClearCrossNasDeleteMarker(item);
                            break;
                        default:
                            item.DeletionState = CrossNasSourceDeletionState.ResultUnavailable;
                            break;
                    }
                }
                catch
                {
                    item.DeletionState = CrossNasSourceDeletionState.ResultUnavailable;
                    throw;
                }
                await SaveCrossNasAsync(transfer).ConfigureAwait(false);
                if (item.DeletionState != CrossNasSourceDeletionState.Deleted) break;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { transfer.DeletionError = CrossNasDeletionError(error); }
        finally
        {
            ReleaseCrossNasDeletionPaths(sourceOwner, sourcePaths);
            ReleaseCrossNasDeletionPaths(targetOwner, targetPaths);
            transfer.Running = false;
            await FinishCrossNasCheckpointAsync(transfer).ConfigureAwait(false);
            transfer.Gate.Release();
            CrossNasExecuting.Value = null;
        }
        return CrossNasSnapshot(transfer);
    }

    private static FileMutationSessionState ReserveCrossNasDeletionPaths(DsmRepository repository, HashSet<string> paths)
    {
        if (repository.CrossNasRecoveryConflicts(paths)) throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.target-busy");
        var owner = repository.FileMutationState();
        lock (owner.Sync)
        {
            if (repository.OfficeEditingConflicts(paths)) throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.target-busy");
            if (owner.ActiveTargets.Concat(owner.Reviews.Values.SelectMany(review => review.Targets))
                .Any(existing => paths.Any(path => CrossNasPathsOverlap(existing, path))))
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.target-busy");
            var copyMoves = repository.FileCopyMoveState();
            lock (copyMoves.Sync)
                if (CopyMoveTargetsOverlap(copyMoves.ActiveTargets.Concat(copyMoves.Reviews.Values.SelectMany(review => review.Targets)), paths))
                    throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.target-busy");
            var recycles = repository.FileRecycleState();
            lock (recycles.Sync)
                if (FileRecycleTargetsOverlap(recycles.ActiveTargets.Concat(recycles.Reviews.Values.SelectMany(review => review.Targets)), paths))
                    throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.target-busy");
            owner.ActiveTargets.UnionWith(paths);
            owner.CrossNasDeletionTargets.UnionWith(paths);
        }
        return owner;
    }

    private static void ReleaseCrossNasDeletionPaths(FileMutationSessionState? owner, HashSet<string>? paths)
    {
        if (owner is null || paths is null) return;
        lock (owner.Sync)
        {
            owner.ActiveTargets.ExceptWith(paths);
            owner.CrossNasDeletionTargets.ExceptWith(paths);
        }
    }
    // 在既有会话互斥中补上删源的祖先/后代保护，不建立第二套文件执行器。
    private static bool CrossNasDeletionConflicts(FileMutationSessionState owner, IEnumerable<string> paths) =>
        owner.CrossNasDeletionTargets.Concat(owner.Reviews.Values.Where(review => review.Operation is "crossNasDelete" or "crossNasDeleteTarget")
            .SelectMany(review => review.Targets)).Any(existing => paths.Any(path => CrossNasPathsOverlap(existing, path)));

    private async Task ReviewCrossNasSourceDeletionAsync(CrossNasTransfer transfer, CancellationToken token)
    {
        try
        {
            var target = ResolveCrossNasTarget(transfer);
            transfer.DeletionError = null;
            foreach (var item in transfer.Items.Where(item => item.DeletionState == CrossNasSourceDeletionState.ResultUnavailable))
                await ReviewCrossNasDeleteItemAsync(item, token).ConfigureAwait(false);
            // 只读刷新从不重启删除；未知有回执可继续查询，丢回执保持未知。
            if (transfer.Items.All(item => item.DeletionState is CrossNasSourceDeletionState.Deleted or CrossNasSourceDeletionState.NotStarted))
            {
                await VerifyCrossNasRemainingSourcesAsync(transfer, token).ConfigureAwait(false);
                if (transfer.Items.Any(item => item.DeletionState == CrossNasSourceDeletionState.NotStarted))
                    await VerifyCrossNasTargetAsync(transfer, target, token, updateCopyResults: false).ConfigureAwait(false);
            }
        }
        catch (Exception error) { transfer.DeletionError = CrossNasDeletionError(error); }
    }

    private async Task ReviewCrossNasDeleteItemAsync(CrossNasTransferItem item, CancellationToken token, int attempts = 1)
    {
        if (!item.DeleteSubmitted || item.DeleteTaskId is null) return;
        FileRecycleTaskTransportResult status;
        var attempt = 0;
        do
        {
            if (attempt > 0) await Task.Delay(200, token).ConfigureAwait(false);
            status = await _api.ReadFileRecycleStatusAsync(_profile, _session, _capabilities["SYNO.FileStation.Delete"],
                item.DeleteTaskId, token).ConfigureAwait(false);
            attempt++;
        } while (status.Status == FileRecycleTaskTransportStatus.Running && attempt < attempts);
        if (status.Status == FileRecycleTaskTransportStatus.ConfirmedFailure)
        {
            item.DeletionState = CrossNasSourceDeletionState.Failed;
            ClearCrossNasDeleteMarker(item);
            return;
        }
        if (status.Status != FileRecycleTaskTransportStatus.Finished) return;
        var children = await LoadCrossNasChildrenAsync(this, MutationParent(item.Source.Item.Path), token).ConfigureAwait(false);
        if (children.Any(child => child.Path == item.Source.Item.Path)) return;
        item.DeletionState = CrossNasSourceDeletionState.Deleted;
        ClearCrossNasDeleteMarker(item);
    }

    private async Task VerifyCrossNasRemainingSourcesAsync(CrossNasTransfer transfer, CancellationToken token)
    {
        var remaining = transfer.Items.Where(item => item.DeletionState != CrossNasSourceDeletionState.Deleted).ToArray();
        if (remaining.Length == 0) return;
        var changedDirectories = transfer.Items.Any(item => item.DeletionState == CrossNasSourceDeletionState.Deleted);
        if (transfer.Request.IsDirectory)
        {
            var tree = await LoadCrossNasTreeAsync(this, transfer.Request.SourcePath, token).ConfigureAwait(false);
            var expected = remaining.Where(item => item.RelativePath.Length > 0).ToDictionary(item => item.Source.Item.Path, StringComparer.Ordinal);
            if (tree.Count != expected.Count || tree.Any(row => !expected.TryGetValue(row.Item.Path, out var original) ||
                !CrossNasSameRemainingFile(row.Item, original.Source.Item, changedDirectories)))
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-tree-changed");
        }
        foreach (var item in remaining)
        {
            var current = await ReadFileMetadataAsync(item.Source.Item.Path, token).ConfigureAwait(false);
            if (current is null || CrossNasUnsafeMetadata(current) ||
                !CrossNasSameRemainingFile(current.Item, item.Source.Item, changedDirectories))
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-changed");
            if (!current.Item.CanDelete)
                throw new CrossNasPreflightException(MutationErrorCategory.Permission, "file.cross-nas.delete-denied");
            if (!current.Item.IsDirectory) await VerifyCrossNasSourceHashAsync(item, token).ConfigureAwait(false);
        }
    }

    private async Task VerifyCrossNasDeleteItemAsync(CrossNasTransfer transfer, CrossNasTransferItem item, DsmRepository target, CancellationToken token)
    {
        var current = await ReadFileMetadataAsync(item.Source.Item.Path, token).ConfigureAwait(false);
        if (current is null || CrossNasUnsafeMetadata(current) ||
            !CrossNasSameRemainingFile(current.Item, item.Source.Item, transfer.Items.Any(row => row.DeletionState == CrossNasSourceDeletionState.Deleted)))
            throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-changed");
        if (!current.Item.CanDelete) throw new CrossNasPreflightException(MutationErrorCategory.Permission, "file.cross-nas.delete-denied");
        if (current.Item.IsDirectory)
        {
            if ((await LoadCrossNasChildrenAsync(this, current.Item.Path, token).ConfigureAwait(false)).Count != 0)
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-directory-not-empty");
            var targetFolder = await target.ReadFileMetadataAsync(item.DestinationPath, token).ConfigureAwait(false);
            if (targetFolder is null || !targetFolder.Item.IsDirectory || CrossNasUnsafeMetadata(targetFolder))
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.target-content-changed");
        }
        else
        {
            await VerifyCrossNasSourceHashAsync(item, token).ConfigureAwait(false);
            var confirmed = await target.ReviewFileUploadCoreAsync((transfer.TargetScope, item.DestinationPath), item.Upload!, token, validateCompleted: true).ConfigureAwait(false);
            if (confirmed.Status != MutationResultStatus.ConfirmedSuccess)
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.target-content-changed");
            if (await ReadFileMetadataAsync(item.Source.Item.Path, token).ConfigureAwait(false) != current)
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-changed");
        }
    }

    private async Task VerifyCrossNasSourceHashAsync(CrossNasTransferItem item, CancellationToken token)
    {
        if (item.Upload is not { Accepted: true, Hash: { } expected })
            throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.copy-receipt-missing");
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        long offset = 0; string? version = null;
        while (offset < item.Source.Item.Size)
        {
            var range = await ReadFileRangeResultAsync(item.Source.Item.Path, offset,
                Math.Min(CrossNasChunkSize, item.Source.Item.Size - offset), version, item.Source.Item.Size, token).ConfigureAwait(false);
            EnsureCrossNasRange(range, offset, item.Source.Item.Size);
            if (offset > 0 && range.ServerContentVersion != version)
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-version-changed");
            version ??= range.ServerContentVersion;
            hash.AppendData(range.Bytes); offset += range.ActualByteCount;
        }
        if (Convert.ToHexString(hash.GetHashAndReset()) != expected)
            throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-content-changed");
    }

    private static bool CrossNasSameRemainingFile(FileItem current, FileItem original, bool changedDirectories) =>
        CrossNasSameFile(changedDirectories && current.IsDirectory ? current with { ModifiedAt = original.ModifiedAt } : current, original);
    private static void ClearCrossNasDeleteMarker(CrossNasTransferItem item)
    {
        if (item.DeleteOwner is { } owner && item.DeleteMarker is { } marker)
            lock (owner.Sync) owner.Reviews.Remove(marker.Key);
        if (item.DeleteTargetOwner is { } targetOwner && item.DeleteTargetMarker is { } targetMarker)
            lock (targetOwner.Sync) targetOwner.Reviews.Remove(targetMarker.Key);
    }
    private static MutationResult CrossNasDeletionError(Exception error) => UploadFailure(
        error is CrossNasPreflightException rejected ? rejected.Category :
        error is DsmException { AuthenticationFailure: true } ? MutationErrorCategory.Authentication : MutationErrorCategory.Network,
        error is CrossNasPreflightException known ? known.Message : "file.cross-nas.delete-readback-unavailable");
    private static CrossNasSourceDeletionOutcome CrossNasDeletionSnapshot(CrossNasTransfer transfer)
    {
        var rows = transfer.Items.Select(item => new CrossNasSourceDeletionItem(item.Source.Item.Path, item.Source.Item.IsDirectory, item.DeletionState)).ToArray();
        var succeeded = rows.Count(item => item.State == CrossNasSourceDeletionState.Deleted);
        var failed = rows.Count(item => item.State == CrossNasSourceDeletionState.Failed);
        var unknown = rows.Count(item => item.State is CrossNasSourceDeletionState.Deleting or CrossNasSourceDeletionState.ResultUnavailable);
        var status = succeeded == rows.Length && rows.Length > 0 ? MutationResultStatus.ConfirmedSuccess : unknown > 0 ? MutationResultStatus.SubmittedButUnverified :
            succeeded > 0 && failed > 0 ? MutationResultStatus.PartialSuccess : MutationResultStatus.ConfirmedFailure;
        return new(new(1, status, "crossNasDeleteSources", transfer.Items.Any(item => item.DeleteSubmitted), unknown > 0,
            new(succeeded, failed, unknown), transfer.DeletionError?.ErrorCategory, diagnosticTag: transfer.DeletionError?.DiagnosticTag), rows);
    }
}
