using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string InternalHostApi = "SYNO.Virtualization.Host";

    private static string InternalVirtualMachineResourceApi(VirtualizationResourceKind kind) => kind switch
    {
        VirtualizationResourceKind.Host => InternalHostApi,
        VirtualizationResourceKind.Storage => InternalCreationRepoApi,
        VirtualizationResourceKind.Network => ManagedNetworkApi,
        VirtualizationResourceKind.Image => InternalCreationImageApi,
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };

    private async Task<IReadOnlyList<VirtualMachineSummary>> ReadVirtualMachineInventoryAsync(VirtualMachineApiSource source, CancellationToken token)
    {
        var data = source == VirtualMachineApiSource.Public
            ? await CallPublicVirtualMachineAsync(PublicGuestApi, "list", null, token).ConfigureAwait(false)
            : await CallInternalVirtualMachineAsync(InternalSettingsGuestApi, "list", null, 2, 2, token).ConfigureAwait(false);
        return source == VirtualMachineApiSource.Public ? ParseMachines(data) : ParseInternalMachines(data);
    }

    private static IReadOnlyList<VirtualMachineSummary> ParseInternalMachines(JsonObject data)
    {
        var rows = RequiredObjectArray(data, "guests", "guest", "vms");
        RequireCompleteVirtualMachineList(data, rows.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        return rows.Select(item =>
        {
            var id = AdvancedText(item, "guest_id");
            if (!VirtualMachinePowerRules.ValidId(id) || !ids.Add(id)) throw InvalidVirtualMachineManagerResponse();
            var cpu = OptionalVirtualMachineInteger(item, "vcpu_num", 1, int.MaxValue);
            var kib = OptionalVirtualMachineInteger(item, "vram_size", 1, long.MaxValue / 1024);
            return new VirtualMachineSummary(id, AdvancedText(item, "name"), ParseMachineState(AdvancedText(item, "status")),
                cpu is null ? null : (int)cpu.Value, kib * 1024, ParseVirtualDiskBytes(item),
                VirtualMachineOptionalString(item, "host_id"), VirtualMachineOptionalString(item, "host_name")) { Source = VirtualMachineApiSource.Internal };
        }).ToArray();
    }

    private static IReadOnlyList<VirtualizationResourceSummary> ParseInternalVirtualMachineResources(JsonObject data, VirtualizationResourceKind kind)
    {
        if (kind == VirtualizationResourceKind.Image) return ParseInternalVirtualMachineImages(data);
        var (root, idKey) = kind switch
        {
            VirtualizationResourceKind.Host => ("hosts", "host_id"),
            VirtualizationResourceKind.Storage => ("repos", "repo_id"),
            VirtualizationResourceKind.Network => ("networks", "network_id"),
            _ => throw new ArgumentOutOfRangeException(nameof(kind)),
        };
        var rows = RequiredObjectArray(data, root);
        RequireCompleteVirtualMachineList(data, rows.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        return rows.Select(item =>
        {
            var id = AdvancedText(item, idKey);
            if (!VirtualMachinePowerRules.ValidId(id) || !ids.Add(id)) throw InvalidVirtualMachineManagerResponse();
            var name = VirtualMachineRequiredString(item, "name", kind == VirtualizationResourceKind.Host ? "host_name" : "name");
            // Repo 的 size/used 字符串及 allocated_size 没有已确认的展示单位，不按公开 MiB 猜测。
            return new VirtualizationResourceSummary(id, name, kind,
                ParseResourceHealth(VirtualMachineOptionalString(item, "status_type") ?? VirtualMachineOptionalString(item, "status")),
                Type: VirtualMachineOptionalString(item, "type"))
            { Source = VirtualMachineApiSource.Internal, Detail = VirtualMachineResourceDetail(item), IsFrozen = OptionalVirtualMachineBoolean(data, "is_freeze") };
        }).ToArray();
    }

    private static IReadOnlyList<VirtualizationResourceSummary> ParseInternalVirtualMachineImages(JsonObject data)
    {
        var rows = RequiredObjectArray(data, "images");
        RequireCompleteVirtualMachineList(data, rows.Count);
        var frozen = OptionalVirtualMachineBoolean(data, "is_freeze");
        var result = new Dictionary<string, VirtualizationResourceSummary>(StringComparer.Ordinal);
        foreach (var row in rows)
        {
            var id = AdvancedText(row, "id");
            if (!VirtualMachinePowerRules.ValidId(id)) throw InvalidVirtualMachineManagerResponse();
            var name = VirtualMachineOptionalString(row, "name") ?? "";
            var type = VirtualMachineOptionalString(row, "type");
            var storage = VirtualMachineOptionalString(row, "repo_id"); var host = VirtualMachineOptionalString(row, "host_id");
            var status = VirtualMachineOptionalString(row, "status"); var statusType = VirtualMachineOptionalString(row, "status_type");
            var replica = storage is not null && host is not null && status is not null && statusType is not null
                ? new VirtualMachineImageReplica(storage, host, status, statusType) : null;
            if (result.TryGetValue(id, out var prior))
            {
                if (prior.Name != name || prior.Type != type || prior.ImageReplicas is null || replica is null ||
                    prior.ImageReplicas.Any(item => item.StorageId == storage && item.HostId == host)) throw InvalidVirtualMachineManagerResponse();
                result[id] = prior with { ImageReplicas = prior.ImageReplicas.Append(replica).OrderBy(item => item.StorageId, StringComparer.Ordinal)
                    .ThenBy(item => item.HostId, StringComparer.Ordinal).ToArray() };
            }
            else result.Add(id, new(id, name, VirtualizationResourceKind.Image, ParseResourceHealth(statusType ?? status), Type: type)
            {
                Source = VirtualMachineApiSource.Internal, Detail = VirtualMachineResourceDetail(row), IsFrozen = frozen,
                ImageReplicas = replica is null ? null : [replica],
            });
        }
        return result.Values.Select(item => item.ImageReplicas is { } replicas ? item with
        {
            Health = replicas.Any(copy => ParseResourceHealth(copy.StatusType) == VirtualizationResourceHealth.Error) ? VirtualizationResourceHealth.Error :
                replicas.Any(copy => ParseResourceHealth(copy.Status) == VirtualizationResourceHealth.Offline) ? VirtualizationResourceHealth.Offline :
                replicas.All(copy => copy.Status == "online" && copy.StatusType == "healthy") ? VirtualizationResourceHealth.Healthy : VirtualizationResourceHealth.Unknown,
        } : item).OrderBy(item => item.Id, StringComparer.Ordinal).ToArray();
    }

    private static string? VirtualMachineResourceDetail(JsonObject row) => new[] { "description", "type", "path", "volume_path" }
        .Select(key => VirtualMachineOptionalString(row, key)).FirstOrDefault(value => value is not null);

    private static long? OptionalVirtualMachineInteger(JsonObject data, string key, long minimum, long maximum)
    {
        if (!data.ContainsKey(key)) return null;
        if (data[key] is JsonValue node)
        {
            if (node.TryGetValue<int>(out var integer) && integer >= minimum && integer <= maximum) return integer;
            if (node.TryGetValue<long>(out var number) && number >= minimum && number <= maximum) return number;
        }
        throw InvalidVirtualMachineManagerResponse();
    }

    private static bool? OptionalVirtualMachineBoolean(JsonObject data, string key) => !data.ContainsKey(key) ? null : AdvancedBool(data, key);

    private static void RequireCompleteVirtualMachineList(JsonObject data, int count)
    {
        if (OptionalVirtualMachineInteger(data, "total", 0, int.MaxValue) is { } total && total != count ||
            OptionalVirtualMachineInteger(data, "offset", 0, int.MaxValue) is { } offset && offset != 0) throw InvalidVirtualMachineManagerResponse();
    }
}
