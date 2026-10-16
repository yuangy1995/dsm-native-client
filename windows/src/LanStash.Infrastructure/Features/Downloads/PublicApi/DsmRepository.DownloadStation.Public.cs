using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Download Station 官方公开只读接口适配器。内部 DownloadStation2 API 不属于本契约。
/// </summary>
public sealed partial class DsmRepository
{
    private const string PublicDownloadInfoApi = "SYNO.DownloadStation.Info";
    private const string PublicDownloadScheduleApi = "SYNO.DownloadStation.Schedule";
    private const string PublicDownloadTaskApi = "SYNO.DownloadStation.Task";
    private const string PublicDownloadStatisticApi = "SYNO.DownloadStation.Statistic";
    private const string PublicDownloadRssSiteApi = "SYNO.DownloadStation.RSS.Site";
    private const string PublicDownloadRssFeedApi = "SYNO.DownloadStation.RSS.Feed";
    private const int PublicDownloadApiVersion = 1;
    private const int MaximumTaskPageSize = 100;
    private static readonly IReadOnlySet<DownloadStationReadFeature> PublicDownloadTaskFeatures =
        new HashSet<DownloadStationReadFeature>
        {
            DownloadStationReadFeature.Tasks,
            DownloadStationReadFeature.TaskAdvancedDetails,
        };

    private bool HasReadablePublicDownloadStationContract =>
        HasPublicDownloadVersion(PublicDownloadTaskApi);

    private DownloadStationAvailability PublicDownloadAvailability
    {
        get
        {
            if (!HasReadablePublicDownloadStationContract)
            {
                return new(
                    DownloadStationAvailabilityStatus.Unavailable,
                    new HashSet<DownloadStationReadFeature>());
            }

            var features = new HashSet<DownloadStationReadFeature>(PublicDownloadTaskFeatures);
            if (HasPublicDownloadVersion(PublicDownloadStatisticApi))
            {
                features.Add(DownloadStationReadFeature.ActivitySummary);
            }
            if (HasPublicDownloadVersion(PublicDownloadInfoApi) || HasPublicDownloadVersion(PublicDownloadInfoApi, 2))
            {
                if (HasPublicDownloadVersion(PublicDownloadInfoApi, 2)) features.Add(DownloadStationReadFeature.DefaultDestination);
                features.Add(DownloadStationReadFeature.ServerSettings);
            }
            if (HasPublicDownloadVersion(PublicDownloadRssSiteApi) &&
                HasPublicDownloadVersion(PublicDownloadRssFeedApi))
            {
                features.Add(DownloadStationReadFeature.RssSummary);
            }
            if (HasPublicDownloadVersion(PublicDownloadBtSearchApi))
            {
                features.Add(DownloadStationReadFeature.BtSearch);
            }
            return new(DownloadStationAvailabilityStatus.Available, features)
            { SupportsCreateDestination = HasPublicDownloadVersion(PublicDownloadTaskApi, 2) };
        }
    }

    DownloadStationAvailability IDownloadStationRepository.Availability =>
        PublicDownloadAvailability;

    public async Task<DownloadTaskPage> ListTasksAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken = default)
    {
        EnsureReadablePublicDownloadStationContract();
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
        var safeLimit = Math.Min(limit, MaximumTaskPageSize);
        var data = await CallPublicDownloadAsync(
            PublicDownloadTaskApi,
            "list",
            new Dictionary<string, string>
            {
                ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                ["limit"] = safeLimit.ToString(CultureInfo.InvariantCulture),
                ["additional"] = "detail,transfer,file,tracker,peer",
            },
            cancellationToken).ConfigureAwait(false);

        var sourceOffset = data.ContainsKey("offset") ? RequiredNonNegativeInt(data, "offset") : offset;
        int? sourceTotal = data.ContainsKey("total") ? RequiredNonNegativeInt(data, "total") : null;
        if (sourceOffset != offset || data["tasks"] is not JsonArray sourceTasks)
        {
            throw InvalidDownloadStationResponse();
        }

        var taskObjects = new JsonObject[sourceTasks.Count];
        for (var index = 0; index < sourceTasks.Count; index++)
        {
            taskObjects[index] = sourceTasks[index] as JsonObject
                ?? throw InvalidDownloadStationResponse();
        }
        if (sourceTotal < sourceOffset || sourceTasks.Count > safeLimit)
        {
            throw InvalidDownloadStationResponse();
        }
        if (sourceOffset > int.MaxValue - sourceTasks.Count)
        {
            throw InvalidDownloadStationResponse();
        }
        var nextOffset = sourceOffset + sourceTasks.Count;
        if (nextOffset > sourceTotal ||
            (sourceTasks.Count == 0 && sourceOffset < sourceTotal))
        {
            throw InvalidDownloadStationResponse();
        }

        var tasks = taskObjects.Select(ParsePublicDownloadTask).ToArray();
        if (tasks.Select(task => task.Id).Distinct(StringComparer.Ordinal).Count() != tasks.Length)
        {
            throw InvalidDownloadStationResponse();
        }
        var hasMore = sourceTotal is int total ? nextOffset < total : sourceTasks.Count == safeLimit;
        return new(
            tasks,
            sourceOffset,
            sourceTasks.Count,
            sourceTotal,
            hasMore ? nextOffset : null,
            hasMore);
    }

    public async Task<DownloadStationSnapshot> LoadSnapshotAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken = default)
    {
        var tasks = await ListTasksAsync(offset, limit, cancellationToken).ConfigureAwait(false);
        var activity = await LoadPublicDownloadActivityAsync(cancellationToken).ConfigureAwait(false);
        var settings = await LoadPublicDownloadSettingsAsync(cancellationToken).ConfigureAwait(false);
        var rss = await LoadPublicDownloadRssAsync(cancellationToken).ConfigureAwait(false);
        var defaultDestination = settings.Status == DownloadStationSectionStatus.Available
            ? settings.Value?.DefaultDestination
            : null;
        return new(
            _profile.Id,
            tasks,
            activity,
            new(
                string.IsNullOrWhiteSpace(defaultDestination)
                    ? DownloadStationSectionStatus.Unavailable
                    : DownloadStationSectionStatus.Available,
                defaultDestination))
        {
            Settings = settings,
            Rss = rss,
        };
    }

    private async Task<DownloadActivitySection> LoadPublicDownloadActivityAsync(
        CancellationToken cancellationToken)
    {
        if (!HasPublicDownloadVersion(PublicDownloadStatisticApi))
        {
            return new(DownloadStationSectionStatus.Unavailable, null);
        }
        try
        {
            var data = await CallPublicDownloadAsync(
                PublicDownloadStatisticApi,
                "getinfo",
                parameters: null,
                cancellationToken).ConfigureAwait(false);
            var value = new DownloadActivitySummary(
                RequiredNonNegativeLong(data, "speed_download"),
                RequiredNonNegativeLong(data, "speed_upload"),
                RequiredNonNegativeLong(data, "emule_speed_download"),
                RequiredNonNegativeLong(data, "emule_speed_upload"));
            return new(DownloadStationSectionStatus.Available, value);
        }
        catch (DsmException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
        catch (JsonException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
        catch (IOException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
    }

    private async Task<DownloadStationSettingsSection> LoadPublicDownloadSettingsAsync(
        CancellationToken cancellationToken)
    {
        if (!HasPublicDownloadVersion(PublicDownloadInfoApi) && !HasPublicDownloadVersion(PublicDownloadInfoApi, 2))
        {
            return new(DownloadStationSectionStatus.Unavailable, null);
        }
        try
        {
            var snapshot = await ReadDownloadSettingsSnapshotAsync(cancellationToken).ConfigureAwait(false);
            return new(DownloadStationSectionStatus.Available, snapshot.Value);
        }
        catch (DsmException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
        catch (JsonException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
        catch (IOException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
    }

    private async Task<DownloadRssSection> LoadPublicDownloadRssAsync(
        CancellationToken cancellationToken)
    {
        if (!HasPublicDownloadVersion(PublicDownloadRssSiteApi) ||
            !HasPublicDownloadVersion(PublicDownloadRssFeedApi))
        {
            return new(DownloadStationSectionStatus.Unavailable, null);
        }
        try
        {
            var sites = await ListRssSitesAsync(cancellationToken).ConfigureAwait(false);
            var feedCount = 0;
            foreach (var site in sites)
                feedCount = checked(feedCount + (await ListRssFeedsAsync(site.Id, cancellationToken).ConfigureAwait(false)).Count);
            return new(
                DownloadStationSectionStatus.Available,
                new DownloadRssSummary(
                    sites.Count,
                    feedCount));
        }
        catch (DsmException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
        catch (JsonException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
        catch (IOException)
        {
            return new(DownloadStationSectionStatus.Failed, null);
        }
    }

    private void EnsureReadablePublicDownloadStationContract()
    {
        if (_profile.Id != _session.ProfileId)
        {
            throw new InvalidOperationException(
                "Download Station requests require a session for the active NAS profile.");
        }
        if (!HasReadablePublicDownloadStationContract)
        {
            throw MissingPublicDownloadStationContract();
        }
    }

    private bool HasPublicDownloadVersion(string apiName, int version = PublicDownloadApiVersion) =>
        _capabilities.TryGetValue(apiName, out var capability) &&
        capability.MinVersion <= version && capability.MaxVersion >= version;

    private bool HasControllablePublicDownloadStationContract =>
        _capabilities.TryGetValue(PublicDownloadTaskApi, out var capability) &&
        capability.MinVersion <= PublicDownloadApiVersion &&
        capability.MaxVersion >= PublicDownloadApiVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private Task<JsonObject> CallPublicDownloadAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken,
        int version = PublicDownloadApiVersion)
    {
        if (!_capabilities.TryGetValue(apiName, out var capability) ||
            capability.MinVersion > version || capability.MaxVersion < version)
        {
            throw MissingPublicDownloadStationContract();
        }
        return _api.CallAsync(
            _profile,
            _session,
            capability with
            {
                Path = capability.Path == "webapi/entry.cgi" ? "/webapi/entry.cgi" : capability.Path,
                MinVersion = version,
                MaxVersion = version,
            },
            method,
            parameters,
            cancellationToken);
    }

    private static DownloadTask ParsePublicDownloadTask(JsonObject item)
    {
        var id = StableDownloadId(item["id"]);
        if (id is null)
        {
            throw InvalidDownloadStationResponse();
        }
        var rawStatus = item.String("status")?.Trim();
        if (string.IsNullOrEmpty(rawStatus))
        {
            throw InvalidDownloadStationResponse();
        }
        var additional = item.Object("additional");
        var transfer = additional?.Object("transfer");
        var detail = additional?.Object("detail");
        var statusExtra = item.Object("status_extra");
        return new DownloadTask(
            id,
            DownloadRequiredString(item, "title"),
            rawStatus,
            ParsePublicDownloadTaskState(rawStatus),
            OptionalNonNegativeLong(item, "size"),
            OptionalNonNegativeLong(item, "size_downloaded")
                ?? OptionalNonNegativeLong(transfer, "size_downloaded"),
            OptionalNonNegativeLong(transfer, "size_uploaded"),
            OptionalNonNegativeLong(transfer, "speed_download"),
            OptionalNonNegativeLong(transfer, "speed_upload"),
            detail?.String("destination"),
            statusExtra?.String("error_detail"))
        {
            AdvancedDetails = new DownloadTaskAdvancedDetails(
                ParseDownloadTaskPriority(
                    item["priority"] ??
                    detail?["priority"] ??
                    FirstDownloadAdditionalObject(additional, "file", "files")?["priority"]),
                CountDownloadAdditionalObjects(additional, "file", "files"),
                CountDownloadAdditionalObjects(additional, "tracker", "trackers"),
                CountDownloadAdditionalObjects(additional, "peer", "peers"),
                OptionalNonNegativeInt(item, "seeds") ??
                    OptionalNonNegativeInt(item, "seeders") ??
                    OptionalNonNegativeInt(detail, "seeds") ??
                    OptionalNonNegativeInt(detail, "seeders"),
                OptionalNonNegativeInt(item, "peers") ??
                    OptionalNonNegativeInt(detail, "peers"),
                OptionalNonNegativeInt(item, "leeches") ??
                    OptionalNonNegativeInt(item, "leechs") ??
                    OptionalNonNegativeInt(detail, "leeches") ??
                    OptionalNonNegativeInt(detail, "leechs")),
        };
    }

    private static DownloadTaskState ParsePublicDownloadTaskState(string rawStatus) =>
        rawStatus.ToLowerInvariant() switch
        {
            "waiting" => DownloadTaskState.Waiting,
            "downloading" => DownloadTaskState.Downloading,
            "paused" => DownloadTaskState.Paused,
            "finished" => DownloadTaskState.Finished,
            "checking" or "hash_checking" or "filehosting_waiting" or "extracting" =>
                DownloadTaskState.Checking,
            "seeding" or "uploading" => DownloadTaskState.Seeding,
            "error" => DownloadTaskState.Error,
            _ => DownloadTaskState.Unknown,
        };

    private async Task<DownloadTask> LoadExactDownloadTaskAsync(
        string taskId,
        CancellationToken cancellationToken)
    {
        var allTasks = await LoadAllPublicDownloadTasksAsync(cancellationToken).ConfigureAwait(false);
        return allTasks.SingleOrDefault(task => string.Equals(task.Id, taskId, StringComparison.Ordinal))
            ?? throw InvalidDownloadStationResponse();
    }

    private async Task<IReadOnlyList<DownloadTask>> LoadAllPublicDownloadTasksAsync(
        CancellationToken cancellationToken)
    {
        var offset = 0;
        int? total = null;
        var first = true;
        var tasks = new List<DownloadTask>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        while (true)
        {
            var page = await ListTasksAsync(offset, MaximumTaskPageSize, cancellationToken)
                .ConfigureAwait(false);
            if (!first && page.SourceTotal != total)
            {
                throw InvalidDownloadStationResponse();
            }
            total = page.SourceTotal;
            first = false;
            foreach (var task in page.Tasks)
            {
                if (!seen.Add(task.Id))
                {
                    throw InvalidDownloadStationResponse();
                }
                tasks.Add(task);
            }
            if (!page.HasMore)
            {
                return tasks;
            }
            if (page.NextOffset is not int nextOffset || nextOffset <= offset)
            {
                throw InvalidDownloadStationResponse();
            }
            offset = nextOffset;
        }
    }

    private static bool TryPrepareDownloadCreateRequest(
        DownloadTaskCreateRequest request,
        out string normalizedUri,
        out string? normalizedDestination)
    {
        normalizedUri = request.Uri.Trim();
        normalizedDestination = string.IsNullOrEmpty(request.Destination) ? null : request.Destination;
        if (string.IsNullOrEmpty(normalizedUri) ||
            normalizedUri.Any(char.IsControl) ||
            !Uri.TryCreate(normalizedUri, UriKind.Absolute, out var uri))
        {
            return false;
        }

        var scheme = uri.Scheme.ToLowerInvariant();
        var validUri = scheme switch
        {
            "http" or "https" or "ftp" => !string.IsNullOrWhiteSpace(uri.Host),
            "magnet" => normalizedUri.Length > "magnet:".Length,
            _ => false,
        };
        if (!validUri)
        {
            return false;
        }
        if (normalizedDestination is not null &&
            (string.IsNullOrEmpty(normalizedDestination) ||
                normalizedDestination.Any(char.IsControl)))
        {
            return false;
        }
        return true;
    }

    private static bool DownloadControlAccepts(
        DownloadTaskControlAction action,
        DownloadTaskState state) =>
        action switch
        {
            DownloadTaskControlAction.Pause => state is DownloadTaskState.Waiting or
                DownloadTaskState.Downloading or DownloadTaskState.Checking or DownloadTaskState.Seeding,
            DownloadTaskControlAction.Resume => state == DownloadTaskState.Paused,
            _ => false,
        };

    private static MutationErrorCategory DownloadControlErrorCategory(DsmException error) =>
        DownloadStationErrors.IsKnownRejection(error.Code) ? DownloadStationErrors.Category(error.Code)
            : error.AuthenticationFailure ? MutationErrorCategory.Authentication : MutationErrorCategory.Server;

    private static string? StableDownloadId(JsonNode? node)
    {
        if (node is not JsonValue value)
        {
            return null;
        }
        if (value.TryGetValue<string>(out var text))
        {
            return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
        }
        if (value.TryGetValue<int>(out var nativeInteger))
        {
            return nativeInteger.ToString(CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<long>(out var integer))
        {
            return integer.ToString(CultureInfo.InvariantCulture);
        }
        return null;
    }

    private static int RequiredNonNegativeInt(JsonObject data, string key)
    {
        var value = RequiredNonNegativeLong(data, key);
        return value <= int.MaxValue ? (int)value : throw InvalidDownloadStationResponse();
    }

    private static long RequiredNonNegativeLong(JsonObject data, string key)
    {
        if (data[key] is not JsonValue value) throw InvalidDownloadStationResponse();
        if (value.TryGetValue<long>(out var number) && number >= 0) return number;
        if (value.TryGetValue<int>(out var integer) && integer >= 0) return integer;
        throw InvalidDownloadStationResponse();
    }

    private static long? OptionalNonNegativeLong(JsonObject? data, string key)
    {
        if (data?[key] is null)
        {
            return null;
        }
        // 下载大小、速度等可选字段也可能返回十进制数字字符串；未知值不补零。
        // 分页、RSS 编号和回执仍使用严格的必填数值读取，避免改变结果完整性判断。
        if (data[key] is JsonValue value && value.TryGetValue<string>(out var text) &&
            long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var number))
        {
            return number;
        }
        return RequiredNonNegativeLong(data, key);
    }

    private static int? OptionalNonNegativeInt(JsonObject? data, string key)
    {
        var value = OptionalNonNegativeLong(data, key);
        return value is null
            ? null
            : value <= int.MaxValue
                ? (int)value.Value
                : throw InvalidDownloadStationResponse();
    }

    private static bool? OptionalDownloadBool(JsonObject? data, string key)
    {
        if (data is null || !data.ContainsKey(key))
        {
            return null;
        }
        return data[key] is JsonValue value && value.TryGetValue<bool>(out var flag) ? flag : throw InvalidDownloadStationResponse();
    }

    private static DownloadTaskPriority? ParseDownloadTaskPriority(JsonNode? node)
    {
        if (node is null)
        {
            return null;
        }
        if (node is not JsonValue value)
        {
            throw InvalidDownloadStationResponse();
        }
        if (value.TryGetValue<int>(out var integer))
        {
            return integer switch
            {
                0 => DownloadTaskPriority.Low,
                1 => DownloadTaskPriority.Normal,
                2 => DownloadTaskPriority.High,
                _ => DownloadTaskPriority.Unknown,
            };
        }
        if (!value.TryGetValue<string>(out var text))
        {
            throw InvalidDownloadStationResponse();
        }
        var normalized = text.Trim();
        if (normalized.Length == 0)
        {
            return null;
        }
        if (normalized.Any(char.IsControl))
        {
            throw InvalidDownloadStationResponse();
        }
        return normalized.ToLowerInvariant() switch
        {
            "low" or "lower" or "0" => DownloadTaskPriority.Low,
            "normal" or "medium" or "default" or "1" => DownloadTaskPriority.Normal,
            "high" or "higher" or "2" => DownloadTaskPriority.High,
            _ => DownloadTaskPriority.Unknown,
        };
    }

    private static int? CountDownloadAdditionalObjects(JsonObject? additional, params string[] keys)
    {
        if (additional is null)
        {
            return null;
        }
        foreach (var key in keys)
        {
            if (!additional.TryGetPropertyValue(key, out var node) || node is null)
            {
                continue;
            }
            return CountDownloadArrayNode(node);
        }
        return null;
    }

    private static JsonObject? FirstDownloadAdditionalObject(JsonObject? additional, params string[] keys)
    {
        if (additional is null)
        {
            return null;
        }
        foreach (var key in keys)
        {
            if (!additional.TryGetPropertyValue(key, out var node) || node is null)
            {
                continue;
            }
            var array = DownloadArrayNode(node);
            if (array.Count == 0)
            {
                return null;
            }
            return array[0] as JsonObject ?? throw InvalidDownloadStationResponse();
        }
        return null;
    }

    private static int CountDownloadArrayNode(JsonNode node) =>
        DownloadArrayNode(node).Count;

    private static JsonArray DownloadArrayNode(JsonNode node)
    {
        if (node is JsonArray direct)
        {
            return direct;
        }
        if (node is JsonObject wrapper)
        {
            foreach (var key in new[] { "items", "list", "files", "trackers", "peers", "feeds", "sites" })
            {
                if (wrapper.TryGetPropertyValue(key, out var nested) && nested is JsonArray array)
                {
                    return array;
                }
            }
        }
        throw InvalidDownloadStationResponse();
    }

    private static DsmException MissingPublicDownloadStationContract() =>
        new(
            UserText.Key("WinShared11a208e43c34b77c"),
            UserText.Key("WinShared371d84f48836296f"),
            102);

    private static DsmException InvalidDownloadStationResponse() =>
        new(
            UserText.Key("WinShared17bab1054ab28010"),
            UserText.Key("WinSharedefc81ced18eb3bb0"));

    private static string DownloadCreateDigest(string kind, params string[] values)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true);
        writer.Write(kind);
        foreach (var value in values)
        {
            writer.Write(value.Length);
            writer.Write(value);
        }
        writer.Flush();
        return Convert.ToHexString(SHA256.HashData(stream.ToArray())).ToLowerInvariant();
    }

}
