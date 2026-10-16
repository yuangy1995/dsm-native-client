using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private bool FileContentUploadAvailable => FileContentCapability("SYNO.FileStation.Download", 2) &&
        FileContentCapability("SYNO.FileStation.Upload", 2, multipart: true) && FileContentCapability("SYNO.FileStation.List", 2) &&
        FileContentCapability("SYNO.FileStation.CheckPermission", 3);
    private bool FileContentCapability(string name, int version, bool multipart = false) =>
        _capabilities.TryGetValue(name, out var cap) && cap.Name == name && cap.MinVersion <= version &&
        cap.MaxVersion >= version && SafeMutationCapabilityPath(cap.Path) &&
        (multipart ? cap.RequestFormat.Equals("MULTIPART", StringComparison.OrdinalIgnoreCase) :
            cap.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) || cap.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase));

    public Task<MutationResult> UploadFileAsync(FileUploadRequest request, IProgress<long>? progress = null,
        CancellationToken cancellationToken = default) => UploadFileCoreAsync(request, progress, cancellationToken);

    private async Task<MutationResult> UploadFileCoreAsync(FileUploadRequest request, IProgress<long>? progress,
        CancellationToken cancellationToken, Func<PendingFileUpload, Task>? checkpoint = null,
        Func<CancellationToken, Task<MutationResult?>>? validateBeforeSubmission = null)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (!FileContentUploadAvailable)
            return UploadResult(MutationResultStatus.Unsupported, false, false, 0, 1, 0,
                MutationErrorCategory.Unsupported, "file.upload.unsupported");
        var path = JoinMutationPath(request.FolderPath, request.FileName);
        if (!ValidMutationDirectory(request.FolderPath) || !ValidMutationObjectPath(path) || ArchiveContainsRecycleSegment(path))
            return UploadFailure(MutationErrorCategory.Validation, "file.upload.invalid-target");
        if (cancellationToken.IsCancellationRequested) return UploadCancelled();
        var key = (ServiceScope(), path);
        var shared = ServiceMutations;
        var marker = new FileMutationReview("uploadFile", request.FolderPath, path, null, false, [path]);
        PendingFileUpload pending;
        // 只在登记目标时持锁；长时间传输和暂停不占用其他文件或设置的执行锁。
        lock (shared.FileUploads)
        {
            if (shared.FileUploads.TryGetValue(key, out var previous))
            {
                if (previous.Completed && previous.OperationId == request.OperationId)
                    return UploadResult(MutationResultStatus.ConfirmedSuccess, true, false, 1, 0, 0);
                if (previous.Completed) shared.FileUploads.Remove(key);
                else
                {
                    return previous.Submitted && previous.OperationId == request.OperationId ? UploadUnverified("file.upload.pending") :
                        UploadFailure(MutationErrorCategory.Conflict, "file.upload.target-busy");
                }
            }
            var reservation = ReserveFileMutation(marker);
            if (!reservation.Acquired) return UploadFailure(MutationErrorCategory.Conflict, "file.upload.target-busy");
            if (reservation.PendingReview is not null)
            {
                ReleaseFileMutation(marker.Targets);
                return UploadUnverified("file.upload.pending");
            }
            pending = new(request.OperationId, request.Length, marker, FileMutationState());
            shared.FileUploads.Add(key, pending);
        }
        await pending.Gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var before = await ReadFileMetadataAsync(path, cancellationToken).ConfigureAwait(false);
            if (before is not null && (!request.Overwrite || before.Item.IsDirectory || UploadIsLink(before)))
                return UploadFailure(MutationErrorCategory.Conflict, "file.upload.target-exists");
            var permission = await _api.CheckFileMutationPermissionAsync(_profile, _session,
                _capabilities["SYNO.FileStation.CheckPermission"], request.FolderPath,
                $"LanStash-Write-Check-{Guid.NewGuid():N}.tmp", cancellationToken).ConfigureAwait(false);
            if (permission.Status == FilePermissionTransportStatus.Cancelled) return UploadCancelled();
            if (permission.Status != FilePermissionTransportStatus.Allowed)
                return UploadFailure(permission.ErrorCategory ?? MutationErrorCategory.Permission, "file.upload.permission");
            var latest = await ReadFileMetadataAsync(path, cancellationToken).ConfigureAwait(false);
            if (latest != before) return UploadFailure(MutationErrorCategory.Conflict, "file.upload.target-changed");
            if (validateBeforeSubmission is not null &&
                await validateBeforeSubmission(cancellationToken).ConfigureAwait(false) is { } rejection) return rejection;
            cancellationToken.ThrowIfCancellationRequested();
            using var content = new UploadHashStream(request.Content);
            var frozen = new FileUploadRequest(content, request.Length, request.FolderPath, request.FileName, request.Overwrite, request.OperationId);
            StoreFileMutationReview(marker);
            pending.Submitted = true;
            if (checkpoint is not null) await checkpoint(pending).ConfigureAwait(false);
            var submission = await _api.UploadFileAsync(_profile, _session,
                _capabilities["SYNO.FileStation.Upload"], frozen, progress, cancellationToken).ConfigureAwait(false);
            if (submission.Status is FileUploadTransportStatus.ConfirmedFailure or
                FileUploadTransportStatus.CancelledBeforeSubmission or FileUploadTransportStatus.Unsupported)
            {
                ClearFileUpload(key, pending);
                return submission.Status switch
                {
                    FileUploadTransportStatus.CancelledBeforeSubmission => UploadCancelled(),
                    FileUploadTransportStatus.Unsupported => UploadResult(MutationResultStatus.Unsupported,
                        false, false, 0, 1, 0, MutationErrorCategory.Unsupported, submission.DiagnosticTag),
                    _ => UploadResult(MutationResultStatus.ConfirmedFailure, true, false, 0, 1, 0,
                        submission.ErrorCategory, submission.DiagnosticTag),
                };
            }
            pending.Accepted = submission.Status == FileUploadTransportStatus.Accepted;
            pending.Hash = content.BytesRead == request.Length ? content.CompleteHash() : null;
            if (checkpoint is not null) await checkpoint(pending).ConfigureAwait(false);
            if (submission.Status == FileUploadTransportStatus.CancellationRequestedAfterSubmission)
                return UploadCancelledAfterSubmission();
            return await ReviewFileUploadCoreAsync(key, pending, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        { return pending.Submitted ? UploadCancelledAfterSubmission() : UploadCancelled(); }
        catch (Exception error)
        {
            var category = error is DsmException { AuthenticationFailure: true }
                ? MutationErrorCategory.Authentication : MutationErrorCategory.Network;
            return pending.Submitted ? UploadUnverified("file.upload.result-unavailable", category) :
                UploadFailure(category, "file.upload.preflight-unavailable");
        }
        finally
        {
            if (!pending.Submitted) ClearFileUpload(key, pending);
            lock (pending.Owner.Sync) pending.Owner.ActiveTargets.ExceptWith(marker.Targets);
            pending.Gate.Release();
        }
    }

    public async Task<MutationResult?> ReviewFileUploadAsync(string folderPath, string fileName,
        CancellationToken cancellationToken = default, Guid? operationId = null)
    {
        var key = (ServiceScope(), JoinMutationPath(folderPath, fileName));
        PendingFileUpload? pending;
        lock (ServiceMutations.FileUploads)
        {
            ServiceMutations.FileUploads.TryGetValue(key, out pending);
            if (operationId is { } id && pending?.OperationId != id || operationId is null && pending?.Completed == true) return null;
        }
        if (pending is null) return null;
        if (!await pending.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
            return pending.Submitted ? UploadUnverified("file.upload.pending") : null;
        try { return await ReviewFileUploadCoreAsync(key, pending, cancellationToken).ConfigureAwait(false); }
        finally { pending.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewFileUploadCoreAsync((string Scope, string Path) key,
        PendingFileUpload pending, CancellationToken token, bool validateCompleted = false)
    {
        if (pending.Completed && !validateCompleted) return UploadResult(MutationResultStatus.ConfirmedSuccess, true, false, 1, 0, 0);
        // 内容相同也不能补造本次接受回执。回执丢失时只保留未知，绝不重新上传。
        if (!pending.Accepted || pending.Hash is null) return UploadUnverified("file.upload.receipt-unavailable");
        try
        {
            var offset = 0;
            int? total = null;
            var seen = new HashSet<string>(StringComparer.Ordinal);
            FileItem? found = null;
            while (found is null)
            {
                var page = await ListFilesAsync(pending.Marker.Parent, offset, 500, token).ConfigureAwait(false);
                if (page.Offset != offset || (total is not null && page.Total != total) ||
                    page.Items.Any(item => !seen.Add(item.Path))) return UploadUnverified("file.upload.readback-invalid");
                total ??= page.Total;
                found = page.Items.SingleOrDefault(item => item.Path == key.Path);
                if (found is not null) break;
                if (page.Items.Count == 0 || offset + page.Items.Count >= page.Total)
                    return UploadUnverified("file.upload.readback-mismatch");
                offset = checked(offset + page.Items.Count);
            }
            if (found.IsDirectory || found.Size != pending.Length) return UploadUnverified("file.upload.readback-mismatch");
            var metadata = await ReadFileMetadataAsync(key.Path, token).ConfigureAwait(false);
            if (metadata is null || metadata.Item.IsDirectory || metadata.Item.Size != pending.Length || UploadIsLink(metadata))
                return UploadUnverified("file.upload.readback-mismatch");
            using var hash = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
            string? version = null;
            for (long position = 0; position < pending.Length;)
            {
                var length = Math.Min(4L * 1024 * 1024, pending.Length - position);
                var chunk = await ReadFileRangeResultAsync(key.Path, position, length, version, pending.Length, token).ConfigureAwait(false);
                if (chunk.ActualByteCount != length || chunk.Bytes.LongLength != length ||
                    (pending.Length > length && string.IsNullOrEmpty(chunk.ServerContentVersion)))
                    return UploadUnverified("file.upload.readback-incomplete");
                version ??= chunk.ServerContentVersion;
                hash.AppendData(chunk.Bytes);
                position += length;
            }
            if (!string.Equals(Convert.ToHexString(hash.GetHashAndReset()), pending.Hash, StringComparison.Ordinal))
                return UploadUnverified("file.upload.content-mismatch");
            if (await ReadFileMetadataAsync(key.Path, token).ConfigureAwait(false) != metadata)
                return UploadUnverified("file.upload.target-changed");
            lock (ServiceMutations.FileUploads) pending.Completed = true;
            lock (pending.Owner.Sync) pending.Owner.Reviews.Remove(pending.Marker.Key);
            return UploadResult(MutationResultStatus.ConfirmedSuccess, true, false, 1, 0, 0);
        }
        catch (OperationCanceledException) { return UploadCancelledAfterSubmission(); }
        catch (DsmException error) when (error.AuthenticationFailure)
        { return UploadUnverified("file.upload.authentication-required", MutationErrorCategory.Authentication); }
        catch (Exception) { return UploadUnverified("file.upload.readback-unavailable"); }
    }

    private void ClearFileUpload((string Scope, string Path) key, PendingFileUpload pending)
    {
        lock (ServiceMutations.FileUploads)
            if (ServiceMutations.FileUploads.GetValueOrDefault(key) == pending) ServiceMutations.FileUploads.Remove(key);
        lock (pending.Owner.Sync) pending.Owner.Reviews.Remove(pending.Marker.Key);
    }
    private static bool UploadIsLink(FileEntryMetadata metadata) =>
        metadata.Type?.Contains("link", StringComparison.OrdinalIgnoreCase) == true;
    private sealed class PendingFileUpload(Guid operationId, long length, FileMutationReview marker, FileMutationSessionState owner)
    {
        public SemaphoreSlim Gate { get; } = new(1, 1);
        public long Length { get; } = length;
        public Guid OperationId { get; } = operationId;
        public FileMutationReview Marker { get; } = marker;
        public FileMutationSessionState Owner { get; } = owner;
        public volatile bool Submitted;
        public bool Completed { get; set; }
        public bool Accepted { get; set; }
        public string? Hash { get; set; }
    }
    private static MutationResult UploadFailure(MutationErrorCategory category, string tag) =>
        UploadResult(MutationResultStatus.ConfirmedFailure, false, false, 0, 1, 0, category, tag);
    private static MutationResult UploadCancelled() =>
        UploadResult(MutationResultStatus.CancelledBeforeSubmission, false, false, 0, 0, 0);
    private static MutationResult UploadCancelledAfterSubmission() =>
        UploadResult(MutationResultStatus.CancellationRequestedAfterSubmission, true, true, 0, 0, 1,
            MutationErrorCategory.Network, "file.upload.cancelled-after-submit");

    // 只摘要本次 multipart 实际消费的字节；不要求可 Seek，也不关闭调用方的原流。
    private sealed class UploadHashStream(Stream source) : Stream
    {
        private readonly System.Security.Cryptography.IncrementalHash _hash =
            System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.SHA256);
        public long BytesRead { get; private set; }
        public string CompleteHash() => Convert.ToHexString(_hash.GetHashAndReset());
        public override int Read(byte[] buffer, int offset, int count)
        {
            var read = source.Read(buffer, offset, count);
            _hash.AppendData(buffer, offset, read); BytesRead += read; return read;
        }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            var read = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            _hash.AppendData(buffer.Span[..read]); BytesRead += read; return read;
        }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        protected override void Dispose(bool disposing) { if (disposing) _hash.Dispose(); base.Dispose(disposing); }
        public override bool CanRead => source.CanRead;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => BytesRead; set => throw new NotSupportedException(); }
        public override void Flush() => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private static MutationResult UploadUnverified(string diagnosticTag, MutationErrorCategory category = MutationErrorCategory.Unknown) =>
        UploadResult(
            MutationResultStatus.SubmittedButUnverified,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: 1,
            category,
            diagnosticTag);

    private static MutationResult UploadResult(
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh,
        int succeeded,
        int failed,
        int unknown,
        MutationErrorCategory? errorCategory = null,
        string? diagnosticTag = null) =>
        new(
            1,
            status,
            "uploadFile",
            submitted,
            requiresRefresh,
            new MutationResultCounts(succeeded, failed, unknown),
            errorCategory,
            diagnosticTag: diagnosticTag);
}
