using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string FileBackgroundTaskApi = "SYNO.FileStation.BackgroundTask";
    private const int FileBackgroundTaskApiVersion = 3;
    private const int FileBackgroundTaskMaximumPageSize = 100;
    private const string FileBackgroundTaskFilter =
        "[\"SYNO.FileStation.CopyMove\",\"SYNO.FileStation.Delete\",\"SYNO.FileStation.Extract\",\"SYNO.FileStation.Compress\"]";

    bool IFileBackgroundTaskRepository.IsAvailable => IsFileBackgroundTaskAvailable;

    Task<FileBackgroundTaskPage> IFileBackgroundTaskRepository.ListTasksAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken) =>
        ListFileBackgroundTasksAsync(offset, limit, cancellationToken);

    private bool IsFileBackgroundTaskAvailable =>
        _capabilities.TryGetValue(FileBackgroundTaskApi, out var capability) &&
        string.Equals(capability.Name, FileBackgroundTaskApi, StringComparison.Ordinal) &&
        capability.MinVersion <= FileBackgroundTaskApiVersion &&
        capability.MaxVersion >= FileBackgroundTaskApiVersion &&
        HasFixedCapability(FileBackgroundTaskApi, FileBackgroundTaskApiVersion) &&
        _profile.Id == _session.ProfileId && !string.IsNullOrWhiteSpace(_session.Sid);

    private async Task<FileBackgroundTaskPage> ListFileBackgroundTasksAsync(
        int offset,
        int limit,
        CancellationToken cancellationToken, bool strict = false)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!IsFileBackgroundTaskAvailable ||
            !_capabilities.TryGetValue(FileBackgroundTaskApi, out var capability))
        {
            throw new NotSupportedException("The File Station background-task list is unavailable.");
        }

        var requestedOffset = Math.Max(0, offset);
        var requestedLimit = Math.Clamp(limit, 1, FileBackgroundTaskMaximumPageSize);
        var data = await _api.CallReadJsonObjectAsync(
            _profile,
            _session,
            capability,
            FileBackgroundTaskApiVersion,
            "list",
            new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["offset"] = requestedOffset.ToString(CultureInfo.InvariantCulture),
                ["limit"] = requestedLimit.ToString(CultureInfo.InvariantCulture),
                ["sort_by"] = ShareParameterString(FileBackgroundTaskApi, "crtime"),
                ["sort_direction"] = ShareParameterString(FileBackgroundTaskApi, "desc"),
                ["api_filter"] = FileBackgroundTaskFilter,
            },
            cancellationToken).ConfigureAwait(false);

        var taskArray = data["tasks"] as JsonArray;
        if (strict && (taskArray is null || taskArray.Count > requestedLimit ||
            FileBackgroundTaskOptionalNonNegativeLong(data, "offset") != requestedOffset ||
            FileBackgroundTaskOptionalNonNegativeLong(data, "total") is not { } count || count > int.MaxValue ||
            count < (long)requestedOffset + taskArray.Count || taskArray.Count == 0 && count != requestedOffset))
            throw new InvalidDataException("file.tasks.pagination");
        var sourceTaskCount = taskArray?.Count ?? 0;
        var rawTasks = taskArray?.Take(requestedLimit).ToArray() ?? [];
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var tasks = new List<FileBackgroundTaskSummary>(rawTasks.Length);
        foreach (var node in rawTasks)
        {
            if (node is JsonObject item &&
                ParseFileBackgroundTask(item) is { } task &&
                (!strict || item["taskid"] is JsonValue id && id.TryGetValue<string>(out var rawId) && rawId == task.Id) &&
                seen.Add(task.Id))
            {
                tasks.Add(task);
            }
            else if (strict) throw new InvalidDataException("file.tasks.identity");
        }

        var resolvedOffset = BoundedPageValue(data, "offset", requestedOffset);
        var nextOffset = SaturatingAdd(resolvedOffset, rawTasks.Length);
        var reportedTotal = BoundedPageValue(data, "total", nextOffset);
        var total = Math.Max(nextOffset, reportedTotal);
        return new FileBackgroundTaskPage(
            tasks,
            resolvedOffset,
            nextOffset,
            total,
            nextOffset < int.MaxValue &&
                (sourceTaskCount > requestedLimit || rawTasks.Length > 0 && nextOffset < total));
    }

    private static FileBackgroundTaskSummary? ParseFileBackgroundTask(JsonObject item)
    {
        var id = NormalizeFileBackgroundTaskId(item.String("taskid"));
        var kind = ParseFileBackgroundTaskKind(item.String("api"));
        var finished = FileBackgroundTaskStrictBoolean(item, "finished");
        if (id is null || kind is null || finished is null)
        {
            return null;
        }

        var total = FileBackgroundTaskOptionalNonNegativeLong(item, "total");
        var totalItemCount = kind == FileBackgroundTaskKind.Delete
            ? ToNonNegativeInt(total)
            : null;
        var totalBytes = kind == FileBackgroundTaskKind.CopyOrMove ? total : null;
        return new FileBackgroundTaskSummary(
            id,
            kind.Value,
            finished.Value ? FileBackgroundTaskState.Finished : FileBackgroundTaskState.Active,
            OptionalProgress(item, "progress"),
            OptionalCreationTime(item, "crtime"),
            ToNonNegativeInt(FileBackgroundTaskOptionalNonNegativeLong(item, "processed_num")),
            totalItemCount,
            FileBackgroundTaskOptionalNonNegativeLong(item, "processed_size"),
            totalBytes)
        {
            CreationTimestamp = FileTaskTimestamp(item),
            ApiVersion = FileBackgroundTaskOptionalNonNegativeLong(item, "version") is { } version && version is > 0 and <= int.MaxValue ? (int)version : null,
            Method = item["method"] is JsonValue method && method.TryGetValue<string>(out var name) && name == "start" ? name : null,
        };
    }

    private static string? NormalizeFileBackgroundTaskId(string? value)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed.Length > 256)
        {
            return null;
        }
        return trimmed.All(character =>
            character is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or
                '.' or '_' or '-' or ':')
            ? trimmed
            : null;
    }

    private static FileBackgroundTaskKind? ParseFileBackgroundTaskKind(string? api) => api switch
    {
        "SYNO.FileStation.CopyMove" => FileBackgroundTaskKind.CopyOrMove,
        "SYNO.FileStation.Delete" => FileBackgroundTaskKind.Delete,
        "SYNO.FileStation.Extract" => FileBackgroundTaskKind.Extract,
        "SYNO.FileStation.Compress" => FileBackgroundTaskKind.Compress,
        _ => null,
    };

    private static bool? FileBackgroundTaskStrictBoolean(JsonObject item, string key)
    {
        if (item[key] is not JsonValue value)
        {
            return null;
        }
        if (value.TryGetValue<bool>(out var boolean))
        {
            return boolean;
        }
        if (value.TryGetValue<int>(out var integer))
        {
            return integer switch { 0 => false, 1 => true, _ => null };
        }
        if (!value.TryGetValue<string>(out var text))
        {
            return null;
        }
        return text.Trim().ToLowerInvariant() switch
        {
            "0" or "false" => false,
            "1" or "true" => true,
            _ => null,
        };
    }

    private static long? FileBackgroundTaskOptionalNonNegativeLong(JsonObject item, string key)
    {
        if (item[key] is not JsonValue value)
        {
            return null;
        }
        long? number = value.TryGetValue<long>(out var parsed)
            ? parsed
            : long.TryParse(
                value.ToString().Trim('"'),
                NumberStyles.Integer,
                CultureInfo.InvariantCulture,
                out parsed)
                ? parsed
                : null;
        return number >= 0 ? number : null;
    }

    private static double? OptionalProgress(JsonObject item, string key)
    {
        if (item[key] is not JsonValue value)
        {
            return null;
        }
        if (!double.TryParse(
                value.ToString().Trim('"'),
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out var number))
        {
            return null;
        }
        return double.IsFinite(number) && number > 0 && number <= 1 ? number : null;
    }

    private static DateTimeOffset? OptionalCreationTime(JsonObject item, string key)
    {
        if (FileTaskTimestamp(item) is not { } epoch)
        {
            return null;
        }
        try
        {
            return DateTimeOffset.UnixEpoch.AddTicks((long)(epoch * TimeSpan.TicksPerSecond));
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    private static decimal? FileTaskTimestamp(JsonObject item) => item["crtime"] is JsonValue value &&
        decimal.TryParse(value.TryGetValue<string>(out var text) ? text : value.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var epoch) &&
        epoch >= 946_684_800 && epoch <= DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 86_400 ? epoch : null;

    private static int? ToNonNegativeInt(long? value) =>
        value is >= 0 and <= int.MaxValue ? (int)value.Value : null;

    private static int BoundedPageValue(JsonObject data, string key, int fallback)
    {
        var value = FileBackgroundTaskOptionalNonNegativeLong(data, key);
        return value is >= 0 and <= int.MaxValue ? (int)value.Value : fallback;
    }

    private static int SaturatingAdd(int left, int right) =>
        left > int.MaxValue - right ? int.MaxValue : left + right;
}
