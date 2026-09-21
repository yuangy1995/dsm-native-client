using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<NasConnectionSnapshot> LoadConnectionSnapshotAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var capability = ConnectionCapability() ?? throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        var json = capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase);
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "list", new Dictionary<string, string>
        { ["start"] = "0", ["limit"] = "500", ["sort_by"] = json ? JsonSerializer.Serialize("time") : "time", ["sort_direction"] = json ? JsonSerializer.Serialize("DESC") : "DESC" }, cancellationToken).ConfigureAwait(false);
        if (data["items"] is not JsonArray rows || rows.Count > 500) throw InvalidNasServiceSettings();
        int? total = data["total"] is null ? null : data["total"] is JsonValue scalar && scalar.TryGetValue<int>(out var count) && count >= rows.Count ? count : throw InvalidNasServiceSettings();
        var result = new List<NasConnectionEntry>();
        foreach (var node in rows)
        {
            if (node is not JsonObject row) throw InvalidNasServiceSettings();
            var pid = DirectoryText(row["pid"]); var did = DirectoryText(row["did"]);
            if (pid?.Any(char.IsControl) == true || did?.Any(char.IsControl) == true) throw InvalidNasServiceSettings();
            var item = new NasConnectionEntry("", pid, did, DirectoryText(row["who"]), DirectoryText(row["from"]), DirectoryText(row["type"]),
                DirectoryText(row["descr"]), DirectoryText(row["protocol"]), DirectoryText(row["location"]), DirectoryText(row["time"]),
                DirectoryBoolean(row["is_current_connected"]), DirectoryBoolean(row["can_be_kicked"]));
            // 显示行标识与操作目标不同；缺少 DID/PID 的行只能查看，绝不用行号执行断开。
            result.Add(item with { Id = ServiceHash(JsonSerializer.Serialize(new { Index = result.Count, Data = ConnectionSignature(item) })),
                TargetKey = string.IsNullOrWhiteSpace(item.TargetIdentity) ? "" : ConnectionKey(item), IdentityKeys = ConnectionIdentityKeys(item) });
        }
        var entries = result.Select(item => item with { IsAmbiguous = !string.IsNullOrWhiteSpace(item.TargetIdentity) && result.Count(other =>
            item.IsWeb ? other.DeviceId == item.DeviceId : other.ProcessId == item.ProcessId) > 1 }).ToArray();
        return new(Array.AsReadOnly(entries), total, total is int known ? known == rows.Count : rows.Count < 500);
    }
    private ApiCapability? ConnectionCapability() => SecurityCapability("SYNO.Core.CurrentConnection", 1);
    private static string ConnectionKey(NasConnectionEntry item) => ServiceHash((item.IsWeb ? "web:" : "service:") + item.TargetIdentity);
    private static IReadOnlyList<string> ConnectionIdentityKeys(NasConnectionEntry item)
    {
        var keys = new List<string>();
        if (!string.IsNullOrWhiteSpace(item.DeviceId)) keys.Add(ServiceHash("web:" + item.DeviceId));
        if (!string.IsNullOrWhiteSpace(item.ProcessId)) keys.Add(ServiceHash("service:" + item.ProcessId));
        return keys.AsReadOnly();
    }
    private static string ConnectionSignature(NasConnectionEntry item) => JsonSerializer.Serialize(new
    {
        Pid = item.ProcessId is null ? null : ServiceHash(item.ProcessId), Did = item.DeviceId is null ? null : ServiceHash(item.DeviceId),
        item.Account, item.Source, item.Type, item.Description, item.Protocol, item.Location, item.ReportedTime, item.IsCurrent, item.DisconnectAllowed,
    });
}
