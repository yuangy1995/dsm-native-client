using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

internal static class DsmFixtureParser
{
    private const int SharedRootPageLimit = 500;

    /// <summary>
    /// 将 File Station 列表数据转换为稳定领域语义，供生产请求和脱敏 Fixture 共用。
    /// </summary>
    public static FilePage ParseFilePage(
        JsonObject data,
        string root = "files",
        int expectedOffset = 0,
        int requestedLimit = SharedRootPageLimit)
    {
        var sourceItems = data.Array(root).OfType<JsonObject>().ToArray();
        var items = sourceItems.Select(item =>
        {
            var additional = item.Object("additional");
            var time = additional?.Object("time");
            var permission = additional?.Object("perm");
            return new FileItem(
                item.String("path") ?? string.Empty,
                item.String("name") ?? item.String("path")?.Split('/').Last() ?? UserText.Key("WinShared79f326be4409d51f"),
                item.Bool("isdir") ?? false,
                item.Bool("isdir") == true
                    ? 0
                    : item.Long("size") ?? additional?.Long("size") ?? -1,
                time?.Date("mtime") ?? item.Date("mtime"),
                additional?.Object("owner")?.String("user") ?? additional?.String("owner"),
                permission?.Bool("write") ?? false,
                permission?.Bool("delete") ?? false);
        }).Where(item => !string.IsNullOrWhiteSpace(item.Path)).ToArray();
        return new FilePage(
            items,
            data.Int("total") ?? items.Length,
            data.Int("offset") ?? 0,
            root == "shares"
                ? ParseStorageSpace(data, sourceItems, expectedOffset, requestedLimit)
                : null);
    }

    private static StorageSpaceSummary? ParseStorageSpace(
        JsonObject data,
        IReadOnlyList<JsonObject> shares,
        int expectedOffset,
        int requestedLimit)
    {
        var offset = data.Int("offset");
        var total = data.Int("total");
        if (expectedOffset != 0 || requestedLimit < 1 ||
            (data.ContainsKey("offset") && offset is null) ||
            (data.ContainsKey("total") && total is null) ||
            offset is < 0 || total is < 0 ||
            (offset is not null && offset != expectedOffset) ||
            (total is not null && total != shares.Count) ||
            (total is null && shares.Count >= requestedLimit))
        {
            return null;
        }

        var volumes = new Dictionary<string, (long Total, long Remaining)>(
            StringComparer.OrdinalIgnoreCase);
        foreach (var share in shares)
        {
            var additional = share.Object("additional");
            var realPath = additional?.String("real_path");
            if (string.IsNullOrWhiteSpace(realPath))
            {
                return null;
            }
            var volume = VolumeIdentity(realPath);
            if (volume is null)
            {
                continue;
            }
            var volumeStatus = additional?.Object("volume_status");
            var capacity = FirstLong(volumeStatus, "totalspace", "total_space", "total");
            var remaining = FirstLong(volumeStatus, "freespace", "free_space", "available");
            if (capacity is not > 0 || remaining is null or < 0)
            {
                return null;
            }
            var normalized = (Total: capacity.Value, Remaining: Math.Min(remaining.Value, capacity.Value));
            if (volumes.TryGetValue(volume, out var existing) && existing != normalized)
            {
                return null;
            }
            volumes[volume] = normalized;
        }
        if (volumes.Count == 0)
        {
            return null;
        }

        try
        {
            long totalBytes = 0;
            long remainingBytes = 0;
            foreach (var volume in volumes.Values)
            {
                totalBytes = checked(totalBytes + volume.Total);
                remainingBytes = checked(remainingBytes + volume.Remaining);
            }
            return new StorageSpaceSummary(totalBytes, remainingBytes, volumes.Count);
        }
        catch (OverflowException)
        {
            return null;
        }
    }

    private static long? FirstLong(JsonObject? value, params string[] keys)
    {
        if (value is null)
        {
            return null;
        }
        foreach (var key in keys)
        {
            if (value.Long(key) is { } result)
            {
                return result;
            }
        }
        return null;
    }

    private static string? VolumeIdentity(string? realPath)
    {
        var volume = realPath?.Split('/', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        return volume?.StartsWith("volume", StringComparison.OrdinalIgnoreCase) == true
            ? volume
            : null;
    }
}

public sealed partial class DsmRepository
{
    private FilePage ParseFilePage(
        JsonObject data,
        string root,
        int expectedOffset = 0,
        int requestedLimit = 500) =>
        DsmFixtureParser.ParseFilePage(data, root, expectedOffset, requestedLimit);
}
