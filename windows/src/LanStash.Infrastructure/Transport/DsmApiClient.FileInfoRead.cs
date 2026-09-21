using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    // 仅补齐公开 List v2/getinfo 的只读契约，不开放任意 API 的同名方法。
    private static bool IsFileInfoRead(ApiCapability capability, int version, string method, IReadOnlyDictionary<string, string>? parameters)
    {
        if (capability.Name != "SYNO.FileStation.List" || version != 2 || method != "getinfo" ||
            parameters is null || parameters.Count is < 1 or > 2 || !parameters.TryGetValue("path", out var paths) ||
            parameters.Keys.Any(key => key is not ("path" or "additional"))) return false;
        try
        {
            using var pathDocument = JsonDocument.Parse(paths);
            if (pathDocument.RootElement.ValueKind != JsonValueKind.Array || pathDocument.RootElement.GetArrayLength() == 0) return false;
            foreach (var item in pathDocument.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String || item.GetString() is not { Length: > 0 } path ||
                    path[0] != '/' || path.Any(char.IsControl) || path.Contains('\\') ||
                    path.Split('/').Any(part => part is "." or "..")) return false;
            }
            if (parameters.TryGetValue("additional", out var fields))
            {
                using var additional = JsonDocument.Parse(fields);
                if (additional.RootElement.ValueKind != JsonValueKind.Array) return false;
                foreach (var item in additional.RootElement.EnumerateArray())
                    if (item.ValueKind != JsonValueKind.String || item.GetString() is not
                        ("size" or "time" or "perm" or "owner" or "type" or "real_path" or "mount_point_type")) return false;
            }
            return true;
        }
        catch (Exception error) when (error is JsonException or ArgumentException) { return false; }
    }
}
