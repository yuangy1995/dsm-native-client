using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Download Station 官方公开只读接口适配器。内部 DownloadStation2 API 不属于本契约。
/// </summary>
public sealed partial class DsmRepository
{
    private const string PublicDownloadTaskApi = "SYNO.DownloadStation.Task";
    private const string PublicDownloadStatisticApi = "SYNO.DownloadStation.Statistic";
    private const int PublicDownloadApiVersion = 1;
    private const int MaximumTaskPageSize = 100;

    private static readonly IReadOnlySet<DownloadStationReadFeature> PublicDownloadTaskFeatures =
        new HashSet<DownloadStationReadFeature>
        {
            DownloadStationReadFeature.Tasks,
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
            return new(DownloadStationAvailabilityStatus.Available, features);
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
                ["additional"] = "detail,transfer",
            },
            cancellationToken).ConfigureAwait(false);

        var sourceOffset = RequiredNonNegativeInt(data, "offset");
        var sourceTotal = RequiredNonNegativeInt(data, "total");
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
        var hasMore = nextOffset < sourceTotal;
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
        return new(
            _profile.Id,
            tasks,
            activity,
            new(DownloadStationSectionStatus.Unavailable, null));
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

    private bool HasPublicDownloadVersion(string apiName) =>
        _capabilities.TryGetValue(apiName, out var capability) &&
        capability.MinVersion <= PublicDownloadApiVersion &&
        capability.MaxVersion >= PublicDownloadApiVersion;

    private Task<JsonObject> CallPublicDownloadAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken)
    {
        if (!_capabilities.TryGetValue(apiName, out var capability) ||
            capability.MinVersion > PublicDownloadApiVersion ||
            capability.MaxVersion < PublicDownloadApiVersion)
        {
            throw MissingPublicDownloadStationContract();
        }
        return _api.CallAsync(
            _profile,
            _session,
            capability with
            {
                MinVersion = PublicDownloadApiVersion,
                MaxVersion = PublicDownloadApiVersion,
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
        var transfer = item.Object("additional")?.Object("transfer");
        var detail = item.Object("additional")?.Object("detail");
        var statusExtra = item.Object("status_extra");
        return new DownloadTask(
            id,
            item.String("title")?.Trim() is { Length: > 0 } title ? title : id,
            rawStatus,
            ParsePublicDownloadTaskState(rawStatus),
            OptionalNonNegativeLong(item, "size"),
            OptionalNonNegativeLong(item, "size_downloaded")
                ?? OptionalNonNegativeLong(transfer, "size_downloaded"),
            OptionalNonNegativeLong(transfer, "size_uploaded"),
            OptionalNonNegativeLong(transfer, "speed_download"),
            OptionalNonNegativeLong(transfer, "speed_upload"),
            detail?.String("destination"),
            statusExtra?.String("error_detail"));
    }

    private static DownloadTaskState ParsePublicDownloadTaskState(string rawStatus) =>
        rawStatus.ToLowerInvariant() switch
        {
            "waiting" => DownloadTaskState.Waiting,
            "downloading" => DownloadTaskState.Downloading,
            "paused" => DownloadTaskState.Paused,
            "finished" => DownloadTaskState.Finished,
            "hash_checking" or "filehosting_waiting" or "extracting" =>
                DownloadTaskState.Checking,
            "seeding" => DownloadTaskState.Seeding,
            "error" => DownloadTaskState.Error,
            _ => DownloadTaskState.Unknown,
        };

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
        var value = data.Int(key);
        return value is >= 0 ? value.Value : throw InvalidDownloadStationResponse();
    }

    private static long RequiredNonNegativeLong(JsonObject data, string key)
    {
        var value = data.Long(key);
        return value is >= 0 ? value.Value : throw InvalidDownloadStationResponse();
    }

    private static long? OptionalNonNegativeLong(JsonObject? data, string key)
    {
        if (data is null || !data.ContainsKey(key))
        {
            return null;
        }
        var value = data.Long(key);
        return value is >= 0 ? value : throw InvalidDownloadStationResponse();
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
}
