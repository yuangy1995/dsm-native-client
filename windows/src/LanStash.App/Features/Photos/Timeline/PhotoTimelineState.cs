using System.Collections.ObjectModel;
using LanStash.Domain;

namespace LanStash.App.Features.Photos.Timeline;

public enum PhotoTimelinePhase { Idle, Scanning, Content, Empty, Error }
public enum PhotoTimelineFilter { All, Images, Videos }

public sealed record PhotoTimelineEntry(PhotoItem Item)
{
    public string Name => Item.Name;
    public string Path => Item.Path;
    public bool IsImage => Item.Kind == PhotoItemKind.Image;
    public bool IsVideo => Item.Kind == PhotoItemKind.Video;
}

public sealed class PhotoTimelineGroup(string key, DateTimeOffset? month)
{
    public string Key { get; } = key;
    public DateTimeOffset? Month { get; } = month;
    public string Title { get; set; } = key;
    public ObservableCollection<PhotoTimelineEntry> Items { get; } = [];
}
