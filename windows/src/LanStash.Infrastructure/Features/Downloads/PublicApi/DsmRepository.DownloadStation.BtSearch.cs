using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string PublicDownloadBtSearchApi = "SYNO.DownloadStation.BTSearch";
    private const int MaximumBtSearchPolls = 60;
    private const int MaximumBtSearchResults = 200;
    private static readonly TimeSpan BtSearchPollInterval = TimeSpan.FromMilliseconds(500);

    public async Task<DownloadBtSearchCatalog> LoadBtSearchCatalogAsync(
        CancellationToken cancellationToken = default)
    {
        EnsureReadablePublicDownloadStationContract();
        EnsureBtSearchContract();
        var modules = await CallPublicDownloadAsync(
            PublicDownloadBtSearchApi,
            "getModule",
            parameters: null,
            cancellationToken).ConfigureAwait(false);
        var categories = await CallPublicDownloadAsync(
            PublicDownloadBtSearchApi,
            "getCategory",
            parameters: null,
            cancellationToken).ConfigureAwait(false);
        return ParseBtSearchCatalog(modules, categories);
    }

    public async Task<IReadOnlyList<DownloadBtSearchResult>> SearchBtAsync(
        DownloadBtSearchRequest request,
        CancellationToken cancellationToken = default)
    {
        EnsureReadablePublicDownloadStationContract();
        EnsureBtSearchContract();
        var prepared = PrepareBtSearchRequest(request);
        var started = await CallPublicDownloadAsync(
            PublicDownloadBtSearchApi,
            "start",
            new Dictionary<string, string>
            {
                ["keyword"] = prepared.Keyword,
                ["module"] = prepared.Module,
            },
            cancellationToken).ConfigureAwait(false);
        var taskId = NativeNonEmptyString(started, "taskid")
            ?? throw InvalidDownloadStationResponse();

        try
        {
            for (var poll = 0; poll < MaximumBtSearchPolls; poll++)
            {
                var data = await CallPublicDownloadAsync(
                    PublicDownloadBtSearchApi,
                    "list",
                    new Dictionary<string, string>
                    {
                        ["taskid"] = taskId,
                        ["offset"] = "0",
                        ["limit"] = MaximumBtSearchResults.ToString(CultureInfo.InvariantCulture),
                        ["sort_by"] = prepared.Sort,
                        ["sort_direction"] = prepared.Direction,
                        ["filter_category"] = prepared.Category,
                        ["filter_title"] = prepared.TitleFilter,
                    },
                    cancellationToken).ConfigureAwait(false);
                if (NativeBool(data, "finished") is not bool finished)
                {
                    throw InvalidDownloadStationResponse();
                }
                if (finished)
                {
                    return ParseBtSearchResults(data);
                }
                await Task.Delay(BtSearchPollInterval, cancellationToken).ConfigureAwait(false);
            }
            throw InvalidDownloadStationResponse();
        }
        finally
        {
            await TryCleanBtSearchTaskAsync(taskId).ConfigureAwait(false);
        }
    }

    private void EnsureBtSearchContract()
    {
        if (!HasPublicDownloadVersion(PublicDownloadBtSearchApi))
        {
            throw MissingPublicDownloadStationContract();
        }
    }

    private async Task TryCleanBtSearchTaskAsync(string taskId)
    {
        try
        {
            await CallPublicDownloadAsync(
                PublicDownloadBtSearchApi,
                "clean",
                new Dictionary<string, string> { ["taskid"] = taskId },
                CancellationToken.None).ConfigureAwait(false);
        }
        catch
        {
            // 清理只能尽力执行，不能覆盖搜索成功、取消或原始失败的结果。
        }
    }

    private static DownloadBtSearchCatalog ParseBtSearchCatalog(
        JsonObject modulesData,
        JsonObject categoriesData)
    {
        if (modulesData["modules"] is not JsonArray moduleItems ||
            categoriesData["categories"] is not JsonArray categoryItems)
        {
            throw InvalidDownloadStationResponse();
        }

        var moduleIds = new HashSet<string>(StringComparer.Ordinal);
        var modules = moduleItems.Select(item =>
        {
            if (item is not JsonObject module ||
                NativeNonEmptyString(module, "id", allowComma: false) is not { } id ||
                NativeNonEmptyString(module, "title") is not { } title ||
                NativeBool(module, "enabled") is not bool enabled ||
                !moduleIds.Add(id))
            {
                throw InvalidDownloadStationResponse();
            }
            return new DownloadBtSearchModule(id, title, enabled);
        }).ToArray();

        var categoryIds = new HashSet<string>(StringComparer.Ordinal);
        var categories = categoryItems.Select(item =>
        {
            if (item is not JsonObject category ||
                NativeNonEmptyString(category, "id") is not { } id ||
                NativeNonEmptyString(category, "title") is not { } title ||
                !categoryIds.Add(id))
            {
                throw InvalidDownloadStationResponse();
            }
            return new DownloadBtSearchCategory(id, title);
        }).ToArray();

        return new DownloadBtSearchCatalog(modules, categories);
    }

    private readonly record struct PreparedBtSearchRequest(
        string Keyword,
        string Module,
        string Category,
        string Sort,
        string Direction,
        string TitleFilter);

    private PreparedBtSearchRequest PrepareBtSearchRequest(DownloadBtSearchRequest request)
    {
        if (request.ProfileId != _profile.Id || _session.ProfileId != _profile.Id)
        {
            throw InvalidDownloadStationResponse();
        }
        if (request.Keyword.Any(char.IsControl))
        {
            throw new ArgumentException("download.bt.search.invalid_keyword", nameof(request));
        }
        var keyword = request.Keyword.Trim();
        if (!StableBtSearchText(keyword, required: true, allowComma: true, maxLength: 200))
        {
            throw new ArgumentException("download.bt.search.invalid_keyword", nameof(request));
        }
        if (request.TitleFilter.Any(char.IsControl))
        {
            throw new ArgumentException("download.bt.search.invalid_title_filter", nameof(request));
        }
        var titleFilter = request.TitleFilter.Trim();
        if (!StableBtSearchText(titleFilter, required: false, allowComma: true, maxLength: 200))
        {
            throw new ArgumentException("download.bt.search.invalid_title_filter", nameof(request));
        }
        if (request.CategoryId?.Any(char.IsControl) == true)
        {
            throw new ArgumentException("download.bt.search.invalid_category", nameof(request));
        }
        var category = string.IsNullOrWhiteSpace(request.CategoryId)
            ? string.Empty
            : request.CategoryId.Trim();
        if (!StableBtSearchText(category, required: false, allowComma: true, maxLength: 128))
        {
            throw new ArgumentException("download.bt.search.invalid_category", nameof(request));
        }

        var module = request.ModuleScope switch
        {
            DownloadBtSearchModuleScope.All => "all",
            DownloadBtSearchModuleScope.Enabled => "enabled",
            DownloadBtSearchModuleScope.Selected => SelectedModuleValue(request.SelectedModuleIds),
            _ => throw new ArgumentOutOfRangeException(nameof(request)),
        };

        return new(
            keyword,
            module,
            category,
            BtSearchSortValue(request.Sort),
            BtSearchDirectionValue(request.Direction),
            titleFilter);
    }

    private static string SelectedModuleValue(IReadOnlySet<string> values)
    {
        if (values.Any(value => value.Any(char.IsControl)))
        {
            throw new ArgumentException("download.bt.search.invalid_module");
        }
        var modules = values
            .Select(value => value.Trim())
            .Where(value => value.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .Order(StringComparer.Ordinal)
            .ToArray();
        if (modules.Length == 0 ||
            modules.Any(value => !StableBtSearchText(value, required: true, allowComma: false, maxLength: 128)))
        {
            throw new ArgumentException("download.bt.search.invalid_module");
        }
        return string.Join(",", modules);
    }

    private static IReadOnlyList<DownloadBtSearchResult> ParseBtSearchResults(JsonObject data)
    {
        if (data["items"] is not JsonArray items || items.Count > MaximumBtSearchResults)
        {
            throw InvalidDownloadStationResponse();
        }
        var uris = new HashSet<string>(StringComparer.Ordinal);
        return items.Select(item =>
        {
            if (item is not JsonObject result ||
                NativeNonEmptyString(result, "download_uri") is not { } downloadUri ||
                !uris.Add(downloadUri))
            {
                throw InvalidDownloadStationResponse();
            }
            return new DownloadBtSearchResult(
                NativeNonEmptyString(result, "title") ?? downloadUri,
                OptionalNativeNonNegativeLong(result, "size"),
                NativeNonEmptyString(result, "date"),
                downloadUri,
                NativeNonEmptyString(result, "external_link"),
                OptionalNativeNonNegativeInt(result, "peers"),
                OptionalNativeNonNegativeInt(result, "seeds"),
                OptionalNativeNonNegativeInt(result, "leechs"),
                NativeNonEmptyString(result, "module_title"));
        }).ToArray();
    }

    private static string? NativeNonEmptyString(
        JsonObject item,
        string key,
        bool allowComma = true)
    {
        if (!item.TryGetPropertyValue(key, out var node) ||
            node is not JsonValue value ||
            !value.TryGetValue<string>(out var text) ||
            !StableBtSearchText(text, required: true, allowComma: allowComma, maxLength: 2_048))
        {
            return null;
        }
        return text;
    }

    private static bool? NativeBool(JsonObject item, string key)
    {
        if (!item.TryGetPropertyValue(key, out var node) ||
            node is not JsonValue value ||
            !value.TryGetValue<bool>(out var result))
        {
            return null;
        }
        return result;
    }

    private static long? OptionalNativeNonNegativeLong(JsonObject item, string key)
    {
        if (!item.TryGetPropertyValue(key, out var node))
        {
            return null;
        }
        if (node is not JsonValue value)
        {
            throw InvalidDownloadStationResponse();
        }
        if (value.TryGetValue<long>(out var longValue))
        {
            return longValue >= 0 ? longValue : throw InvalidDownloadStationResponse();
        }
        if (value.TryGetValue<int>(out var intValue))
        {
            return intValue >= 0 ? intValue : throw InvalidDownloadStationResponse();
        }
        throw InvalidDownloadStationResponse();
    }

    private static int? OptionalNativeNonNegativeInt(JsonObject item, string key)
    {
        var value = OptionalNativeNonNegativeLong(item, key);
        return value is null
            ? null
            : value <= int.MaxValue
                ? (int)value.Value
                : throw InvalidDownloadStationResponse();
    }

    private static bool StableBtSearchText(
        string value,
        bool required,
        bool allowComma,
        int maxLength)
    {
        if (value.Length == 0)
        {
            return !required;
        }
        return value.Length <= maxLength &&
            string.Equals(value, value.Trim(), StringComparison.Ordinal) &&
            !value.Any(char.IsControl) &&
            (allowComma || !value.Contains(',', StringComparison.Ordinal));
    }

    private static string BtSearchSortValue(DownloadBtSearchSort sort) => sort switch
    {
        DownloadBtSearchSort.Title => "title",
        DownloadBtSearchSort.Size => "size",
        DownloadBtSearchSort.Date => "date",
        DownloadBtSearchSort.Peers => "peers",
        DownloadBtSearchSort.Provider => "provider",
        DownloadBtSearchSort.Seeds => "seeds",
        DownloadBtSearchSort.Leeches => "leechs",
        _ => throw new ArgumentOutOfRangeException(nameof(sort), sort, null),
    };

    private static string BtSearchDirectionValue(DownloadBtSearchDirection direction) => direction switch
    {
        DownloadBtSearchDirection.Ascending => "asc",
        DownloadBtSearchDirection.Descending => "desc",
        _ => throw new ArgumentOutOfRangeException(nameof(direction), direction, null),
    };
}
