using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string SystemLogApi = "SYNO.Core.SyslogClient.Log";
    public bool CanReadLogs => SecurityCapability(SystemLogApi, 1) is not null;

    public async Task<NasLogPage> LoadLogPageAsync(int offset, int limit, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        ArgumentOutOfRangeException.ThrowIfNegative(offset);
        if (limit is < 1 or > 500) throw new ArgumentOutOfRangeException(nameof(limit));
        var capability = SecurityCapability(SystemLogApi, 1) ?? throw new NotSupportedException();
        // 内部只读接口：只发送已记录的分页参数，不附加管理员身份探测。
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "list",
            new Dictionary<string, string> { ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                ["limit"] = limit.ToString(CultureInfo.InvariantCulture) }, cancellationToken).ConfigureAwait(false);
        if (data["items"] is not JsonArray rows || rows.Count > limit || rows.Any(row => row is not JsonObject)) throw InvalidLogs();
        var entries = rows.Cast<JsonObject>().Select(row =>
        {
            var message = LogText(row, "descr") ?? LogText(row, "message") ?? LogText(row, "msg");
            if (message is null) throw InvalidLogs();
            var rawTime = LogText(row, "time");
            DateTimeOffset? time = DateTimeOffset.TryParse(rawTime, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out var parsed) ? parsed : null;
            if (long.TryParse(rawTime, NumberStyles.Integer, CultureInfo.InvariantCulture, out var seconds) && seconds is >= -62135596800 and <= 253402300799)
                time = DateTimeOffset.FromUnixTimeSeconds(seconds);
            return new NasLogEntry(time, LogText(row, "logtype") ?? LogText(row, "orginalLogType"),
                LogText(row, "level"), LogText(row, "who"), message);
        }).ToArray();
        var total = LogCount(data, "total");
        if (data["total"] is not null && total is null) throw InvalidLogs();
        return new(ProfileId, offset, limit, Array.AsReadOnly(entries), total,
            LogCount(data, "infoCount"), LogCount(data, "warnCount"), LogCount(data, "errorCount"));
    }

    private static string? LogText(JsonObject row, string key) => row[key] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
    private static long? LogCount(JsonObject data, string key) => data[key] is JsonValue value &&
        value.TryGetValue<decimal>(out var number) && number >= 0 && number <= long.MaxValue && number == decimal.Truncate(number) ? (long)number : null;
    private static InvalidDataException InvalidLogs() => new("nas-logs.invalid-response");
}
