using System.Text;
using System.Security.Cryptography;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const long TextEditMaxBytes = 5L * 1024 * 1024;

    private static readonly string[] TextEditExtensionsList = new[]
    {
        "txt", "json", "geojson", "xml", "js", "ts", "jsx", "tsx",
        "css", "scss", "html", "htm", "md", "yaml", "yml",
        "sh", "py", "rb", "cs", "swift", "kt", "java",
        "c", "cpp", "h", "hpp", "sql", "conf", "ini", "cfg", "log", "csv", "toml",
    };

    FileTextEditAvailability IFilePreviewRepository.GetTextEditAvailability() => new(
        FileContentUploadAvailable, FileContentUploadAvailable, TextEditExtensionsList);

    async Task<FileTextContentSnapshot> IFilePreviewRepository.DownloadTextContentSnapshotAsync(
        string path, long expectedFileSize, long maxBytes, CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(expectedFileSize);
        ArgumentOutOfRangeException.ThrowIfLessThan(maxBytes, 1);
        if (expectedFileSize > maxBytes || maxBytes > TextEditMaxBytes)
            throw new ArgumentOutOfRangeException(nameof(expectedFileSize), "textedit.size_exceeded");
        if (expectedFileSize == 0)
        {
            var item = (await ReadFileMetadataAsync(path, cancellationToken).ConfigureAwait(false))?.Item;
            if (item is not { IsDirectory: false, Size: 0, ModifiedAt: not null })
                throw new InvalidOperationException("textedit.source_changed");
            return new(string.Empty, 0, EmptyTextVersion(item), TextHash([]));
        }
        var result = await ReadFileRangeResultAsync(path, 0, expectedFileSize,
            expectedTotalLength: expectedFileSize, cancellationToken: cancellationToken).ConfigureAwait(false);
        if (result.ActualByteCount != expectedFileSize || result.ServerContentVersion is not { Length: > 0 } version)
            throw new InvalidOperationException("textedit.version_unavailable");
        var bytes = result.Bytes.AsSpan(0, checked((int)result.ActualByteCount));
        return new(DecodeTextEditContent(bytes), result.ActualByteCount, version, TextHash(bytes));
    }

    async Task<MutationResult> IFilePreviewRepository.SaveTextContentAsync(
        string path, string content, FileTextContentSnapshot original, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(content);
        ArgumentNullException.ThrowIfNull(original);
        if (!FileContentUploadAvailable || !ValidMutationObjectPath(path) || ArchiveContainsRecycleSegment(path))
            return TextSaveFailure(MutationErrorCategory.Unsupported);
        byte[] encoded;
        try { encoded = new UTF8Encoding(false, true).GetBytes(content); }
        catch (EncoderFallbackException) { return TextSaveFailure(MutationErrorCategory.Validation); }
        if (encoded.LongLength > TextEditMaxBytes || original.ByteLength < 0 || original.ByteLength > TextEditMaxBytes)
            return TextSaveFailure(MutationErrorCategory.Validation);
        if (cancellationToken.IsCancellationRequested)
            return MutationResultSave(MutationResultStatus.CancelledBeforeSubmission, false, false, null, null);
        var shared = ServiceMutations;
        if (!await shared.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false))
            return TextSaveFailure(MutationErrorCategory.Conflict);
        var key = (ServiceScope(), path);
        var marker = new FileMutationReview("saveTextContent", MutationParent(path), path, null, false, [path]);
        var reserved = false;
        try
        {
            // 以原账号、连接和目标防重；页面关闭或 Repository 重建不能重新覆盖。
            if (shared.TextSaves.ContainsKey(key)) return TextSaveUnknown();
            var reservation = ReserveFileMutation(marker);
            reserved = reservation.Acquired;
            if (!reserved || reservation.PendingReview is not null) return TextSaveFailure(MutationErrorCategory.Conflict);
            if (content == original.Text)
                return MutationResultSave(MutationResultStatus.CancelledBeforeSubmission, false, false, null, "file.textedit.unchanged");
            var metadata = await ReadFileMetadataAsync(path, cancellationToken).ConfigureAwait(false);
            if (metadata?.Item is not { IsDirectory: false } item || item.Size != original.ByteLength)
                return TextSaveFailure(MutationErrorCategory.Conflict);
            // 与既有上传语义一致：一次性名称只检查目录创建权限，不创建任何文件。
            // 列表中的 write 标记并不保证覆盖权限，最终仍由 Upload 的拒绝结果判定。
            var permission = await _api.CheckFileMutationPermissionAsync(_profile, _session,
                _capabilities["SYNO.FileStation.CheckPermission"], MutationParent(path),
                $"LanStash-Write-Check-{Guid.NewGuid():N}.tmp", cancellationToken).ConfigureAwait(false);
            if (permission.Status != FilePermissionTransportStatus.Allowed)
                return TextSaveFailure(permission.ErrorCategory ?? MutationErrorCategory.Permission);
            if (original.ByteLength == 0)
            {
                var latest = (await ReadFileMetadataAsync(path, cancellationToken).ConfigureAwait(false))?.Item;
                if (latest is not { IsDirectory: false, Size: 0, ModifiedAt: not null } || EmptyTextVersion(latest) != original.ContentVersion)
                    return TextSaveFailure(MutationErrorCategory.Conflict);
            }
            else
            {
                var before = await ReadFileRangeResultAsync(path, 0, original.ByteLength,
                    original.ContentVersion, original.ByteLength, cancellationToken).ConfigureAwait(false);
                if (before.ActualByteCount != original.ByteLength || TextHash(before.Bytes.AsSpan(0,
                    checked((int)before.ActualByteCount))) != original.Sha256)
                    return TextSaveFailure(MutationErrorCategory.Conflict);
            }
            cancellationToken.ThrowIfCancellationRequested();
            var pending = new PendingTextSave(encoded.LongLength, TextHash(encoded), marker, FileMutationState());
            using var stream = new MemoryStream(encoded, writable: false);
            var request = new FileUploadRequest(stream, encoded.LongLength, MutationParent(path),
                path[(path.LastIndexOf('/') + 1)..], overwrite: true);
            shared.TextSaves.Add(key, pending);
            StoreFileMutationReview(marker);
            FileUploadTransportResult transport;
            try
            {
                // 直接使用同一上传 transport，保存接受回执供内容复查归属判断。
                transport = await _api.UploadFileAsync(_profile, _session,
                    _capabilities["SYNO.FileStation.Upload"], request, null, cancellationToken).ConfigureAwait(false);
            }
            catch { return TextSaveUnknown(); }
            if (transport.Status is FileUploadTransportStatus.ConfirmedFailure or
                FileUploadTransportStatus.CancelledBeforeSubmission or FileUploadTransportStatus.Unsupported)
            {
                ClearTextSave(key, pending);
                return transport.Status == FileUploadTransportStatus.CancelledBeforeSubmission
                    ? MutationResultSave(MutationResultStatus.CancelledBeforeSubmission, false, false, null, null)
                    : TextSaveFailure(transport.ErrorCategory ?? MutationErrorCategory.Unknown);
            }
            pending.Accepted = transport.Status == FileUploadTransportStatus.Accepted;
            return await ReviewTextSaveCoreAsync(key, pending, CancellationToken.None).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return MutationResultSave(MutationResultStatus.CancelledBeforeSubmission, false, false, null, null);
        }
        catch (FileRangeContractException error) when (error.Failure is
            FileRangeContractFailure.ContentVersionMismatch or FileRangeContractFailure.UnexpectedTotalLength)
        { return TextSaveFailure(MutationErrorCategory.Conflict); }
        catch { return TextSaveFailure(MutationErrorCategory.Network); }
        finally { if (reserved) ReleaseFileMutation(marker.Targets); shared.Gate.Release(); }
    }

    async Task<MutationResult?> IFilePreviewRepository.ReviewTextContentSaveAsync(string path, CancellationToken cancellationToken)
    {
        var shared = ServiceMutations;
        await shared.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var key = (ServiceScope(), path);
            return shared.TextSaves.TryGetValue(key, out var pending)
                ? await ReviewTextSaveCoreAsync(key, pending, cancellationToken).ConfigureAwait(false) : null;
        }
        finally { shared.Gate.Release(); }
    }

    private async Task<MutationResult> ReviewTextSaveCoreAsync((string Scope, string Path) key,
        PendingTextSave pending, CancellationToken token)
    {
        // 相同正文不能替代本次接受回执；丢失回执时永不认领他人的写入。
        if (!pending.Accepted) return TextSaveUnknown();
        try
        {
            var item = (await ReadFileMetadataAsync(key.Path, token).ConfigureAwait(false))?.Item;
            if (item is not { IsDirectory: false } || item.Size != pending.Length) return TextSaveUnknown();
            if (pending.Length > 0)
            {
                var result = await ReadFileRangeResultAsync(key.Path, 0, pending.Length,
                    expectedTotalLength: pending.Length, cancellationToken: token).ConfigureAwait(false);
                if (result.ActualByteCount != pending.Length || TextHash(result.Bytes.AsSpan(0,
                    checked((int)result.ActualByteCount))) != pending.Hash) return TextSaveUnknown();
            }
            ClearTextSave(key, pending);
            return MutationResultSave(MutationResultStatus.ConfirmedSuccess, true, false, null, null);
        }
        catch { return TextSaveUnknown(); }
    }

    private void ClearTextSave((string Scope, string Path) key, PendingTextSave pending)
    {
        ServiceMutations.TextSaves.Remove(key);
        lock (pending.Owner.Sync) pending.Owner.Reviews.Remove(pending.Marker.Key);
    }

    private sealed class PendingTextSave(long length, string hash, FileMutationReview marker, FileMutationSessionState owner)
    {
        public FileMutationReview Marker { get; } = marker;
        public FileMutationSessionState Owner { get; } = owner;
        public long Length { get; } = length;
        public string Hash { get; } = hash;
        public bool Accepted { get; set; }
    }
    private static string TextHash(ReadOnlySpan<byte> bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static string EmptyTextVersion(FileItem item) => "empty:" + TextHash(Encoding.UTF8.GetBytes(
        System.Text.Json.JsonSerializer.Serialize(item)));
    private static MutationResult TextSaveFailure(MutationErrorCategory category) => MutationResultSave(
        MutationResultStatus.ConfirmedFailure, false, false, category, "file.textedit.preflight-failed");
    private static MutationResult TextSaveUnknown() => MutationResultSave(MutationResultStatus.SubmittedButUnverified,
        true, true, MutationErrorCategory.Unknown, "file.textedit.readback-unverified");

    Task<string> IFilePreviewRepository.FormatTextContentAsync(
        string text,
        TextFormatKind kind,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(text);
        return Task.FromResult(FileTextFormatter.Format(text, kind));
    }

    private static string DecodeTextEditContent(ReadOnlySpan<byte> bytes)
    {
        try
        {
            if (bytes.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF })) return new UTF8Encoding(false, true).GetString(bytes[3..]);
            if (bytes.StartsWith(new byte[] { 0xFF, 0xFE })) return new UnicodeEncoding(false, false, true).GetString(bytes[2..]);
            if (bytes.StartsWith(new byte[] { 0xFE, 0xFF })) return new UnicodeEncoding(true, false, true).GetString(bytes[2..]);
            return new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (DecoderFallbackException) { throw new InvalidOperationException("textedit.encoding_error"); }
    }

    private static MutationResult MutationResultSave(
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh,
        MutationErrorCategory? errorCategory,
        string? diagnosticTag)
    {
        var succeeded = status == MutationResultStatus.ConfirmedSuccess ? 1 : 0;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0;
        var failed = succeeded == 0 && unknown == 0 &&
            status != MutationResultStatus.CancelledBeforeSubmission ? 1 : 0;
        return new MutationResult(
            1,
            status,
            "saveTextContent",
            submitted,
            requiresRefresh,
            new MutationResultCounts(succeeded, failed, unknown),
            errorCategory,
            diagnosticTag: diagnosticTag);
    }
}
