using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<IReadOnlyList<NasEthernetInterface>> LoadEthernetInterfacesAsync(CancellationToken cancellationToken = default)
    {
        var snapshot = await LoadEthernetSnapshotAsync(cancellationToken).ConfigureAwait(false);
        if (snapshot.FailedInterfaces > 0) throw InvalidNasServiceSettings();
        return snapshot.Interfaces;
    }

    public async Task<NasEthernetSnapshot> LoadEthernetSnapshotAsync(CancellationToken cancellationToken = default)
    {
        var recovery = await GetEthernetRecoveryAsync(cancellationToken).ConfigureAwait(false);
        if (recovery?.RequiresSignIn == true)
            throw new DsmException(UserText.Key("NasNetworkFreshSignIn"), UserText.Key("NasNetworkFreshSignIn"), authenticationFailure: true);
        return await LoadEthernetSnapshotCoreAsync(cancellationToken).ConfigureAwait(false);
    }

    private async Task<NasEthernetSnapshot> LoadEthernetSnapshotCoreAsync(CancellationToken cancellationToken)
    {
        const string name = "SYNO.Core.Network.Ethernet";
        cancellationToken.ThrowIfCancellationRequested();
        if (!_capabilities.TryGetValue(name, out var capability) || capability.Name != name ||
            capability.MinVersion != 1 || capability.MaxVersion < 2 ||
            !(capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) ||
              capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)))
            throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        var list = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 2, "list",
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (list["interfaces"] is not JsonArray rows) throw InvalidNasServiceSettings();
        var targets = new Dictionary<string, JsonObject>(StringComparer.Ordinal);
        var failed = 0;
        foreach (var node in rows)
        {
            if (node is not JsonObject row) throw InvalidNasServiceSettings();
            var id = row.String("ifname") ?? row.String("id");
            if (id is null) { failed++; continue; }
            if (!id.StartsWith("eth", StringComparison.Ordinal)) continue;
            if (!NasEthernetSettingsRules.SafeId(id)) { failed++; continue; }
            if (!targets.TryAdd(id, row)) throw InvalidNasServiceSettings();
        }
        var result = new List<NasEthernetInterface>();
        foreach (var (id, row) in targets)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var detail = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "get",
                    new Dictionary<string, string> { ["ifname"] = capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase)
                        ? JsonSerializer.Serialize(id) : id }, cancellationToken).ConfigureAwait(false);
                result.Add(ParseEthernetInterface(id, detail, row));
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
            catch (DsmException error) when (error.AuthenticationFailure) { throw; }
            catch (Exception) { failed++; }
        }
        return new(result.AsReadOnly(), failed);
    }

    private static NasEthernetInterface ParseEthernetInterface(string id, JsonObject detail, JsonObject row)
    {
    var returnedId = detail.String("ifname") ?? detail.String("ethernet_ifname");
    if (returnedId is not null && returnedId != id) throw InvalidNasServiceSettings();
    JsonNode? Field(string key) => detail[key] ?? detail["ethernet_" + key] ?? row[key] ?? row["ethernet_" + key];
    var fields = new JsonObject();
    foreach (var key in new[] { "use_dhcp", "title", "display", "ip", "mask", "gateway", "dns", "mtu", "mtu_config", "enable_vlan", "vlan_id", "is_default_gateway", "status" })
        fields[key] = Field(key)?.DeepClone();
    if (fields.Bool("use_dhcp") is not bool dhcp) throw InvalidNasServiceSettings();
    var mtu = fields.Int("mtu") ?? fields.Int("mtu_config");
    var vlan = fields.Int("vlan_id");
    var dns = fields.String("dns");
    return new(id, fields.String("title") ?? fields.String("display") ?? id, dhcp,
        fields.String("ip"), fields.String("mask"), fields.String("gateway"),
        Array.AsReadOnly((dns ?? "").Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)),
        mtu is >= 576 and <= 9000 ? mtu : null, vlan is >= 1 and <= 4094 ? vlan : null)
    {
        IsDefaultGateway = fields.Bool("is_default_gateway"), VlanEnabled = fields.Bool("enable_vlan"),
        Status = fields.String("status"), ReportedDns = dns,
    };
    }

    public Task<MutationResult> SaveEthernetInterfaceAsync(string interfaceId, bool dhcp,
        string? ip, string? subnet, string? gateway, IReadOnlyList<string>? dns, int? mtu, int? vlan,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(UnsupportedResult("saveNetwork")); // 旧签名不能构造完整的单网卡 configs 或恢复原值。
}
