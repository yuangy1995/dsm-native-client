using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int CrossNasChunkSize = 4 * 1024 * 1024;
    private const int CrossNasPipeCapacity = 12 * 1024 * 1024;
    private const int CrossNasFolderPageSize = 500;
    private const int CrossNasFolderItemLimit = 5000;
    private const int CrossNasFolderDepthLimit = 128;

    public CrossNasCopyMoveAvailability CrossNasAvailability => new(
        CanCrossCopy: !CrossNasRecoveryUnavailable && CrossNasSourceTransferAvailable(), CanCrossMove: CrossNasSourceDeletionEnabled &&
            CrossNasSourceTransferAvailable() && MutationCapability("SYNO.FileStation.Delete", 2));
    // PENDING_USER_VALIDATION：真实 NAS 的非递归删除、权限和外部并发窗口验收后才开放。
    internal bool CrossNasSourceDeletionEnabled { get; set; }
    private bool CrossNasSourceTransferAvailable() =>
        FileContentCapability("SYNO.FileStation.Download", 2) && FileContentCapability("SYNO.FileStation.List", 2);
    public bool CanReceiveCrossNasCopy => FileContentUploadAvailable;
    public string? GetCrossNasTargetIdentity(Guid targetProfileId) => CrossNasRepositoryResolver?.Invoke(targetProfileId)?.ServiceScope();

    public async Task<IReadOnlyList<CrossNasTransferSummary>> GetCrossNasTransfersAsync(CancellationToken cancellationToken = default)
    {
        await InitializeCrossNasRecoveryAsync().ConfigureAwait(false);
        if (CrossNasRecoveryUnavailable) throw new IOException("file.cross-nas.recovery-unavailable");
        cancellationToken.ThrowIfCancellationRequested();
        var scope = ServiceScope();
        lock (CrossNasTransfers)
            return CrossNasTransfers
                .Where(pair => pair.Key.Scope == scope).Select(pair =>
                {
                    var task = pair.Value; var request = task.Request;
                    return new CrossNasTransferSummary(task.Id, ProfileId, request.TargetProfileId, request.SourcePath,
                        request.DestinationFolderPath, request.SourceName, request.IsDirectory, request.FileSize, CrossNasSnapshot(task));
                }).ToArray();
    }

    public async Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(CrossNasCopyMoveRequest request,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        await InitializeCrossNasRecoveryAsync().ConfigureAwait(false);
        if (CrossNasRecoveryUnavailable) return CrossNasRejected(request, MutationErrorCategory.Unknown, "file.cross-nas.recovery-unavailable");
        if (request.Operation != CrossNasCopyMoveOperation.Copy &&
            (request.Operation != CrossNasCopyMoveOperation.Move || !CrossNasAvailability.CanCrossMove))
            return CrossNasRejected(request, MutationErrorCategory.Unsupported, "file.cross-nas.move-disabled");
        if (!CrossNasSourceTransferAvailable())
            return CrossNasRejected(request, MutationErrorCategory.Unsupported, "file.cross-nas.source-no-capability");
        if (request.SourceProfileId != ProfileId || _session.ProfileId != ProfileId ||
            request.SourceProfileId == request.TargetProfileId || request.FileSize < 0 || request.Overwrite ||
            !ValidMutationObjectPath(request.SourcePath) || !ValidMutationDirectory(request.DestinationFolderPath) ||
            !ValidMutationItemName(request.SourceName) || !request.SourcePath.EndsWith("/" + request.SourceName, StringComparison.Ordinal) ||
            ArchiveContainsRecycleSegment(request.SourcePath) || ArchiveContainsRecycleSegment(request.DestinationFolderPath))
            return CrossNasRejected(request, MutationErrorCategory.Validation, "file.cross-nas.invalid-request");
        var target = CrossNasRepositoryResolver?.Invoke(request.TargetProfileId);
        if (target is null || target.ProfileId != request.TargetProfileId || target._session.ProfileId != target.ProfileId)
            return CrossNasRejected(request, MutationErrorCategory.Unsupported, "file.cross-nas.target-not-found");
        if (!target.CanReceiveCrossNasCopy || request.IsDirectory && !target.FileMutationAvailability.CanCreateFolder)
            return CrossNasRejected(request, MutationErrorCategory.Unsupported, "file.cross-nas.target-no-capability");
        if (cancellationToken.IsCancellationRequested)
            return CrossNasRejected(request, null, "file.cross-nas.cancelled-before-submit", MutationResultStatus.CancelledBeforeSubmission);

        var scope = ServiceScope(); var targetScope = target.ServiceScope();
        if (request.TargetIdentity is not null && request.TargetIdentity != targetScope)
            return CrossNasRejected(request, MutationErrorCategory.Authentication, "file.cross-nas.target-session-changed");
        var destination = JoinMutationPath(request.DestinationFolderPath, request.SourceName);
        CrossNasTransfer transfer;
        lock (CrossNasTransfers)
        {
            if (request.OperationId != Guid.Empty && CrossNasTransfers.TryGetValue((scope, request.OperationId), out var existing))
                return existing.Request == request && existing.TargetScope == targetScope ? CrossNasSnapshot(existing) :
                    CrossNasRejected(request, MutationErrorCategory.Conflict, "file.cross-nas.operation-mismatch");
            if (request.OperationId != Guid.Empty && CrossNasTransfers.Values.Any(item => item.Id == request.OperationId))
                return CrossNasRejected(request, MutationErrorCategory.Conflict, "file.cross-nas.operation-owner-mismatch");
            var overlapping = CrossNasTransfers.Values.FirstOrDefault(item => item.SourceScope == scope &&
                item.TargetScope == targetScope && (item.Running || item.HasSubmitted && !item.Verified) &&
                CrossNasPathsOverlap(item.DestinationPath, destination));
            if (overlapping is not null)
                return overlapping.Request.SourcePath == request.SourcePath && overlapping.DestinationPath == destination
                    ? CrossNasSnapshot(overlapping) : CrossNasRejected(request, MutationErrorCategory.Conflict, "file.cross-nas.target-busy");
            transfer = new(request.OperationId == Guid.Empty ? Guid.NewGuid() : request.OperationId, request, scope, targetScope, destination);
            CrossNasTransfers.Add((scope, transfer.Id), transfer);
            transfer.Running = true;
        }
        CrossNasExecuting.Value = transfer.Id;
        await transfer.Gate.WaitAsync().ConfigureAwait(false);
        try
        {
            transfer.Items = await BuildCrossNasPlanAsync(request, destination, cancellationToken).ConfigureAwait(false);
            var parent = await target.ReadFileMetadataAsync(request.DestinationFolderPath, cancellationToken).ConfigureAwait(false);
            if (parent is null || !parent.Item.IsDirectory || CrossNasUnsafeMetadata(parent, allowShare: true))
                throw new CrossNasPreflightException(MutationErrorCategory.Validation, "file.cross-nas.invalid-destination");
            if (await target.ReadFileMetadataAsync(destination, cancellationToken).ConfigureAwait(false) is not null)
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.target-exists");
            await RunCrossNasPlanAsync(transfer, target, progress, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) { RecordCrossNasError(transfer, error); }
        finally { transfer.Running = false; await FinishCrossNasCheckpointAsync(transfer).ConfigureAwait(false); transfer.Gate.Release(); CrossNasExecuting.Value = null; }
        return CrossNasSnapshot(transfer);
    }

    public async Task<CrossNasCopyMoveOutcome?> ReviewCrossNasTransferAsync(Guid operationId, CancellationToken cancellationToken = default)
    {
        var transfer = FindCrossNasTransfer(operationId);
        if (transfer is null) return null;
        if (!await transfer.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return CrossNasSnapshot(transfer);
        try
        {
            if (transfer.DeletionStarted)
            {
                await ReviewCrossNasSourceDeletionAsync(transfer, cancellationToken).ConfigureAwait(false);
                transfer.RestoredNeedsReview = false;
                return CrossNasSnapshot(transfer);
            }
            if (!transfer.HasSubmitted && transfer.Error is not null) return CrossNasSnapshot(transfer);
            transfer.Verified = false;
            var target = ResolveCrossNasTarget(transfer);
            transfer.Error = null;
            foreach (var item in transfer.Items.Where(item => item.State == CrossNasTransferItemState.ResultUnavailable))
            {
                if (item.Upload is { } upload)
                {
                    // 复用原回执与摘要；恢复绝不进入上传分支。
                    var result = await target.ReviewFileUploadCoreAsync((transfer.TargetScope, item.DestinationPath), upload, cancellationToken, validateCompleted: true).ConfigureAwait(false);
                    SetCrossNasItemResult(item, result);
                }
                else if (item.FolderReview is { Accepted: true } review)
                {
                    var metadata = await target.ReadFileMetadataAsync(item.DestinationPath, cancellationToken).ConfigureAwait(false);
                    if (metadata is not null && metadata.Item.IsDirectory && !CrossNasUnsafeMetadata(metadata))
                    {
                        item.Result = MutationOutcome("createFolder", MutationResultStatus.ConfirmedSuccess, true, false, null, null, metadata.Item).Result;
                        item.State = CrossNasTransferItemState.Copied;
                        if (item.FolderOwner is { } owner) lock (owner.Sync) owner.Reviews.Remove(review.Key);
                    }
                }
            }
            await VerifyCrossNasPlanAsync(transfer, target, cancellationToken).ConfigureAwait(false);
            transfer.RestoredNeedsReview = false;
        }
        catch (Exception error) { RecordCrossNasError(transfer, error); }
        finally { await FinishCrossNasCheckpointAsync(transfer).ConfigureAwait(false); transfer.Gate.Release(); }
        return CrossNasSnapshot(transfer);
    }

    public async Task<CrossNasCopyMoveOutcome?> ContinueCrossNasTransferAsync(Guid operationId, IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var transfer = FindCrossNasTransfer(operationId);
        if (transfer is null) return null;
        if (!await transfer.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return CrossNasSnapshot(transfer);
        try
        {
            if (!CrossNasCanContinue(transfer)) return CrossNasSnapshot(transfer);
            transfer.Running = true;
            CrossNasExecuting.Value = transfer.Id;
            var target = ResolveCrossNasTarget(transfer);
            transfer.Error = null;
            await VerifyCrossNasSourceAsync(transfer, cancellationToken).ConfigureAwait(false);
            await RunCrossNasPlanAsync(transfer, target, progress, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) { RecordCrossNasError(transfer, error); }
        finally { transfer.Running = false; await FinishCrossNasCheckpointAsync(transfer).ConfigureAwait(false); transfer.Gate.Release(); CrossNasExecuting.Value = null; }
        return CrossNasSnapshot(transfer);
    }

    private CrossNasTransfer? FindCrossNasTransfer(Guid id)
    {
        lock (CrossNasTransfers)
            return CrossNasTransfers.GetValueOrDefault((ServiceScope(), id));
    }
    private DsmRepository ResolveCrossNasTarget(CrossNasTransfer transfer)
    {
        var target = CrossNasRepositoryResolver?.Invoke(transfer.Request.TargetProfileId);
        if (target is null || target.ProfileId != transfer.Request.TargetProfileId || target.ServiceScope() != transfer.TargetScope ||
            target._session.ProfileId != target.ProfileId)
            throw new CrossNasPreflightException(MutationErrorCategory.Authentication, "file.cross-nas.target-session-changed");
        return target;
    }

    private async Task<CrossNasTransferItem[]> BuildCrossNasPlanAsync(CrossNasCopyMoveRequest request, string destination, CancellationToken token)
    {
        var root = await ReadFileMetadataAsync(request.SourcePath, token).ConfigureAwait(false);
        if (root is null || root.Item.Name != request.SourceName || root.Item.IsDirectory != request.IsDirectory ||
            !request.IsDirectory && root.Item.Size != request.FileSize || CrossNasUnsafeMetadata(root) ||
            request.SourceModifiedAt is not null && request.SourceModifiedAt != root.Item.ModifiedAt)
            throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-changed");
        var plan = new List<CrossNasTransferItem> { new(root, destination, string.Empty) };
        if (request.IsDirectory)
        {
            var tree = await LoadCrossNasTreeAsync(this, request.SourcePath, token).ConfigureAwait(false);
            foreach (var item in tree.OrderBy(item => item.Item.IsDirectory ? 0 : 1)
                         .ThenBy(item => item.RelativePath.Count(c => c == '/')).ThenBy(item => item.RelativePath, StringComparer.Ordinal))
            {
                var metadata = await ReadFileMetadataAsync(item.Item.Path, token).ConfigureAwait(false);
                if (metadata is null || CrossNasUnsafeMetadata(metadata) || !CrossNasSameFile(metadata.Item, item.Item))
                    throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-changed");
                plan.Add(new(metadata, destination + "/" + item.RelativePath, item.RelativePath));
            }
        }
        _ = plan.Where(item => !item.Source.Item.IsDirectory).Aggregate(0L, (total, item) => checked(total + checked(item.Source.Item.Size * 2)));
        return plan.ToArray();
    }

    private async Task RunCrossNasPlanAsync(CrossNasTransfer transfer, DsmRepository target, IProgress<long>? progress, CancellationToken token)
    {
        long completed = transfer.Items.Where(item => item.State == CrossNasTransferItemState.Copied && !item.Source.Item.IsDirectory)
            .Aggregate(0L, (total, item) => checked(total + checked(item.Source.Item.Size * 2)));
        foreach (var item in transfer.Items.Where(item => item.State == CrossNasTransferItemState.NotStarted))
        {
            token.ThrowIfCancellationRequested();
            if (!CrossNasSameMetadata(await ReadFileMetadataAsync(item.Source.Item.Path, token).ConfigureAwait(false), item.Source))
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-changed");
            item.State = CrossNasTransferItemState.Copying;
            try { await SaveCrossNasAsync(transfer).ConfigureAwait(false); }
            catch { item.State = CrossNasTransferItemState.NotStarted; throw; }
            try
            {
                MutationResult result;
                if (item.Source.Item.IsDirectory)
                {
                    var owner = target.FileMutationState();
                    try
                    {
                        var outcome = await target.CreateFolderCoreAsync(new(target.ProfileId, MutationParent(item.DestinationPath), item.Source.Item.Name), token, async review =>
                        { item.FolderReview = review; item.FolderOwner = owner; transfer.HasSubmitted = true; await SaveCrossNasAsync(transfer).ConfigureAwait(false); }).ConfigureAwait(false);
                        result = outcome.Result;
                    }
                    finally
                    {
                        lock (owner.Sync) item.FolderReview ??= owner.Reviews.Values.SingleOrDefault(review => review.Operation == "createFolder" && review.NewPath == item.DestinationPath);
                        item.FolderOwner = owner;
                    }
                }
                else result = await CopyCrossNasFileAsync(transfer, target, item, completed, progress, token).ConfigureAwait(false);
                SetCrossNasItemResult(item, result);
                transfer.HasSubmitted |= result.Submitted;
                await SaveCrossNasAsync(transfer).ConfigureAwait(false);
                if (item.State != CrossNasTransferItemState.Copied) break;
                if (!item.Source.Item.IsDirectory) completed = checked(completed + checked(item.Source.Item.Size * 2));
            }
            catch (Exception)
            {
                item.State = CrossNasTransferItemState.ResultUnavailable;
                item.Result = UploadUnverified("file.cross-nas.result-unavailable");
                transfer.HasSubmitted = true;
                throw;
            }
        }
        await VerifyCrossNasPlanAsync(transfer, target, token).ConfigureAwait(false);
    }

    private async Task VerifyCrossNasPlanAsync(CrossNasTransfer transfer, DsmRepository target, CancellationToken token)
    {
        transfer.Verified = false;
        if (transfer.Items.Length == 0 || transfer.Items.Any(item => item.State != CrossNasTransferItemState.Copied)) return;
        await VerifyCrossNasSourceAsync(transfer, token).ConfigureAwait(false);
        await VerifyCrossNasTargetAsync(transfer, target, token).ConfigureAwait(false);
        if (transfer.Items.All(item => item.State == CrossNasTransferItemState.Copied)) transfer.Verified = true;
    }

    private static async Task VerifyCrossNasTargetAsync(CrossNasTransfer transfer, DsmRepository target, CancellationToken token, bool updateCopyResults = true)
    {
        foreach (var item in transfer.Items)
        {
            if (item.Upload is { } upload)
            {
                var result = await target.ReviewFileUploadCoreAsync((transfer.TargetScope, item.DestinationPath), upload, token, validateCompleted: true).ConfigureAwait(false);
                if (updateCopyResults) SetCrossNasItemResult(item, result);
                if (result.Status != MutationResultStatus.ConfirmedSuccess)
                {
                    if (!updateCopyResults) throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.target-content-changed");
                    return;
                }
            }
            else
            {
                var current = await target.ReadFileMetadataAsync(item.DestinationPath, token).ConfigureAwait(false);
                if (current is null || !current.Item.IsDirectory || CrossNasUnsafeMetadata(current))
                    throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.tree-readback-mismatch");
            }
        }
        if (transfer.Request.IsDirectory)
        {
            var actual = await LoadCrossNasTreeAsync(target, transfer.DestinationPath, token).ConfigureAwait(false);
            var expected = transfer.Items.Skip(1).ToDictionary(item => item.RelativePath, StringComparer.Ordinal);
            if (actual.Count != expected.Count || actual.Any(row => !expected.TryGetValue(row.RelativePath, out var planned) ||
                row.Item.IsDirectory != planned.Source.Item.IsDirectory || !row.Item.IsDirectory && row.Item.Size != planned.Source.Item.Size))
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.tree-readback-mismatch");
        }
    }

    private async Task VerifyCrossNasSourceAsync(CrossNasTransfer transfer, CancellationToken token)
    {
        if (transfer.Request.IsDirectory)
        {
            var tree = await LoadCrossNasTreeAsync(this, transfer.Request.SourcePath, token).ConfigureAwait(false);
            var expected = transfer.Items.Skip(1).ToDictionary(item => item.Source.Item.Path, StringComparer.Ordinal);
            if (tree.Count != expected.Count || tree.Any(row => !expected.TryGetValue(row.Item.Path, out var original) || !CrossNasSameFile(row.Item, original.Source.Item)))
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-tree-changed");
        }
        foreach (var item in transfer.Items)
            if (!CrossNasSameMetadata(await ReadFileMetadataAsync(item.Source.Item.Path, token).ConfigureAwait(false), item.Source))
                throw new CrossNasPreflightException(MutationErrorCategory.Conflict, "file.cross-nas.source-changed");
    }

    private static void SetCrossNasItemResult(CrossNasTransferItem item, MutationResult result)
    {
        item.Result = result;
        item.State = result.Status switch
        {
            MutationResultStatus.ConfirmedSuccess => CrossNasTransferItemState.Copied,
            MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission => CrossNasTransferItemState.ResultUnavailable,
            MutationResultStatus.CancelledBeforeSubmission => CrossNasTransferItemState.NotStarted,
            _ => CrossNasTransferItemState.Failed,
        };
    }
    private bool CrossNasCanContinue(CrossNasTransfer transfer) => !CrossNasRecoveryUnavailable && !transfer.RestoredNeedsReview && !transfer.DeletionStarted && !transfer.Running && transfer.Error is null && transfer.Items.Length > 0 &&
        transfer.Items.Any(item => item.State == CrossNasTransferItemState.NotStarted) &&
        transfer.Items.All(item => item.State is CrossNasTransferItemState.NotStarted or CrossNasTransferItemState.Copied);

    private CrossNasCopyMoveOutcome CrossNasSnapshot(CrossNasTransfer transfer)
    {
        var rows = transfer.Items.Select(item => new CrossNasTransferItemResult(item.Source.Item.Path, item.DestinationPath,
            item.Source.Item.IsDirectory, item.State, item.Result)).ToArray();
        var succeeded = rows.Count(item => item.State == CrossNasTransferItemState.Copied);
        var failed = rows.Count(item => item.State == CrossNasTransferItemState.Failed);
        var unknown = rows.Count(item => item.State == CrossNasTransferItemState.ResultUnavailable);
        var status = transfer.Verified ? MutationResultStatus.ConfirmedSuccess : unknown > 0 || transfer.Running && transfer.HasSubmitted ||
            transfer.HasSubmitted && transfer.Error is not null ? MutationResultStatus.SubmittedButUnverified :
            succeeded > 0 && failed > 0 ? MutationResultStatus.PartialSuccess :
            succeeded > 0 || failed > 0 || transfer.Error is not null || transfer.Running ? MutationResultStatus.ConfirmedFailure :
            MutationResultStatus.CancelledBeforeSubmission;
        var issue = transfer.Error ?? rows.FirstOrDefault(item => item.State is CrossNasTransferItemState.Failed or CrossNasTransferItemState.ResultUnavailable)?.Result;
        return new(new(1, status, "crossNasCopy", transfer.HasSubmitted, status == MutationResultStatus.SubmittedButUnverified,
            new(succeeded, failed, unknown), issue?.ErrorCategory, diagnosticTag: issue?.DiagnosticTag),
            transfer.Request.SourcePath, transfer.DestinationPath)
        { OperationId = transfer.Id, Items = rows, CanContinue = CrossNasCanContinue(transfer), IsRunning = transfer.Running, RequiresReadOnlyRecovery = transfer.RestoredNeedsReview, RecoveryStorageUnavailable = CrossNasRecoveryUnavailable,
            CanDeleteSources = !CrossNasRecoveryUnavailable && !transfer.RestoredNeedsReview && CrossNasSourceDeletionEnabled && MutationCapability("SYNO.FileStation.Delete", 2) &&
                transfer.Request.SourcePath.LastIndexOf('/') > 0 &&
                transfer.Verified && !transfer.Running && transfer.DeletionError is null && transfer.Items.All(item => item.State == CrossNasTransferItemState.Copied) &&
                transfer.Items.Any(item => item.DeletionState == CrossNasSourceDeletionState.NotStarted) &&
                transfer.Items.All(item => item.DeletionState is CrossNasSourceDeletionState.NotStarted or CrossNasSourceDeletionState.Deleted),
            SourceDeletion = transfer.DeletionStarted ? CrossNasDeletionSnapshot(transfer) : null };
    }
    private static void RecordCrossNasError(CrossNasTransfer transfer, Exception error)
    {
        if (error is OperationCanceledException && transfer.Items.All(item => item.State is CrossNasTransferItemState.Copied or CrossNasTransferItemState.NotStarted)) return;
        var category = error is CrossNasPreflightException rejected ? rejected.Category :
            error is DsmException { AuthenticationFailure: true } ? MutationErrorCategory.Authentication : MutationErrorCategory.Network;
        transfer.Error = UploadFailure(category, error is CrossNasPreflightException known ? known.Message : "file.cross-nas.readback-unavailable");
    }
    private static CrossNasCopyMoveOutcome CrossNasRejected(CrossNasCopyMoveRequest request, MutationErrorCategory? category, string tag,
        MutationResultStatus? status = null) => new(new(1, status ?? (category == MutationErrorCategory.Unsupported ? MutationResultStatus.Unsupported : MutationResultStatus.ConfirmedFailure),
            "crossNasCopy", false, false, new(0, category is null ? 0 : 1, 0), category, diagnosticTag: tag), request.SourcePath,
            request.DestinationFolderPath + "/" + request.SourceName);

    private static bool CrossNasPathsOverlap(string first, string second) => first == second ||
        first.StartsWith(second + "/", StringComparison.Ordinal) || second.StartsWith(first + "/", StringComparison.Ordinal);
    private static bool CrossNasUnsafeMetadata(FileEntryMetadata metadata, bool allowShare = false) => UploadIsLink(metadata) ||
        metadata.MountPointType is { Length: > 0 } mount && !mount.Equals("normal", StringComparison.OrdinalIgnoreCase) && mount != "none" &&
            !(allowShare && mount.Equals("shared_folder", StringComparison.OrdinalIgnoreCase));
    private static bool CrossNasSameMetadata(FileEntryMetadata? current, FileEntryMetadata original) => current is not null &&
        CrossNasSameFile(current.Item, original.Item) && current.Type == original.Type && current.MountPointType == original.MountPointType;
    private static bool CrossNasSameFile(FileItem first, FileItem second) => first.Path == second.Path && first.Name == second.Name &&
        first.IsDirectory == second.IsDirectory && (first.IsDirectory || first.Size == second.Size) && first.ModifiedAt == second.ModifiedAt;

    private sealed class CrossNasPreflightException(MutationErrorCategory category, string tag) : Exception(tag)
    { public MutationErrorCategory Category { get; } = category; }
    private sealed class CrossNasTransfer(Guid id, CrossNasCopyMoveRequest request, string sourceScope, string targetScope, string destination)
    {
        public Guid Id { get; } = id;
        public CrossNasCopyMoveRequest Request { get; } = request;
        public string SourceScope { get; } = sourceScope;
        public string TargetScope { get; } = targetScope;
        public string DestinationPath { get; } = destination;
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public CrossNasTransferItem[] Items { get; set; } = [];
        public volatile bool Running;
        public bool RestoredNeedsReview { get; set; }
        public bool HasSubmitted { get; set; }
        public bool Verified { get; set; }
        public MutationResult? Error { get; set; }
        public bool DeletionStarted { get; set; }
        public MutationResult? DeletionError { get; set; }
    }
    private sealed class CrossNasTransferItem(FileEntryMetadata source, string destination, string relative)
    {
        public FileEntryMetadata Source { get; } = source;
        public string DestinationPath { get; } = destination;
        public string RelativePath { get; } = relative;
        public Guid UploadId { get; init; } = Guid.NewGuid();
        public CrossNasTransferItemState State { get; set; }
        public MutationResult? Result { get; set; }
        public PendingFileUpload? Upload { get; set; }
        public FileMutationReview? FolderReview { get; set; }
        public FileMutationSessionState? FolderOwner { get; set; }
        public CrossNasSourceDeletionState DeletionState { get; set; }
        public bool DeleteSubmitted { get; set; }
        public string? DeleteTaskId { get; set; }
        public FileMutationReview? DeleteMarker { get; set; }
        public FileMutationSessionState? DeleteOwner { get; set; }
        public FileMutationReview? DeleteTargetMarker { get; set; }
        public FileMutationSessionState? DeleteTargetOwner { get; set; }
    }
}
