namespace LanStash.Domain;

/// <summary>
/// 只读文件分段来源。实现必须验证响应范围、总长度与内容版本，不能返回未经证明的拼接内容。
/// </summary>
public interface IFileRangeReader
{
    Task<FileRangeReadResult> ReadFileRangeResultAsync(
        string remotePath,
        long offset,
        long length,
        string? expectedContentVersion = null,
        long? expectedTotalLength = null,
        CancellationToken cancellationToken = default);
}
