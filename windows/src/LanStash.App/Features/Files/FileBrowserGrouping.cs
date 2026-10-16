using System.Collections.ObjectModel;
using System.Globalization;
using LanStash.App.Features.Files.Preview;
using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.Files;

public enum FileBrowserGrouping { None, Type, Date, Size }

public sealed class FileBrowserGroup(string key, IEnumerable<FileBrowserEntry> items)
    : ObservableCollection<FileBrowserEntry>(items)
{
    public string Key { get; } = key;
    public string Title => LocalizationService.Current.Get(Key switch
    {
        "Folder" => "FileGroupFolder", "Image" => "FileGroupImage", "Video" => "FileGroupVideo",
        "Audio" => "FileGroupAudio", "Document" => "FileGroupDocument", "Other" => "FileGroupOther",
        "Today" => "FileGroupToday", "Yesterday" => "FileGroupYesterday", "Week" => "FileGroupWeek",
        "Month" => "FileGroupMonth", "Earlier" => "FileGroupEarlier", "UnknownDate" => "FileGroupUnknownDate",
        "Tiny" => "FileGroupTiny", "Small" => "FileGroupSmall", "Medium" => "FileGroupMedium",
        "Large" => "FileGroupLarge", "UnknownSize" => "FileGroupUnknownSize",
        _ => throw new InvalidOperationException("file.group.invalid-key"),
    });
}

public sealed partial class FileBrowserViewModel
{
    private FileBrowserGrouping _grouping;
    public FileBrowserGrouping Grouping
    {
        get => _grouping;
        set
        {
            ThrowIfDisposed();
            if (!Enum.IsDefined(value)) throw new ArgumentOutOfRangeException(nameof(value));
            if (SetProperty(ref _grouping, value)) RebuildGroups();
        }
    }
    public IReadOnlyList<FileBrowserGroup> Groups { get; private set; } = [];

    private void RebuildGroups()
    {
        Groups = BuildGroups(Items, Grouping, DateTimeOffset.Now, TimeZoneInfo.Local, CultureInfo.CurrentCulture);
        RaisePropertyChanged(nameof(Groups));
    }

    internal static IReadOnlyList<FileBrowserGroup> BuildGroups(IEnumerable<FileBrowserEntry> items,
        FileBrowserGrouping grouping, DateTimeOffset now, TimeZoneInfo zone, CultureInfo culture)
    {
        if (grouping == FileBrowserGrouping.None) return [];
        var today = TimeZoneInfo.ConvertTime(now, zone).Date;
        var week = today.AddDays(-((7 + (int)today.DayOfWeek - (int)culture.DateTimeFormat.FirstDayOfWeek) % 7));
        var month = new DateTime(today.Year, today.Month, 1);
        var order = grouping switch
        {
            FileBrowserGrouping.Type => new[] { "Folder", "Image", "Video", "Audio", "Document", "Other" },
            FileBrowserGrouping.Date => ["Today", "Yesterday", "Week", "Month", "Earlier", "UnknownDate"],
            _ => ["Folder", "Tiny", "Small", "Medium", "Large", "UnknownSize"],
        };
        var buckets = items.GroupBy(Key).ToDictionary(group => group.Key, group => group.ToArray());
        // 分组只重排组的顺序，组内沿用当前排序；原条目身份和选择不变。
        return order.Where(buckets.ContainsKey).Select(key => new FileBrowserGroup(key, buckets[key])).ToArray();

        string Key(FileBrowserEntry entry)
        {
            var item = entry.Item;
            if (grouping == FileBrowserGrouping.Date)
            {
                if (item.ModifiedAt is not { } modified) return "UnknownDate";
                var date = TimeZoneInfo.ConvertTime(modified, zone).Date;
                if (date == today) return "Today";
                if (date == today.AddDays(-1)) return "Yesterday";
                if (date >= week && date < week.AddDays(7)) return "Week";
                if (date >= month && date < month.AddMonths(1)) return "Month";
                return "Earlier";
            }
            if (item.IsDirectory) return "Folder";
            if (grouping == FileBrowserGrouping.Size) return item.Size switch
            {
                < 0 => "UnknownSize", < 10 * 1024 * 1024 => "Tiny", < 100 * 1024 * 1024 => "Small",
                < 1024L * 1024 * 1024 => "Medium", _ => "Large",
            };
            if (Path.GetExtension(item.Name).ToLowerInvariant() is ".doc" or ".docx" or ".xls" or ".xlsx" or ".ppt" or ".pptx")
                return "Document";
            return FilePreviewClassifier.Classify(item) switch
            {
                FilePreviewKind.Image => "Image", FilePreviewKind.Video => "Video", FilePreviewKind.Audio => "Audio",
                FilePreviewKind.Pdf or FilePreviewKind.Text => "Document", _ => "Other",
            };
        }
    }
}
