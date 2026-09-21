using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasZramSnapshot> LoadZramAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var capability = SecurityCapability("SYNO.Core.Hardware.ZRAM", 1) ??
            throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "get", cancellationToken: cancellationToken).ConfigureAwait(false);
        bool? enabled = ExternalStorageField(data, "enable", "enabled", "zram_enable") is JsonValue scalar && scalar.TryGetValue<bool>(out var flag) ? flag : null;
        // 复用明确字节数和一致别名校验，不推断 size/capacity 的单位。
        var bytes = ExternalStorageBytes(ExternalStorageField(data, "configured_bytes", "capacity_bytes", "size_bytes"));
        var algorithm = ExternalStorageText(ExternalStorageField(data, "algorithm", "compression_algorithm", "compressor"))?.Trim().ToLowerInvariant() switch
        {
            "lz4" or "lz4hc" => NasZramAlgorithm.Lz4,
            "lzo" or "lzo-rle" or "lzorle" => NasZramAlgorithm.Lzo,
            "zstd" => NasZramAlgorithm.Zstd,
            _ => NasZramAlgorithm.Unknown
        };
        return new(enabled, bytes, algorithm);
    }
}
