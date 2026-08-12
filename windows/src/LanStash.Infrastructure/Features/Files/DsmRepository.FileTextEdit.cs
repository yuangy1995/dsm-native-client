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
        CanEdit: true,
        CanFormat: true,
        SupportedExtensions: TextEditExtensionsList);

    async Task<FileTextContentSnapshot> IFilePreviewRepository.DownloadTextContentSnapshotAsync(
        string path,
        long expectedFileSize,
        long maxBytes,
        CancellationToken cancellationToken)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(expectedFileSize);
        ArgumentOutOfRangeException.ThrowIfLessThan(maxBytes, 1);
        if (expectedFileSize > maxBytes || maxBytes > TextEditMaxBytes)
        {
            throw new ArgumentOutOfRangeException(nameof(expectedFileSize), "textedit.size_exceeded");
        }
        if (expectedFileSize == 0)
        {
            throw new InvalidOperationException("textedit.version_unavailable");
        }

        var result = await ReadFileRangeResultAsync(
            path,
            0,
            expectedFileSize,
            expectedTotalLength: expectedFileSize,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (result.ActualByteCount != expectedFileSize ||
            result.ServerContentVersion is not { Length: > 0 } contentVersion)
        {
            throw new InvalidOperationException("textedit.version_unavailable");
        }

        var bytes = result.Bytes.AsSpan(0, checked((int)result.ActualByteCount));
        return new FileTextContentSnapshot(
            DecodeTextEditContent(bytes),
            result.ActualByteCount,
            contentVersion,
            Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant());
    }

    private async Task<MutationResult> UploadTextContentAsync(
        string path,
        string content,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(content);

        var parent = path.Contains('/')
            ? path[..path.LastIndexOf('/')]
            : "/";
        var fileName = path[(path.LastIndexOf('/') + 1)..];

        if (string.IsNullOrWhiteSpace(fileName) ||
            fileName is "." or "..")
        {
            return MutationResultSave(
                MutationResultStatus.ConfirmedFailure,
                false,
                false,
                MutationErrorCategory.Validation,
                "file.textedit.invalid_file_name");
        }

        var tempFile = Path.GetTempFileName();
        try
        {
            // 保存统一使用无 BOM 的 UTF-8，避免静默改变正文开头。
            await File.WriteAllTextAsync(
                tempFile,
                content,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                cancellationToken).ConfigureAwait(false);

            var fileInfo = new FileInfo(tempFile);
            using var stream = new FileStream(
                tempFile,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                4096,
                FileOptions.DeleteOnClose);

            var request = new FileUploadRequest(
                stream,
                fileInfo.Length,
                parent,
                fileName,
                overwrite: true);

            return await UploadFileAsync(request, progress: null, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            return MutationResultSave(
                MutationResultStatus.CancellationRequestedAfterSubmission,
                true,
                true,
                MutationErrorCategory.Network,
                "file.textedit.cancelled-after-submit");
        }
        catch (Exception) when (!File.Exists(tempFile))
        {
            return MutationResultSave(
                MutationResultStatus.ConfirmedFailure,
                false,
                false,
                MutationErrorCategory.Unknown,
                "file.textedit.temp_file_lost");
        }
        finally
        {
            try { File.Delete(tempFile); } catch { }
        }
    }

    async Task<MutationResult> IFilePreviewRepository.SaveTextContentAsync(
        string path,
        string content,
        FileTextContentSnapshot original,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(content);
        ArgumentNullException.ThrowIfNull(original);
        var encoded = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(content);
        if (encoded.LongLength > TextEditMaxBytes)
        {
            return MutationResultSave(
                MutationResultStatus.ConfirmedFailure,
                false,
                false,
                MutationErrorCategory.Validation,
                "file.textedit.size-exceeded");
        }

        try
        {
            var current = await ReadFileRangeResultAsync(
                path,
                0,
                original.ByteLength,
                expectedContentVersion: original.ContentVersion,
                expectedTotalLength: original.ByteLength,
                cancellationToken: cancellationToken).ConfigureAwait(false);
            var currentBytes = current.Bytes.AsSpan(0, checked((int)current.ActualByteCount));
            var currentHash = Convert.ToHexString(SHA256.HashData(currentBytes)).ToLowerInvariant();
            if (!string.Equals(currentHash, original.Sha256, StringComparison.Ordinal))
            {
                return MutationResultSave(
                    MutationResultStatus.ConfirmedFailure,
                    false,
                    false,
                    MutationErrorCategory.Conflict,
                    "file.textedit.source-changed");
            }
        }
        catch (OperationCanceledException)
        {
            return MutationResultSave(
                MutationResultStatus.CancelledBeforeSubmission,
                false,
                false,
                null,
                "file.textedit.cancelled");
        }
        catch (FileRangeContractException error)
            when (error.Failure == FileRangeContractFailure.ContentVersionMismatch)
        {
            return MutationResultSave(
                MutationResultStatus.ConfirmedFailure,
                false,
                false,
                MutationErrorCategory.Conflict,
                "file.textedit.source-changed");
        }
        catch
        {
            return MutationResultSave(
                MutationResultStatus.ConfirmedFailure,
                false,
                false,
                MutationErrorCategory.Network,
                "file.textedit.preflight-unavailable");
        }

        var upload = await UploadTextContentAsync(
            path,
            content,
            cancellationToken).ConfigureAwait(false);
        if (!upload.Submitted || upload.Status == MutationResultStatus.ConfirmedFailure)
        {
            return upload;
        }

        try
        {
            var readback = await ReadFileRangeResultAsync(
                path,
                0,
                encoded.LongLength,
                expectedTotalLength: encoded.LongLength,
                cancellationToken: CancellationToken.None).ConfigureAwait(false);
            var readbackBytes = readback.Bytes.AsSpan(0, checked((int)readback.ActualByteCount));
            if (readback.ActualByteCount == encoded.LongLength &&
                SHA256.HashData(readbackBytes).AsSpan().SequenceEqual(SHA256.HashData(encoded)))
            {
                return MutationResultSave(
                    MutationResultStatus.ConfirmedSuccess,
                    true,
                    false,
                    null,
                    null);
            }
        }
        catch
        {
            // 提交后的读取失败不能触发第二次上传。
        }
        return MutationResultSave(
            MutationResultStatus.SubmittedButUnverified,
            true,
            true,
            MutationErrorCategory.Unknown,
            "file.textedit.readback-unverified");
    }

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
        if (bytes.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }))
        {
            return Encoding.UTF8.GetString(bytes[3..]);
        }
        if (bytes.StartsWith(new byte[] { 0xFF, 0xFE }))
        {
            return Encoding.Unicode.GetString(bytes[2..]);
        }
        if (bytes.StartsWith(new byte[] { 0xFE, 0xFF }))
        {
            return Encoding.BigEndianUnicode.GetString(bytes[2..]);
        }
        // 无 BOM 时严格按 UTF-8 解码，无效字节直接拒绝编辑。
        try
        {
            return new UTF8Encoding(false, true).GetString(bytes);
        }
        catch (DecoderFallbackException)
        {
            throw new InvalidOperationException("textedit.encoding_error");
        }
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
