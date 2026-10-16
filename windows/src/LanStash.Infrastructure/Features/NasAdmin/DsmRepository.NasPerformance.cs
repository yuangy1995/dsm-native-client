using System.Collections.ObjectModel;
using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string PerformanceApi = "SYNO.Core.System.Utilization";
    public bool CanReadPerformance => SecurityCapability(PerformanceApi, 1)?.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) == true;

    public async Task<NasPerformanceSnapshot> LoadPerformanceAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!CanReadPerformance) throw new NotSupportedException();
        var capability = SecurityCapability(PerformanceApi, 1) ?? throw new NotSupportedException();
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "get",
            new Dictionary<string, string> { ["resource"] = "all", ["type"] = "current" }, cancellationToken).ConfigureAwait(false);
        var cpu = Object(data, "cpu"); var memory = Object(data, "memory");
        var disk = Object(Object(data, "disk"), "total"); var volume = Object(Object(data, "space"), "total");
        var networks = Rows(data, "network");
        var totals = networks?.Where(row => row.String("device")?.Equals("total", StringComparison.OrdinalIgnoreCase) == true).ToArray();
        if (totals?.Length > 1) throw InvalidPerformance();
        var network = totals?.FirstOrDefault();
        var nfs = Rows(data, "nfs");
        double? Percent(JsonObject? value, string key) => Number(value, key) is { } number ? Math.Min(100, number) : null;
        var user = Percent(cpu, "user_load"); var system = Percent(cpu, "system_load"); var other = Percent(cpu, "other_load");
        var values = new Dictionary<NasPerformanceMetric, double?>
        {
            [NasPerformanceMetric.Cpu] = user is not null && system is not null && other is not null ? Math.Min(100, user.Value + system.Value + other.Value) : null,
            [NasPerformanceMetric.CpuUser] = user, [NasPerformanceMetric.CpuSystem] = system, [NasPerformanceMetric.CpuOther] = other,
            [NasPerformanceMetric.Memory] = Percent(memory, "real_usage"), [NasPerformanceMetric.Swap] = Percent(memory, "swap_usage"),
            [NasPerformanceMetric.NetworkReceived] = Number(network, "rx"), [NasPerformanceMetric.NetworkSent] = Number(network, "tx"),
            [NasPerformanceMetric.DiskRead] = Number(disk, "read_byte"), [NasPerformanceMetric.DiskWrite] = Number(disk, "write_byte"),
            [NasPerformanceMetric.VolumeRead] = Number(volume, "read_byte"), [NasPerformanceMetric.VolumeWrite] = Number(volume, "write_byte"),
            [NasPerformanceMetric.DiskUtilization] = Percent(disk, "utilization"),
            [NasPerformanceMetric.NfsRead] = Sum(nfs, "read_OPS"), [NasPerformanceMetric.NfsWrite] = Sum(nfs, "write_OPS"),
        };
        var time = Number(data, "time");
        var recorded = time is { } seconds && seconds <= 253402300799 ? DateTimeOffset.UnixEpoch.AddSeconds(seconds) :
            time is null ? DateTimeOffset.UtcNow : throw InvalidPerformance();
        return new(ProfileId, recorded, new ReadOnlyDictionary<NasPerformanceMetric, double?>(values));
    }

    private static InvalidDataException InvalidPerformance() => new("nas-performance.invalid-response");
    private static JsonObject? Object(JsonObject? source, string key) => source?[key] switch
    { null => null, JsonObject value => value, _ => throw InvalidPerformance() };
    private static JsonObject[]? Rows(JsonObject source, string key) => source[key] switch
    {
        null => null,
        JsonArray array when array.All(value => value is JsonObject) => array.Cast<JsonObject>().ToArray(),
        _ => throw InvalidPerformance(),
    };
    private static double? Number(JsonObject? source, string key)
    {
        if (source?[key] is null) return null;
        if (source[key] is JsonValue value &&
            (value.TryGetValue<double>(out var number) || value.TryGetValue<string>(out var text) && double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out number)) &&
            double.IsFinite(number) && number >= 0) return number;
        throw InvalidPerformance();
    }
    private static double? Sum(JsonObject[]? rows, string key)
    {
        if (rows is null || rows.Length == 0) return null;
        var values = rows.Select(row => Number(row, key)).ToArray();
        if (values.Any(value => value is null)) return null;
        var total = values.Sum(value => value!.Value);
        return double.IsFinite(total) ? total : throw InvalidPerformance();
    }
}
