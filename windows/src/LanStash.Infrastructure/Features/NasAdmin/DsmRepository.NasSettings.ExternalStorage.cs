using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasExternalStorageDirectory> LoadExternalStorageAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var sources = new[]
        {
            (Api: "SYNO.Core.ExternalDevice.Storage.USB", Connection: NasExternalStorageConnection.Usb, Flag: NasExternalStorageSources.Usb, Key: "usb_devices"),
            (Api: "SYNO.Core.ExternalDevice.Storage.eSATA", Connection: NasExternalStorageConnection.Esata, Flag: NasExternalStorageSources.Esata, Key: "esata_devices")
        };
        if (!sources.Any(source => SecurityCapability(source.Api, 1) is not null))
            throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        var devices = new List<NasExternalStorageDevice>(); var total = 0; var ignored = 0; var truncated = false;
        var available = NasExternalStorageSources.None; var unavailable = NasExternalStorageSources.None;
        foreach (var source in sources)
        {
            var capability = SecurityCapability(source.Api, 1);
            if (capability is null) { unavailable |= source.Flag; continue; }
            try
            {
                var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "list", cancellationToken: cancellationToken).ConfigureAwait(false);
                if (ExternalStorageField(data, "devices", "items", "storages", source.Key) is not JsonArray rows) throw InvalidNasServiceSettings();
                var parsed = new List<NasExternalStorageDevice>(); var seen = new HashSet<string>(StringComparer.Ordinal); var skipped = 0;
                for (var index = 0; index < Math.Min(rows.Count, 64); index++)
                {
                    if (rows[index] is not JsonObject item) { skipped++; continue; }
                    var identifier = ExternalStorageText(ExternalStorageField(item, "id", "device_id", "storage_id"));
                    var safeId = identifier is { Length: > 0 and <= 128 } && identifier.All(c => char.IsLetterOrDigit(c) || "._-:".Contains(c)) ? identifier : $"snapshot-{index}";
                    if (!seen.Add(safeId)) { skipped++; continue; }
                    var name = new[] { "display_name", "name", "model" }.Select(key => ExternalStorageText(item[key])).FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim();
                    if (name is not { Length: > 0 and <= 160 } || name.Any(char.IsControl) || name.Contains('/') || name.Contains('\\')) name = null;
                    var capacity = ExternalStorageBytes(ExternalStorageField(item, "capacity_bytes", "total_bytes", "size_bytes"));
                    var used = ExternalStorageBytes(ExternalStorageField(item, "used_bytes", "usage_bytes"));
                    if (capacity is not null && used > capacity) used = null;
                    var status = ExternalStorageText(ExternalStorageField(item, "status", "state"))?.Trim().ToLowerInvariant() switch
                    {
                        "ready" or "normal" or "healthy" or "connected" or "mounted" or "active" => NasExternalStorageStatus.Ready,
                        "busy" or "in_use" or "in-use" or "syncing" or "checking" => NasExternalStorageStatus.Busy,
                        "unavailable" or "offline" or "disconnected" or "error" or "failed" => NasExternalStorageStatus.Unavailable,
                        _ => NasExternalStorageStatus.Unknown
                    };
                    parsed.Add(new($"{source.Connection}:{safeId}", name, source.Connection, status, capacity, used));
                }
                var reported = ExternalStorageBytes(ExternalStorageField(data, "total", "total_count"));
                if (reported > 1_000_000) reported = null;
                total += Math.Max(rows.Count, (int?)reported ?? rows.Count);
                truncated |= rows.Count > 64 || reported > rows.Count;
                ignored += skipped; devices.AddRange(parsed); available |= source.Flag;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (DsmException error) when (error.AuthenticationFailure) { throw; }
            catch (Exception) { unavailable |= source.Flag; }
        }
        if (available == NasExternalStorageSources.None) throw InvalidNasServiceSettings();
        return new(devices.AsReadOnly(), total, truncated, ignored, available, unavailable);
    }
    private static string? ExternalStorageText(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
    private static long? ExternalStorageBytes(JsonNode? node)
    {
        if (node is JsonValue value)
        {
            if (value.TryGetValue<long>(out var integer)) return integer >= 0 ? integer : null;
            if (value.TryGetValue<decimal>(out var number) && number == decimal.Truncate(number) && number is >= 0 and <= long.MaxValue) return (long)number;
        }
        return long.TryParse(ExternalStorageText(node), NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
    }
    private static JsonNode? ExternalStorageField(JsonObject data, params string[] names)
    {
        JsonNode? selected = null;
        foreach (var name in names)
        {
            if (data[name] is not { } value) continue;
            if (selected is not null && !JsonNode.DeepEquals(selected, value)) return null;
            selected = value;
        }
        return selected;
    }
}
