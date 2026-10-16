namespace LanStash.Domain;

public sealed record FileItem(
    string Path,
    string Name,
    bool IsDirectory,
    long Size,
    DateTimeOffset? ModifiedAt,
    string? Owner,
    bool CanWrite,
    bool CanDelete);

public sealed record FilePage(
    IReadOnlyList<FileItem> Items,
    int Total,
    int Offset,
    StorageSpaceSummary? StorageSpace = null);

/// <summary>
/// 当前账号通过 File Station 可见的存储空间汇总，不代表管理员看到的物理硬盘容量。
/// </summary>
public sealed record StorageSpaceSummary
{
    public StorageSpaceSummary(long totalBytes, long remainingBytes, int volumeCount)
    {
        TotalBytes = Math.Max(totalBytes, 0);
        RemainingBytes = Math.Clamp(remainingBytes, 0, TotalBytes);
        VolumeCount = Math.Max(volumeCount, 0);
    }

    public long TotalBytes { get; }
    public long RemainingBytes { get; }
    public int VolumeCount { get; }
    public long UsedBytes => Math.Max(TotalBytes - RemainingBytes, 0);

    public double UsedFraction => TotalBytes > 0
        ? Math.Clamp((double)UsedBytes / TotalBytes, 0, 1)
        : 0;
}

public enum FileListSortField
{
    Name,
    Size,
    ModifiedTime,
}

public enum FileListSortDirection
{
    Ascending,
    Descending,
}

public enum FileListTypeFilter
{
    All,
    Files,
    Folders,
}

public readonly record struct FileListOptions(
    FileListSortField SortField = FileListSortField.Name,
    FileListSortDirection SortDirection = FileListSortDirection.Ascending,
    FileListTypeFilter TypeFilter = FileListTypeFilter.All)
{
    public static FileListOptions Default { get; } = new();

    public FileListOptions NormalizeForSharedRoot() =>
        this with
        {
            SortField = FileListSortField.Name,
            TypeFilter = FileListTypeFilter.All,
        };
}

/// <summary>
/// 通过 File Station 搜索 API 异步搜索文件的请求。
/// </summary>
public sealed record FileSearchRequest(
    string FolderPath,
    string Query,
    bool Recursive)
{
    public FileListTypeFilter Kind { get; init; }
    public string Extension { get; init; } = string.Empty;
    public long? MinimumBytes { get; init; }
    public long? MaximumBytes { get; init; }
    public FileSearchTimeRange Modified { get; init; } = new();
    public FileSearchTimeRange Created { get; init; } = new();
    public FileSearchTimeRange Accessed { get; init; } = new();
    public string Owner { get; init; } = string.Empty;
    public string Group { get; init; } = string.Empty;
    public bool SearchesContents { get; init; }

    public bool HasConditions => !string.IsNullOrWhiteSpace(Query) || Kind != FileListTypeFilter.All ||
        !string.IsNullOrWhiteSpace(Extension) || MinimumBytes.HasValue || MaximumBytes.HasValue ||
        Modified != new FileSearchTimeRange() || Created != new FileSearchTimeRange() ||
        Accessed != new FileSearchTimeRange() || !string.IsNullOrWhiteSpace(Owner) || !string.IsNullOrWhiteSpace(Group);

    public void Validate()
    {
        if (!Enum.IsDefined(Kind) || MinimumBytes < 0 || MaximumBytes < 0 || MinimumBytes > MaximumBytes ||
            !Modified.IsValid || !Created.IsValid || !Accessed.IsValid ||
            SearchesContents && string.IsNullOrWhiteSpace(Query))
            throw new ArgumentException("file.search.invalid-conditions");
        _ = CreateNameRegex();
    }

    /// <summary>仅识别闭合斜线及可选 i 标志；其他输入保持普通名称条件。</summary>
    public System.Text.RegularExpressions.Regex? CreateNameRegex()
    {
        if (!Query.StartsWith('/') || Query.Length < 2) return null;
        var end = Query.LastIndexOf('/');
        if (end == 0 || end != Query.Length - 1 && Query[(end + 1)..] != "i") return null;
        if (SearchesContents) throw new ArgumentException("file.search.content-regex-conflict");
        var options = System.Text.RegularExpressions.RegexOptions.CultureInvariant;
        if (end < Query.Length - 1) options |= System.Text.RegularExpressions.RegexOptions.IgnoreCase;
        return new(Query[1..end], options, TimeSpan.FromMilliseconds(250));
    }
}

public sealed record FileSearchTimeRange(DateTimeOffset? From = null, DateTimeOffset? To = null)
{
    public bool IsValid => !(From < DateTimeOffset.UnixEpoch || To < DateTimeOffset.UnixEpoch || From > To);
}

public enum FileSearchIndexCoverage { NotRequested, Complete, Incomplete }

/// <summary>
/// 包含文件项和分页元数据的异步搜索结果。
/// </summary>
public sealed record FileSearchResult(
    IReadOnlyList<FileItem> Items,
    int TotalCount,
    bool IsTruncated)
{
    public FileSearchIndexCoverage IndexCoverage { get; init; }
}
