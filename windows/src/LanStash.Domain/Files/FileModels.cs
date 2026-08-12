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
