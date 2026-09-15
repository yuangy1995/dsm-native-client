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
    public string SizeText => Item.IsDirectory ? string.Empty : FormatSize(Item.Size);
    public string ModifiedText => Item.ModifiedAt?.ToLocalTime().ToString("g") ??
        LocalizationService.Current.Get("UnknownValue");
    public bool IsDirectory => Item.IsDirectory;
    public string Glyph => Item.IsDirectory ? "\uE8B7" : "\uE8A5";

    private static string FormatSize(long size)
    {
        if (size < 0) return LocalizationService.Current.Get("UnknownValue");
        string[] keys = ["NasDetailsByteUnitB", "NasDetailsByteUnitKB", "NasDetailsByteUnitMB", "NasDetailsByteUnitGB", "NasDetailsByteUnitTB"];
        var value = (double)size;
        var unit = 0;
        while (value >= 1024 && unit < keys.Length - 1) { value /= 1024; unit++; }
        return $"{value.ToString(unit == 0 ? "N0" : "N1")} {LocalizationService.Current.Get(keys[unit])}";
    }

    public string Detail => Item.IsDirectory
        ? Item.Path
        : LocalizationService.Current.Format(
            "FileBrowserFileDetail",
            Item.Size,
            Item.ModifiedAt?.ToLocalTime().ToString("g") ??
            LocalizationService.Current.Get("UnknownValue"));
}
