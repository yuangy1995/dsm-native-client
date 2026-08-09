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
    int Offset);

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
