using System.Buffers;
using LanStash.Domain;
using LanStash.Infrastructure.Transport;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int CrossNasChunkSize = 4 * 1024 * 1024;
    private const int CrossNasPipeCapacity = 12 * 1024 * 1024;
    private const int CrossNasFolderPageSize = 500;
    private const int CrossNasFolderItemLimit = 5000;
    private const int CrossNasFolderDepthLimit = 128;

    public CrossNasCopyMoveAvailability CrossNasAvailability => new(
        CanCrossCopy: CrossNasSourceTransferAvailable(),
        CanCrossMove: false);

    private bool CrossNasSourceTransferAvailable() =>
        _capabilities.ContainsKey("SYNO.FileStation.Download") &&
        MutationListAvailable;

    private bool CrossNasTargetTransferAvailable() =>
        _capabilities.TryGetValue("SYNO.FileStation.Upload", out var upload) &&
        string.Equals(upload.Name, "SYNO.FileStation.Upload", StringComparison.Ordinal) &&
        upload.MinVersion <= 2 &&
        upload.MaxVersion >= 2 &&
        string.Equals(upload.RequestFormat, "MULTIPART", StringComparison.OrdinalIgnoreCase) &&
        SafeMutationCapabilityPath(upload.Path) &&
        MutationListAvailable;

    public bool CanReceiveCrossNasCopy => CrossNasTargetTransferAvailable();

    public async Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(
        CrossNasCopyMoveRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (request.Operation != CrossNasCopyMoveOperation.Copy)
        {
            return CrossNasOutcome(
                MutationResultStatus.Unsupported,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Unsupported,
                "file.cross-nas.move-disabled");
        }
        if (!CrossNasAvailability.CanCrossCopy)
        {
            return CrossNasOutcome(
                MutationResultStatus.Unsupported,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Unsupported,
                "file.cross-nas.source-no-capability");
        }
        if (request.SourceProfileId == request.TargetProfileId)
        {
            return CrossNasOutcome(
                MutationResultStatus.Unsupported,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Validation,
                "file.cross-nas.same-profile");
        }
        if (!CrossNasSourceTransferAvailable())
        {
            return CrossNasOutcome(
                MutationResultStatus.Unsupported,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Unsupported,
                "file.cross-nas.source-no-capability");
        }

        var resolver = CrossNasRepositoryResolver;
        if (resolver is null)
        {
            return CrossNasOutcome(
                MutationResultStatus.Unsupported,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Unsupported,
                "file.cross-nas.no-resolver");
        }

        var target = resolver(request.TargetProfileId);
        if (target is null)
        {
            return CrossNasOutcome(
                MutationResultStatus.ConfirmedFailure,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Validation,
                "file.cross-nas.target-not-found");
        }
        if (!target.CrossNasTargetTransferAvailable())
        {
            return CrossNasOutcome(
                MutationResultStatus.Unsupported,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Unsupported,
                "file.cross-nas.target-no-capability");
        }

        if (cancellationToken.IsCancellationRequested)
        {
            return CrossNasOutcome(
                MutationResultStatus.CancelledBeforeSubmission,
                request.SourcePath,
                request.DestinationFolderPath);
        }

        if (ProfileId != request.SourceProfileId ||
            target.ProfileId != request.TargetProfileId)
        {
            return CrossNasOutcome(
                MutationResultStatus.ConfirmedFailure,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Validation,
                "file.cross-nas.profile-mismatch");
        }

        var sourceRepository = this;
        var targetRepository = target;

        if (request.IsDirectory)
        {
            return await CrossNasCopyFolderAsync(
                sourceRepository, targetRepository, request, progress, cancellationToken)
                .ConfigureAwait(false);
        }

        return await CrossNasCopyFileAsync(
            sourceRepository, targetRepository, request, progress, cancellationToken)
            .ConfigureAwait(false);
    }

    private static async Task<CrossNasCopyMoveOutcome> CrossNasCopyFileAsync(
        DsmRepository source,
        DsmRepository target,
        CrossNasCopyMoveRequest request,
        IProgress<long>? progress,
        CancellationToken cancellationToken)
    {
        if (request.FileSize == 0)
        {
            // 零字节文件仍然必须上传并回读确认。
            return await CreateEmptyFileOnTargetAsync(
                target, request, cancellationToken).ConfigureAwait(false);
        }

        var totalProgress = request.FileSize * 2;
        progress?.Report(0);

        using var pipe = new BoundedMemoryStream(CrossNasPipeCapacity);
        long downloadedBytes = 0;
        long uploadedBytes = 0;
        Exception? uploadFault = null;
        FileUploadTransportResult? uploadResult = null;
        var uploadStarted = 0;

        // 先读取并核对第一段，确认源文件契约后才跨过目标上传的提交边界。
        FileRangeReadResult firstResult;
        try
        {
            firstResult = await source._api.ReadFileRangeResultAsync(
                source._profile,
                source._session,
                source._capabilities["SYNO.FileStation.Download"],
                request.SourcePath,
                0,
                Math.Min(CrossNasChunkSize, request.FileSize),
                expectedContentVersion: null,
                expectedTotalLength: request.FileSize,
                cancellationToken: cancellationToken).ConfigureAwait(false);
            EnsureCrossNasRange(firstResult, 0, request.FileSize);
        }
        catch (OperationCanceledException)
        {
            return CrossNasOutcome(
                MutationResultStatus.CancelledBeforeSubmission,
                request.SourcePath,
                request.DestinationFolderPath);
        }
        catch (Exception error)
        {
            return CrossNasOutcome(
                MutationResultStatus.ConfirmedFailure,
                request.SourcePath,
                request.DestinationFolderPath,
                error is FileRangeContractException
                    ? MutationErrorCategory.Unknown
                    : MutationErrorCategory.Network,
                "file.cross-nas.source-range-invalid");
        }

        // 上传任务与源端读取并行，但上传开始标志就是不可逆提交边界。
        var uploadTask = Task.Run(async () =>
        {
            try
            {
                using var readStream = new BoundedMemoryReadStream(pipe);
                var uploadRequest = new FileUploadRequest(
                    readStream,
                    request.FileSize,
                    request.DestinationFolderPath,
                    request.SourceName,
                    request.Overwrite);
                Interlocked.Exchange(ref uploadStarted, 1);
                uploadResult = await target._api.UploadFileAsync(
                    target._profile,
                    target._session,
                    target._capabilities["SYNO.FileStation.Upload"],
                    uploadRequest,
                    // 进度由已下载和已上传字节数相加得到。
                    new UploadProgressAdapter(reported =>
                    {
                        Interlocked.Exchange(ref uploadedBytes, reported);
                        var combined = Math.Min(Volatile.Read(ref downloadedBytes) + reported, totalProgress);
                        progress?.Report(combined);
                    }),
                    cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                pipe.Cancel();
            }
            catch (Exception ex)
            {
                uploadFault = ex;
                pipe.Cancel(ex);
            }
        }, cancellationToken);

        // 下载循环只消费已经核对的段；后续段出现未知时立即停止，不重放上传。
        FileRangeReadResult lastResult = firstResult;
        try
        {
            var offset = 0L;
            while (offset < request.FileSize)
            {
                cancellationToken.ThrowIfCancellationRequested();
                EnsureCrossNasRange(lastResult, offset, request.FileSize);
                await pipe.WriteAsync(lastResult.Bytes, cancellationToken).ConfigureAwait(false);
                Interlocked.Add(ref downloadedBytes, lastResult.ActualByteCount);
                var combined = Math.Min(Volatile.Read(ref downloadedBytes) + Volatile.Read(ref uploadedBytes), totalProgress);
                progress?.Report(combined);
                offset += lastResult.ActualByteCount;
                if (offset == request.FileSize)
                {
                    break;
                }

                var chunkLength = Math.Min(CrossNasChunkSize, request.FileSize - offset);
                var expectedContentVersion = lastResult.ServerContentVersion;
                lastResult = await source._api.ReadFileRangeResultAsync(
                    source._profile,
                    source._session,
                    source._capabilities["SYNO.FileStation.Download"],
                    request.SourcePath,
                    offset,
                    chunkLength,
                    expectedContentVersion: lastResult.ServerContentVersion,
                    expectedTotalLength: request.FileSize,
                    cancellationToken: cancellationToken).ConfigureAwait(false);
                if (!string.Equals(
                        lastResult.ServerContentVersion,
                        expectedContentVersion,
                        StringComparison.Ordinal))
                {
                    throw new FileRangeContractException(
                        FileRangeContractFailure.ContentVersionMismatch,
                        "file.cross-nas.content-version-changed",
                        lastResult.StatusCode);
                }
            }
        }
        catch (Exception ex)
        {
            pipe.Cancel(ex);
            await uploadTask.ConfigureAwait(false);
            if (ex is OperationCanceledException)
            {
                return CrossNasOutcome(
                    Volatile.Read(ref uploadStarted) == 0
                        ? MutationResultStatus.CancelledBeforeSubmission
                        : MutationResultStatus.CancellationRequestedAfterSubmission,
                    request.SourcePath,
                    request.DestinationFolderPath,
                    Volatile.Read(ref uploadStarted) == 0
                        ? null
                        : MutationErrorCategory.Network,
                    Volatile.Read(ref uploadStarted) == 0
                        ? null
                        : "file.cross-nas.cancelled-after-upload-submit");
            }
            // 上传已明确失败时保留服务端给出的错误类别。
            if (uploadResult?.Status == FileUploadTransportStatus.ConfirmedFailure)
            {
                return CrossNasOutcome(
                    MutationResultStatus.ConfirmedFailure,
                    request.SourcePath,
                    request.DestinationFolderPath,
                    uploadResult.ErrorCategory ?? MutationErrorCategory.Server,
                    uploadResult.DiagnosticTag);
            }
            return CrossNasOutcome(
                Volatile.Read(ref uploadStarted) == 0
                    ? MutationResultStatus.ConfirmedFailure
                    : MutationResultStatus.SubmittedButUnverified,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Network,
                "file.cross-nas.download-failed");
        }

        pipe.CompleteWrite();

        try
        {
            await uploadTask.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return CrossNasOutcome(
                MutationResultStatus.CancellationRequestedAfterSubmission,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Network,
                "file.cross-nas.cancelled-after-upload-submit");
        }

        if (uploadFault is not null)
        {
            return CrossNasOutcome(
                MutationResultStatus.SubmittedButUnverified,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Network,
                "file.cross-nas.upload-failed");
        }

        if (uploadResult is null)
        {
            return CrossNasOutcome(
                MutationResultStatus.SubmittedButUnverified,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Unknown,
                "file.cross-nas.upload-no-result");
        }

        switch (uploadResult.Status)
        {
            case FileUploadTransportStatus.Accepted:
                break;
            case FileUploadTransportStatus.ConfirmedFailure:
                return CrossNasOutcome(
                    MutationResultStatus.ConfirmedFailure,
                    request.SourcePath,
                    request.DestinationFolderPath,
                    uploadResult.ErrorCategory ?? MutationErrorCategory.Server,
                    uploadResult.DiagnosticTag ?? "file.cross-nas.upload-confirmed-failure");
            case FileUploadTransportStatus.CancelledBeforeSubmission:
                return CrossNasOutcome(
                    MutationResultStatus.CancelledBeforeSubmission,
                    request.SourcePath,
                    request.DestinationFolderPath);
            case FileUploadTransportStatus.CancellationRequestedAfterSubmission:
                return CrossNasOutcome(
                    MutationResultStatus.CancellationRequestedAfterSubmission,
                    request.SourcePath,
                    request.DestinationFolderPath,
                    MutationErrorCategory.Network,
                    "file.cross-nas.cancelled-after-upload-submit");
            case FileUploadTransportStatus.SubmittedButUnverified:
                return CrossNasOutcome(
                    MutationResultStatus.SubmittedButUnverified,
                    request.SourcePath,
                    request.DestinationFolderPath,
                    MutationErrorCategory.Network,
                    "file.cross-nas.upload-unverified");
            case FileUploadTransportStatus.Unsupported:
                return CrossNasOutcome(
                    MutationResultStatus.Unsupported,
                    request.SourcePath,
                    request.DestinationFolderPath,
                    MutationErrorCategory.Unsupported,
                    "file.cross-nas.upload-unsupported");
            default:
                return CrossNasOutcome(
                    MutationResultStatus.ConfirmedFailure,
                    request.SourcePath,
                    request.DestinationFolderPath,
                    MutationErrorCategory.Unknown,
                    "file.cross-nas.upload-unknown-status");
        }

        // 目标端上传返回成功仍需回读确认，回读失败只能是未知，不能再次上传。
        FileItem? confirmed = null;
        try
        {
            confirmed = await ReadBackCrossNasFileAsync(
                target, request.DestinationFolderPath, request.SourceName,
                request.FileSize, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return CrossNasOutcome(
                MutationResultStatus.CancellationRequestedAfterSubmission,
                request.SourcePath,
                $"{request.DestinationFolderPath}/{request.SourceName}",
                MutationErrorCategory.Network,
                "file.cross-nas.cancelled-after-upload-submit",
                unknown: 1);
        }
        catch
        {
            return CrossNasOutcome(
                MutationResultStatus.SubmittedButUnverified,
                request.SourcePath,
                $"{request.DestinationFolderPath}/{request.SourceName}",
                MutationErrorCategory.Network,
                "file.cross-nas.readback-unavailable",
                unknown: 1);
        }
        if (confirmed is null)
        {
            return CrossNasOutcome(
                MutationResultStatus.SubmittedButUnverified,
                request.SourcePath,
                $"{request.DestinationFolderPath}/{request.SourceName}",
                MutationErrorCategory.Unknown,
                "file.cross-nas.readback-mismatch",
                unknown: 1);
        }

        progress?.Report(totalProgress);
        return CrossNasOutcome(
            MutationResultStatus.ConfirmedSuccess,
            request.SourcePath,
            $"{request.DestinationFolderPath}/{request.SourceName}",
            confirmedItem: confirmed);
    }

    private static async Task<CrossNasCopyMoveOutcome> CreateEmptyFileOnTargetAsync(
        DsmRepository target,
        CrossNasCopyMoveRequest request,
        CancellationToken cancellationToken)
    {
        using var emptyStream = new MemoryStream(Array.Empty<byte>());
        var uploadRequest = new FileUploadRequest(
            emptyStream, 0, request.DestinationFolderPath, request.SourceName, request.Overwrite);
        if (cancellationToken.IsCancellationRequested)
        {
            return CrossNasOutcome(
                MutationResultStatus.CancelledBeforeSubmission,
                request.SourcePath,
                request.DestinationFolderPath);
        }
        FileUploadTransportResult result;
        try
        {
            result = await target._api.UploadFileAsync(
                target._profile,
                target._session,
                target._capabilities["SYNO.FileStation.Upload"],
                uploadRequest,
                progress: null,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return CrossNasOutcome(
                MutationResultStatus.CancellationRequestedAfterSubmission,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Network,
                "file.cross-nas.cancelled-after-upload-submit");
        }
        catch (Exception)
        {
            return CrossNasOutcome(
                MutationResultStatus.SubmittedButUnverified,
                request.SourcePath,
                request.DestinationFolderPath,
                MutationErrorCategory.Unknown,
                "file.cross-nas.empty-upload-unverified");
        }

        if (result.Status != FileUploadTransportStatus.Accepted)
        {
            var status = result.Status switch
            {
                FileUploadTransportStatus.CancelledBeforeSubmission =>
                    MutationResultStatus.CancelledBeforeSubmission,
                FileUploadTransportStatus.CancellationRequestedAfterSubmission =>
                    MutationResultStatus.CancellationRequestedAfterSubmission,
                FileUploadTransportStatus.SubmittedButUnverified =>
                    MutationResultStatus.SubmittedButUnverified,
                FileUploadTransportStatus.Unsupported => MutationResultStatus.Unsupported,
                _ => MutationResultStatus.ConfirmedFailure,
            };
            return CrossNasOutcome(
                status,
                request.SourcePath,
                request.DestinationFolderPath,
                result.ErrorCategory ?? MutationErrorCategory.Server,
                result.DiagnosticTag ?? "file.cross-nas.empty-upload-failed");
        }

        FileItem? confirmed;
        try
        {
            confirmed = await ReadBackCrossNasFileAsync(
                target, request.DestinationFolderPath, request.SourceName, 0,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return CrossNasOutcome(
                MutationResultStatus.CancellationRequestedAfterSubmission,
                request.SourcePath,
                $"{request.DestinationFolderPath}/{request.SourceName}",
                MutationErrorCategory.Network,
                "file.cross-nas.cancelled-after-upload-submit",
                unknown: 1);
        }
        catch
        {
            confirmed = null;
        }
        return confirmed is null
            ? CrossNasOutcome(
                MutationResultStatus.SubmittedButUnverified,
                request.SourcePath,
                $"{request.DestinationFolderPath}/{request.SourceName}",
                MutationErrorCategory.Unknown,
                "file.cross-nas.readback-unverified",
                unknown: 1)
            : CrossNasOutcome(
                MutationResultStatus.ConfirmedSuccess,
                request.SourcePath,
                $"{request.DestinationFolderPath}/{request.SourceName}",
                succeeded: 1,
                confirmedItem: confirmed);
    }

    private static async Task<CrossNasCopyMoveOutcome> CrossNasCopyFolderAsync(
        DsmRepository source,
        DsmRepository target,
        CrossNasCopyMoveRequest request,
        IProgress<long>? progress,
        CancellationToken cancellationToken)
    {
        var destFolderPath = $"{request.DestinationFolderPath}/{request.SourceName}";
        IReadOnlyList<CrossNasTreeItem> sourceTree;
        try
        {
            // 在任何目标写入前固定源树，保证后续不会边遍历边改变提交集合。
            sourceTree = await LoadCrossNasTreeAsync(
                source, request.SourcePath, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return CrossNasOutcome(
                MutationResultStatus.CancelledBeforeSubmission,
                request.SourcePath,
                destFolderPath);
        }
        catch (Exception)
        {
            return CrossNasOutcome(
                MutationResultStatus.ConfirmedFailure,
                request.SourcePath,
                destFolderPath,
                MutationErrorCategory.Unknown,
                "file.cross-nas.source-tree-invalid");
        }

        var folderOutcome = await CreateTargetFolderAsync(
            target, request.DestinationFolderPath, request.SourceName,
            request.Overwrite, request.SourcePath, destFolderPath,
            cancellationToken).ConfigureAwait(false);
        if (folderOutcome.Result.Status != MutationResultStatus.ConfirmedSuccess)
        {
            return folderOutcome;
        }

        var succeeded = 1;
        foreach (var item in sourceTree
                     .OrderBy(item => item.IsDirectory ? 0 : 1)
                     .ThenBy(item => item.RelativePath.Count(c => c == '/'))
                     .ThenBy(item => item.RelativePath, StringComparer.Ordinal))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var destinationParent = DestinationParent(destFolderPath, item.RelativePath);
            CrossNasCopyMoveOutcome childOutcome;
            if (item.IsDirectory)
            {
                childOutcome = await CreateTargetFolderAsync(
                    target, destinationParent, item.Name, request.Overwrite,
                    request.SourcePath, $"{destFolderPath}/{item.RelativePath}",
                    cancellationToken).ConfigureAwait(false);
            }
            else
            {
                var childRequest = new CrossNasCopyMoveRequest(
                    request.SourceProfileId,
                    request.TargetProfileId,
                    item.Path,
                    item.Name,
                    false,
                    item.Size,
                    destinationParent,
                    request.Overwrite,
                    CrossNasCopyMoveOperation.Copy);
                childOutcome = await CrossNasCopyFileAsync(
                    source, target, childRequest, progress, cancellationToken)
                    .ConfigureAwait(false);
            }

            if (childOutcome.Result.Status != MutationResultStatus.ConfirmedSuccess)
            {
                // 未知或取消后的提交状态不能继续追加写操作，也不能重放已经提交的项。
                if (childOutcome.Result.Status is
                    MutationResultStatus.SubmittedButUnverified or
                    MutationResultStatus.CancellationRequestedAfterSubmission)
                {
                    return CrossNasOutcome(
                        MutationResultStatus.SubmittedButUnverified,
                        request.SourcePath,
                        destFolderPath,
                        childOutcome.Result.ErrorCategory,
                        childOutcome.Result.DiagnosticTag,
                        succeeded: succeeded,
                        unknown: 1);
                }
                return CrossNasOutcome(
                    childOutcome.Result.Status,
                    request.SourcePath,
                    destFolderPath,
                    childOutcome.Result.ErrorCategory,
                    childOutcome.Result.DiagnosticTag,
                    succeeded: succeeded,
                    failed: 1);
            }
            succeeded++;
        }

        bool verified;
        try
        {
            verified = await VerifyCrossNasTreeAsync(
                target, destFolderPath, sourceTree, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return CrossNasOutcome(
                MutationResultStatus.CancellationRequestedAfterSubmission,
                request.SourcePath,
                destFolderPath,
                MutationErrorCategory.Network,
                "file.cross-nas.tree-readback-cancelled",
                succeeded: succeeded,
                unknown: 1);
        }
        catch (Exception)
        {
            verified = false;
        }
        if (!verified)
        {
            return CrossNasOutcome(
                MutationResultStatus.SubmittedButUnverified,
                request.SourcePath,
                destFolderPath,
                MutationErrorCategory.Unknown,
                "file.cross-nas.tree-readback-mismatch",
                succeeded: succeeded,
                unknown: 1);
        }
        return CrossNasOutcome(
            MutationResultStatus.ConfirmedSuccess,
            request.SourcePath,
            destFolderPath,
            succeeded: succeeded);
    }

    private static async Task<CrossNasCopyMoveOutcome> CreateTargetFolderAsync(
        DsmRepository target,
        string parentPath,
        string name,
        bool overwrite,
        string sourcePath,
        string destinationPath,
        CancellationToken cancellationToken)
    {
        if (overwrite)
        {
            return CrossNasOutcome(
                MutationResultStatus.Unsupported,
                sourcePath,
                destinationPath,
                MutationErrorCategory.Unsupported,
                "file.cross-nas.overwrite-disabled");
        }

        FileMutationOutcome outcome;
        try
        {
            // 目录创建复用 Repository 的权限检查、预约和提交后回读。
            outcome = await target.CreateFolderAsync(
                new CreateFolderRequest(target.ProfileId, parentPath, name),
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return CrossNasOutcome(
                MutationResultStatus.CancelledBeforeSubmission,
                sourcePath,
                destinationPath);
        }
        return CrossNasOutcome(
            outcome.Result.Status,
            sourcePath,
            destinationPath,
            outcome.Result.ErrorCategory,
            outcome.Result.DiagnosticTag,
            succeeded: outcome.Result.Status == MutationResultStatus.ConfirmedSuccess ? 1 : 0,
            failed: outcome.Result.Status is MutationResultStatus.ConfirmedFailure or
                MutationResultStatus.PermissionDenied ? 1 : 0,
            unknown: outcome.Result.Status is MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0,
            confirmedItem: outcome.ConfirmedItem);
    }

    private static async Task<IReadOnlyList<CrossNasTreeItem>> LoadCrossNasTreeAsync(
        DsmRepository source,
        string rootPath,
        CancellationToken cancellationToken)
    {
        var result = new List<CrossNasTreeItem>();
        var pending = new Queue<(string Path, string RelativePath, int Depth)>();
        pending.Enqueue((rootPath, string.Empty, 0));
        var seen = new HashSet<string>(StringComparer.Ordinal);
        while (pending.Count > 0)
        {
            var current = pending.Dequeue();
            if (current.Depth > CrossNasFolderDepthLimit)
                throw new InvalidDataException("file.cross-nas.tree-too-deep");

            var children = await LoadCrossNasChildrenAsync(
                source, current.Path, cancellationToken).ConfigureAwait(false);
            foreach (var item in children)
            {
                var relativePath = string.IsNullOrEmpty(current.RelativePath)
                    ? item.Name
                    : $"{current.RelativePath}/{item.Name}";
                if (!seen.Add(item.Path) || result.Count >= CrossNasFolderItemLimit)
                    throw new InvalidDataException("file.cross-nas.tree-over-limit");
                result.Add(new CrossNasTreeItem(
                    item.Path, item.Name, item.IsDirectory, item.Size, relativePath));
                if (item.IsDirectory)
                {
                    pending.Enqueue((item.Path, relativePath, current.Depth + 1));
                }
            }
        }
        return result;
    }

    private static async Task<bool> VerifyCrossNasTreeAsync(
        DsmRepository target,
        string rootPath,
        IReadOnlyList<CrossNasTreeItem> expected,
        CancellationToken cancellationToken)
    {
        var actual = await LoadCrossNasTreeAsync(
            target, rootPath, cancellationToken).ConfigureAwait(false);
        if (actual.Count != expected.Count)
            return false;
        var expectedByPath = expected.ToDictionary(item => item.RelativePath, StringComparer.Ordinal);
        foreach (var item in actual)
        {
            if (!expectedByPath.TryGetValue(item.RelativePath, out var expectedItem) ||
                expectedItem.IsDirectory != item.IsDirectory ||
                expectedItem.Size != item.Size)
                return false;
        }
        return true;
    }

    private static async Task<IReadOnlyList<FileItem>> LoadCrossNasChildrenAsync(
        DsmRepository repository,
        string path,
        CancellationToken cancellationToken)
    {
        var result = new List<FileItem>();
        var offset = 0;
        int? total = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        while (true)
        {
            var page = await repository.ListFilesAsync(
                path, offset, CrossNasFolderPageSize, cancellationToken).ConfigureAwait(false);
            if (page.Offset != offset || page.Total < 0 ||
                total is not null && total != page.Total ||
                page.Items.Count > CrossNasFolderPageSize ||
                page.Items.Count == 0 && offset < page.Total)
                throw new InvalidDataException("file.cross-nas.invalid-tree-page");
            total ??= page.Total;
            foreach (var item in page.Items)
            {
                if (!seen.Add(item.Path) || item.Path != $"{path}/{item.Name}")
                    throw new InvalidDataException("file.cross-nas.invalid-tree-item");
                result.Add(item);
            }
            offset = checked(offset + page.Items.Count);
            if (offset >= page.Total)
                break;
        }
        if (result.Count != total)
            throw new InvalidDataException("file.cross-nas.invalid-tree-total");
        return result;
    }

    private static string DestinationParent(string rootPath, string relativePath)
    {
        var separator = relativePath.LastIndexOf('/');
        return separator < 0 ? rootPath : $"{rootPath}/{relativePath[..separator]}";
    }

    private static void EnsureCrossNasRange(
        FileRangeReadResult result,
        long expectedStart,
        long expectedTotalLength)
    {
        var expectedLength = Math.Min(CrossNasChunkSize, expectedTotalLength - expectedStart);
        var segmented = expectedStart > 0 || expectedLength < expectedTotalLength;
        if (result.StatusCode is not (200 or 206) ||
            result.RequestedStart != expectedStart ||
            result.RequestedLength != expectedLength ||
            result.ResponseStart != expectedStart ||
            result.ResponseLength != expectedLength ||
            result.TotalLength != expectedTotalLength ||
            result.ActualByteCount != expectedLength ||
            result.Bytes.Length != expectedLength ||
            segmented && (!result.CanSafelyReadInSegments ||
                string.IsNullOrWhiteSpace(result.ServerContentVersion)))
        {
            throw new FileRangeContractException(
                FileRangeContractFailure.UnexpectedBodyLength,
                "file.cross-nas.invalid-range-contract",
                result.StatusCode);
        }
    }

    private sealed record CrossNasTreeItem(
        string Path,
        string Name,
        bool IsDirectory,
        long Size,
        string RelativePath);

    private static async Task<FileItem?> ReadBackCrossNasFileAsync(
        DsmRepository target,
        string folderPath,
        string fileName,
        long expectedSize,
        CancellationToken cancellationToken)
    {
        const int pageSize = 500;
        var offset = 0;
        while (true)
        {
            var page = await target.ListFilesAsync(
                folderPath, offset, pageSize, cancellationToken).ConfigureAwait(false);
            var match = page.Items.FirstOrDefault(item =>
                !item.IsDirectory &&
                string.Equals(item.Name, fileName, StringComparison.Ordinal) &&
                item.Size == expectedSize);
            if (match is not null) return match;
            offset += page.Items.Count;
            if (offset >= page.Total) return null;
        }
    }

    private static CrossNasCopyMoveOutcome CrossNasOutcome(
        MutationResultStatus status,
        string sourcePath,
        string destinationPath,
        MutationErrorCategory? errorCategory = null,
        string? diagnosticTag = null,
        int succeeded = 0,
        int failed = 0,
        int unknown = 0,
        FileItem? confirmedItem = null)
    {
        var submitted = status != MutationResultStatus.CancelledBeforeSubmission &&
                        status != MutationResultStatus.Unsupported;
        var requiresRefresh = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission;
        var operation = "crossNasCopy";

        var result = new MutationResult(
            1,
            status,
            operation,
            submitted,
            requiresRefresh,
            new MutationResultCounts(succeeded, failed, unknown),
            errorCategory,
            diagnosticTag: diagnosticTag);

        return new CrossNasCopyMoveOutcome(result, sourcePath, destinationPath, confirmedItem);
    }

    /// <summary>
    /// 将上传字节进度适配为跨 NAS 的累计进度。
    /// </summary>
    private sealed class UploadProgressAdapter(Action<long> report) : IProgress<long>
    {
        public void Report(long value) => report(value);
    }

    /// <summary>
    /// 将有界内存管道包装为上传请求可消费的只读流。
    /// </summary>
    private sealed class BoundedMemoryReadStream : Stream
    {
        private readonly BoundedMemoryStream _pipe;

        public BoundedMemoryReadStream(BoundedMemoryStream pipe)
        {
            _pipe = pipe;
        }

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException("Synchronous reads are not supported.");

        public override Task<int> ReadAsync(
            byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();

        public override async ValueTask<int> ReadAsync(
            Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            return await _pipe.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
        }

        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();
        public override void SetLength(long value) =>
            throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();
    }
}
