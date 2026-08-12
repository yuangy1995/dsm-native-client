namespace LanStash.Domain;

/// <summary>
/// 通过 File Station 搜索 API 执行启动、轮询、列出结果和清理任务的异步搜索。
/// </summary>
public interface IFileSearchRepository
{
    Guid ProfileId { get; }

    /// <summary>
    /// 当前连接是否支持异步搜索。
    /// 由 <c>SYNO.FileStation.Search</c> 能力发现结果控制。
    /// </summary>
    bool IsSearchAvailable { get; }

    Task<FileSearchResult> SearchAsync(
        FileSearchRequest request,
        CancellationToken cancellationToken = default);
}
