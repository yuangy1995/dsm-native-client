using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<IReadOnlyList<NasDiskTestTarget>> LoadDiskTestTargetsAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var data = await DiskReadAsync("SYNO.Storage.CGI.Storage", "load_info", null, cancellationToken).ConfigureAwait(false);
        if (data["disks"] is not JsonArray disks) throw InvalidNasServiceSettings();
        var ids = new HashSet<string>(StringComparer.Ordinal); var devices = new HashSet<string>(StringComparer.Ordinal);
        var targets = new List<NasDiskTestTarget>();
        foreach (var node in disks)
        {
            if (node is not JsonObject disk) throw InvalidNasServiceSettings();
            var id = DirectoryText(disk["id"]); var device = DirectoryText(disk["device"]);
            if (!ValidDiskIdentifier(id) || !ValidDiskIdentifier(device) || !ids.Add(id!) || !devices.Add(device!)) throw InvalidNasServiceSettings();
            targets.Add(new(id!, device!, DirectoryText(disk["longName"]) ?? DirectoryText(disk["name"]), DirectoryBoolean(disk["smart_test_support"])));
        }
        return targets.AsReadOnly();
    }
    public async Task<NasDiskTestState> LoadDiskTestStateAsync(NasDiskTestTarget target, CancellationToken cancellationToken = default)
    {
        await ValidateDiskTargetAsync(target, cancellationToken).ConfigureAwait(false);
        var data = await DiskReadAsync("SYNO.Core.Storage.Disk", "get_smart_test_log",
            new() { ["device"] = target.DeviceId }, cancellationToken).ConfigureAwait(false);
        if (data["testInfo"] is not JsonArray { Count: 1 } rows || rows[0] is not JsonObject state) throw InvalidNasServiceSettings();
        var reportedDevice = DirectoryText(state["device"]);
        if (reportedDevice is not null && reportedDevice != target.DeviceId) throw InvalidNasServiceSettings();
        var running = DiskAlias(state, DirectoryBoolean, "testing", "is_testing") ?? throw InvalidNasServiceSettings();
        var type = DiskAlias(state, ParseDiskTestType, "test_type", "testType", "type");
        if (running && type is null) throw InvalidNasServiceSettings();
        var ihm = DirectoryBoolean(state["ihm_testing"]); var performance = DirectoryBoolean(state["perf_testing"]);
        bool? busy = running ? false : ihm == true || performance == true ? true : ihm == false && performance == false ? false : null;
        return new(target, running, running ? type : null, busy,
            DiskAlias(state, DirectoryText, "remain", "progress"), DiskAlias(state, DirectoryText, "latest_test_result", "result"));
    }
    public async Task<NasDiskTestHistory> LoadDiskTestHistoryAsync(NasDiskTestTarget target, CancellationToken cancellationToken = default)
    {
        await ValidateDiskTargetAsync(target, cancellationToken).ConfigureAwait(false);
        var data = await DiskReadAsync("SYNO.Core.Storage.Disk", "disk_test_log_get", new()
        { ["device"] = target.DeviceId, ["offset"] = 0, ["limit"] = 100, ["sort_by"] = "time", ["sort_direction"] = "DESC", ["type"] = "smart" }, cancellationToken).ConfigureAwait(false);
        if (data["testLog"] is not JsonArray logs || logs.Count > 100) throw InvalidNasServiceSettings();
        int? total = data["total"] is null ? null : data["total"] is JsonValue scalar && scalar.TryGetValue<int>(out var count) && count >= logs.Count
            ? count : throw InvalidNasServiceSettings();
        var history = new List<NasDiskTestHistoryEntry>();
        foreach (var node in logs)
        {
            if (node is not JsonObject log) throw InvalidNasServiceSettings();
            var family = DirectoryText(log["type"]);
            if (family is not null && family != "smart" && log["test_type"] is null) continue;
            var type = ParseDiskTestType(log["test_type"]) ?? throw InvalidNasServiceSettings();
            history.Add(new(type, DirectoryText(log["time"]), DirectoryText(log["result"])));
        }
        return new(history.AsReadOnly(), total > logs.Count || total is null && logs.Count == 100);
    }
    private async Task ValidateDiskTargetAsync(NasDiskTestTarget target, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (target is null || !ValidDiskIdentifier(target.Id) || !ValidDiskIdentifier(target.DeviceId) || target.SupportsSmartTest != true) throw InvalidNasServiceSettings();
        var disks = await LoadDiskTestTargetsAsync(token).ConfigureAwait(false);
        if (!disks.Any(disk => disk.Id == target.Id && disk.DeviceId == target.DeviceId && disk.SupportsSmartTest == true)) throw InvalidNasServiceSettings();
    }
    private async Task<JsonObject> DiskReadAsync(string api, string method, Dictionary<string, object>? values, CancellationToken token)
    {
        var capability = SecurityCapability(api, 1) ?? throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        var parameters = values?.ToDictionary(pair => pair.Key, pair => capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)
            ? JsonSerializer.Serialize(pair.Value) : Convert.ToString(pair.Value, System.Globalization.CultureInfo.InvariantCulture)!, StringComparer.Ordinal);
        return await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, method, parameters, token).ConfigureAwait(false);
    }
    private static bool ValidDiskIdentifier(string? value) => !string.IsNullOrWhiteSpace(value) && !value.Any(char.IsControl);
    private static NasDiskTestType? ParseDiskTestType(JsonNode? node) => DirectoryText(node)?.ToLowerInvariant() switch
    { null or "" => null, "quick" => NasDiskTestType.Quick, "extend" or "extended" => NasDiskTestType.Extended, _ => throw InvalidNasServiceSettings() };
    private static T DiskAlias<T>(JsonObject value, Func<JsonNode?, T> parse, params string[] keys)
    {
        var present = keys.Where(key => value[key] is not null).Select(key => parse(value[key])).ToArray();
        if (present.Length == 0) return parse(null);
        if (present.Skip(1).Any(item => !EqualityComparer<T>.Default.Equals(present[0], item))) throw InvalidNasServiceSettings();
        return present[0];
    }
}
