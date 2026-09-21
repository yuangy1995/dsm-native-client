using LanStash.Domain;

namespace LanStash.App.Features.Files.Downloads;

public static class FileDownloadSelection
{
    public static bool IsValidItem(FileItem? item) => item is not null && FileArchivePaths.IsValid(item.Path) &&
        item.Name == item.Path[(item.Path.LastIndexOf('/') + 1)..] && (item.IsDirectory || item.Size >= 0);

    public static bool IsValid(IReadOnlyList<FileItem> items) => items.Count > 0 && items.All(IsValidItem) &&
        items.Select(item => item.Path).Distinct(StringComparer.Ordinal).Count() == items.Count;

    public static bool UsesArchive(IReadOnlyList<FileItem> items) => items.Count > 1 || items.Count == 1 && items[0].IsDirectory;

    public static string SourceLocation(IReadOnlyList<FileItem> items)
    {
        if (items.Count == 1) return items[0].Path;
        var parent = items[0].Path[..items[0].Path.LastIndexOf('/')];
        foreach (var item in items.Skip(1))
            while (parent.Length > 0 && !item.Path.StartsWith(parent + "/", StringComparison.Ordinal))
                parent = parent[..parent.LastIndexOf('/')];
        return parent.Length == 0 ? "/" : parent;
    }

    public static bool MatchesSnapshot(IReadOnlyList<FileItem> snapshot, IReadOnlyList<FileItem> current, IReadOnlySet<string> selectedPaths)
    {
        if (snapshot.Count == 0 || snapshot.Count != selectedPaths.Count) return false;
        var selected = new Dictionary<string, FileItem>(StringComparer.Ordinal);
        foreach (var item in current.Where(item => selectedPaths.Contains(item.Path)))
            if (!selected.TryAdd(item.Path, item)) return false;
        return selected.Count == snapshot.Count && snapshot.All(item => selected.TryGetValue(item.Path, out var present) && present == item);
    }
}
