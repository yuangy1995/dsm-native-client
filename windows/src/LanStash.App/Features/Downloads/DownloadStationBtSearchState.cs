using System.Globalization;
using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

public enum DownloadBtSearchContentState
{
    Loading,
    Ready,
    NoProviders,
    Empty,
    FilteredEmpty,
    Error,
    Content,
}

public sealed record DownloadBtSearchModuleScopeOption(
    DownloadBtSearchModuleScope Value,
    string Title);

public sealed record DownloadBtSearchModuleOption(
    string Id,
    string Title,
    bool IsEnabled);

public sealed record DownloadBtSearchCategoryOption(
    string? Id,
    string Title);

public sealed record DownloadBtSearchSortOption(
    DownloadBtSearchSort Value,
    string Title);

public sealed record DownloadBtSearchDirectionOption(
    DownloadBtSearchDirection Value,
    string Title);

public sealed record DownloadBtSearchResultItem(DownloadBtSearchResult Result)
{
    public string Title => Result.Title;
    public string DownloadUri => Result.DownloadUri;
    public string MetadataText => LocalizationService.Current.Format(
        "DownloadStationBtSearchResultMetadata",
        TextOrUnavailable(Result.Provider),
        DownloadTaskItem.FormatBytes(Result.Size),
        FormatCount(Result.Seeds),
        FormatCount(Result.Peers),
        FormatCount(Result.Leeches),
        FormatListedAt(Result.ListedAt));
    public string AutomationName => LocalizationService.Current.Format(
        "DownloadStationBtSearchResultAutomationName",
        Title,
        MetadataText);

    private static string TextOrUnavailable(string? value) =>
        string.IsNullOrWhiteSpace(value)
            ? LocalizationService.Current.Get("DownloadStationValueUnavailable")
            : value;

    private static string FormatCount(int? value) => value is null
        ? LocalizationService.Current.Get("DownloadStationValueUnavailable")
        : value.Value.ToString("N0", CultureInfo.CurrentCulture);

    private static string FormatListedAt(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            !DateTime.TryParse(
                value,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AllowWhiteSpaces,
                out var parsed))
        {
            return LocalizationService.Current.Get("DownloadStationValueUnavailable");
        }
        return parsed.ToString("d", CultureInfo.CurrentCulture);
    }
}
