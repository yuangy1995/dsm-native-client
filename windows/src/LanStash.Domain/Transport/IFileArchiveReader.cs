namespace LanStash.Domain;

public enum FileArchiveContractFailure
{
    UnsupportedVersion,
    UnexpectedStatus,
    UnexpectedMediaType,
    InvalidZipSignature,
    EmptyResponse,
}

public sealed class FileArchiveContractException(
    FileArchiveContractFailure failure,
    string message,
    int? statusCode = null) : Exception(message)
{
    public FileArchiveContractFailure Failure { get; } = failure;
    public int? StatusCode { get; } = statusCode;
}

/// <summary>
/// 官方 File Station Download 目录压缩流来源。实现必须在转发内容前校验响应类型和 ZIP 签名，
/// 并保持有界内存占用。传给回调的内存只在该次回调返回前有效，调用方不得保留引用。
/// </summary>
public interface IFileArchiveReader
{
    /// <summary>多个项目或单个文件夹返回一个 ZIP；单个普通文件应使用原文件下载。</summary>
    Task StreamArchiveAsync(IReadOnlyList<string> remotePaths,
        Func<ReadOnlyMemory<byte>, CancellationToken, ValueTask> writeChunkAsync,
        CancellationToken cancellationToken = default) => remotePaths.Count == 1
            ? StreamFolderArchiveAsync(remotePaths[0], writeChunkAsync, cancellationToken)
            : Task.FromException(new NotSupportedException("The repository does not implement selection archive downloads."));

    Task StreamFolderArchiveAsync(
        string remotePath,
        Func<ReadOnlyMemory<byte>, CancellationToken, ValueTask> writeChunkAsync,
        CancellationToken cancellationToken = default) =>
        Task.FromException(new NotSupportedException(
            "The repository does not implement folder archive downloads."));
}
