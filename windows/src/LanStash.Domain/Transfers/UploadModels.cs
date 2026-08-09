namespace LanStash.Domain;

/// <summary>
/// 单文件上传所需的稳定输入。调用方拥有并负责关闭 Content。
/// </summary>
public sealed class FileUploadRequest
{
    public Stream Content { get; }
    public long Length { get; }
    public string FolderPath { get; }
    public string FileName { get; }
    public bool Overwrite { get; }

    public FileUploadRequest(
        Stream content,
        long length,
        string folderPath,
        string fileName,
        bool overwrite = false)
    {
        ArgumentNullException.ThrowIfNull(content);
        if (!content.CanRead)
        {
            throw new ArgumentException("upload.stream_not_readable", nameof(content));
        }
        ArgumentOutOfRangeException.ThrowIfNegative(length);
        if (string.IsNullOrWhiteSpace(folderPath) ||
            !folderPath.StartsWith('/') ||
            folderPath.IndexOfAny(['\r', '\n', '\0']) >= 0)
        {
            throw new ArgumentException("upload.invalid_folder", nameof(folderPath));
        }
        if (string.IsNullOrWhiteSpace(fileName) ||
            fileName is "." or ".." ||
            fileName.IndexOfAny(['/', '\\', '\r', '\n', '\0']) >= 0)
        {
            throw new ArgumentException("upload.invalid_file_name", nameof(fileName));
        }

        Content = content;
        Length = length;
        FolderPath = folderPath;
        FileName = fileName;
        Overwrite = overwrite;
    }

    public override string ToString() => nameof(FileUploadRequest);
}

public enum FileUploadTransportStatus
{
    Accepted,
    ConfirmedFailure,
    CancelledBeforeSubmission,
    CancellationRequestedAfterSubmission,
    SubmittedButUnverified,
    Unsupported,
}

/// <summary>
/// 只描述一次 HTTP 上传尝试的事实，不把服务端响应成功等同于最终文件已核验。
/// </summary>
public sealed record FileUploadTransportResult(
    FileUploadTransportStatus Status,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);
