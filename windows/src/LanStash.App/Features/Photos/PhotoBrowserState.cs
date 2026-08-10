using LanStash.Domain;

namespace LanStash.App.Features.Photos;

public enum PhotoBrowserContentState
{
    Loading,
    Empty,
    FilteredEmpty,
    Error,
    Content,
}

public enum PhotoBrowserFilter
{
    All,
    Images,
}

public readonly record struct PhotoBrowserPageKey(
    Guid ProfileId,
    string SpaceId,
    string Path,
    PhotoBrowserFilter Filter);

public sealed record PhotoBrowserLocation(
    string SpaceId,
    string Path,
    PhotoBrowserFilter Filter,
    string? SelectedPath);

public sealed record PhotoBrowserBreadcrumb(string Name, string Path)
{
    public override string ToString() => Name;
}

public sealed record PhotoBrowserEntry(PhotoItem Item)
{
    public string Id => Item.Id;
    public string Name => Item.Name;
    public string Path => Item.Path;
    public bool IsFolder => Item.Kind == PhotoItemKind.Folder;
    public bool IsImage => Item.Kind == PhotoItemKind.Image;
    public bool IsVideo => Item.Kind == PhotoItemKind.Video;
    public bool IsMedia => IsImage || IsVideo;
}
