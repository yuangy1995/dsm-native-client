using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.Files;

public enum FileBrowserContentState
{
    Loading,
    Empty,
    FilteredEmpty,
    Error,
    Content,
}

public enum FileBrowserLayout
{
    List,
    Grid,
}

public readonly record struct FileBrowserRequestKey(
    string Path,
    FileListOptions Options);

public sealed record FileBrowserLocation(
    string Path,
    FileListOptions PreferredOptions,
    string QuickFilterText,
    string? SelectedPath);

public sealed record FileBrowserBreadcrumb(string Name, string Path)
{
    public override string ToString() => Name;
}

public sealed record FileBrowserEntry(FileItem Item)
{
    public string Path => Item.Path;
    public string Name => Item.Name;
    public bool IsDirectory => Item.IsDirectory;
    public string Glyph => Item.IsDirectory ? "\uE8B7" : "\uE8A5";

    public string Detail => Item.IsDirectory
        ? Item.Path
        : LocalizationService.Current.Format(
            "FileBrowserFileDetail",
            Item.Size,
            Item.ModifiedAt?.ToLocalTime().ToString("g") ??
            LocalizationService.Current.Get("UnknownValue"));
}
