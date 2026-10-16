using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<DownloadTaskDetails> LoadTaskDetailsAsync(string taskId, CancellationToken cancellationToken = default)
    {
        EnsureReadablePublicDownloadStationContract();
        if (StableDownloadId(JsonValue.Create(taskId)) != taskId) throw InvalidDownloadStationResponse();
        var data = await CallPublicDownloadAsync(PublicDownloadTaskApi, "getinfo", new Dictionary<string, string>
        { ["id"] = taskId, ["additional"] = "detail,transfer,file,tracker,peer" }, cancellationToken).ConfigureAwait(false);
        if (data["tasks"] is not JsonArray { Count: 1 } rows || rows[0] is not JsonObject item)
            throw InvalidDownloadStationResponse();
        var task = ParsePublicDownloadTask(item);
        if (task.Id != taskId) throw InvalidDownloadStationResponse();
        var additional = item.Object("additional");
        var files = DownloadDetailRows(additional, "file")?.Select(row => new DownloadTaskFile(
            DownloadRequiredString(row, "filename", allowEmpty: false), OptionalNonNegativeLong(row, "size"),
            OptionalNonNegativeLong(row, "size_downloaded"), row.String("priority"))).ToArray();
        var trackers = DownloadDetailRows(additional, "tracker")?.Select(row =>
        {
            if (!Uri.TryCreate(DownloadRequiredString(row, "url", false), UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host))
                throw InvalidDownloadStationResponse();
            // 不保留 userinfo、路径、查询或 fragment，避免默认界面泄露 passkey。
            var origin = uri.GetComponents(UriComponents.SchemeAndServer, UriFormat.UriEscaped);
            return new DownloadTaskTracker(origin, row.String("status"), OptionalNonNegativeInt(row, "seeds"),
                OptionalNonNegativeInt(row, "peers"), OptionalNonNegativeInt(row, "update_timer"));
        }).ToArray();
        var peers = DownloadDetailRows(additional, "peer")?.Select(row =>
        {
            double? progress = row["progress"] is JsonValue value && value.TryGetValue<double>(out var number) &&
                double.IsFinite(number) && number is >= 0 and <= 1 ? number : null;
            return new DownloadTaskPeer(DownloadRequiredString(row, "address", false), row.String("agent"), progress,
                OptionalNonNegativeLong(row, "speed_download"), OptionalNonNegativeLong(row, "speed_upload"));
        }).ToArray();
        return new(task, item.String("type"), item.String("username"),
            OptionalNonNegativeLong(additional?.Object("detail"), "create_time"), files, trackers, peers);
    }

    private static IReadOnlyList<JsonObject>? DownloadDetailRows(JsonObject? additional, string key)
    {
        if (additional?[key] is null) return null;
        if (additional[key] is not JsonArray rows) throw InvalidDownloadStationResponse();
        return rows.Select(row => row as JsonObject ?? throw InvalidDownloadStationResponse()).ToArray();
    }

    private static string DownloadRequiredString(JsonObject row, string key, bool allowEmpty = true) =>
        row[key] is JsonValue value && value.TryGetValue<string>(out var text) && (allowEmpty || text.Length > 0)
            ? text : throw InvalidDownloadStationResponse();

    public async Task<IReadOnlyList<DownloadRssSite>> ListRssSitesAsync(CancellationToken cancellationToken = default)
    {
        var rows = await LoadDownloadRssRowsAsync(PublicDownloadRssSiteApi, ["sites", "site"], null, cancellationToken).ConfigureAwait(false);
        var seen = new HashSet<int>();
        return rows.Select(row =>
        {
            var id = RequiredNonNegativeInt(row, "id");
            if (!seen.Add(id) || row["is_updating"] is not JsonValue value || !value.TryGetValue<bool>(out var updating))
                throw InvalidDownloadStationResponse();
            return new DownloadRssSite(id, DownloadCreateDigest("rss", id.ToString(CultureInfo.InvariantCulture),
                DownloadRequiredString(row, "url"), DownloadRequiredString(row, "username")),
                DownloadRequiredString(row, "title"), updating, RequiredNonNegativeLong(row, "last_update"));
        }).ToArray();
    }

    public async Task<IReadOnlyList<DownloadRssFeed>> ListRssFeedsAsync(int siteId, CancellationToken cancellationToken = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(siteId);
        var rows = await LoadDownloadRssRowsAsync(PublicDownloadRssFeedApi, ["feeds"], siteId, cancellationToken).ConfigureAwait(false);
        var feeds = new List<DownloadRssFeed>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            var title = DownloadRequiredString(row, "title");
            var uri = DownloadRequiredString(row, "download_uri");
            var link = DownloadRequiredString(row, "external_link");
            var rawSize = DownloadRequiredString(row, "size", false);
            if (rawSize.Any(value => value is < '0' or > '9') ||
                !long.TryParse(rawSize, NumberStyles.None, CultureInfo.InvariantCulture, out var size)) throw InvalidDownloadStationResponse();
            var time = RequiredNonNegativeLong(row, "time");
            var id = DownloadCreateDigest("feed", title, uri, link, rawSize, time.ToString(CultureInfo.InvariantCulture));
            if (seen.Add(id)) feeds.Add(new(id, title, size, time, uri));
        }
        return feeds;
    }

    private async Task<IReadOnlyList<JsonObject>> LoadDownloadRssRowsAsync(string api, string[] keys, int? siteId,
        CancellationToken cancellationToken)
    {
        EnsureReadablePublicDownloadStationContract();
        const int limit = 500;
        var offset = 0;
        int? expectedTotal = null;
        var result = new List<JsonObject>();
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var parameters = new Dictionary<string, string>
            { ["offset"] = offset.ToString(CultureInfo.InvariantCulture), ["limit"] = limit.ToString(CultureInfo.InvariantCulture) };
            if (siteId is int id) parameters["id"] = id.ToString(CultureInfo.InvariantCulture);
            var data = await CallPublicDownloadAsync(api, "list", parameters, cancellationToken).ConfigureAwait(false);
            var total = RequiredNonNegativeInt(data, "total");
            var containers = keys.Where(data.ContainsKey).ToArray();
            if (RequiredNonNegativeInt(data, "offset") != offset || (expectedTotal is int previous && total != previous) ||
                containers.Length != 1 || data[containers[0]] is not JsonArray page ||
                page.Count > limit || offset > total || page.Count > total - offset) throw InvalidDownloadStationResponse();
            foreach (var row in page) result.Add(row as JsonObject ?? throw InvalidDownloadStationResponse());
            expectedTotal = total;
            offset += page.Count;
            if (offset == total) return result;
            if (page.Count == 0) throw InvalidDownloadStationResponse();
        }
    }

}
