using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Virtual Machine Manager 官方公开 v1 只读接口适配器。
/// 内部 SYNO.Virtualization.* 接口不属于本契约，也不会作为自动降级路径。
/// </summary>
public sealed partial class DsmRepository
{
    private const int PublicVirtualMachineApiVersion = 1;
    private const string PublicGuestApi = "SYNO.Virtualization.API.Guest";
    private const string PublicHostApi = "SYNO.Virtualization.API.Host";
    private const string PublicStorageApi = "SYNO.Virtualization.API.Storage";
    private const string PublicNetworkApi = "SYNO.Virtualization.API.Network";
    private const string PublicImageApi = "SYNO.Virtualization.API.Guest.Image";

    private bool HasReadablePublicVirtualMachineManagerContract =>
        HasPublicVirtualMachineVersion(PublicGuestApi);

    VirtualMachineManagerAvailability IVirtualMachineManagerRepository.Availability =>
        PublicVirtualMachineManagerAvailability;

    private VirtualMachineManagerAvailability PublicVirtualMachineManagerAvailability
    {
        get
        {
            if (!HasReadablePublicVirtualMachineManagerContract)
            {
                return new(
                    VirtualMachineManagerAvailabilityStatus.Unavailable,
                    new HashSet<VirtualMachineManagerReadFeature>());
            }

            var features = new HashSet<VirtualMachineManagerReadFeature>
            {
                VirtualMachineManagerReadFeature.Machines,
            };
            AddAvailableFeature(features, PublicHostApi, VirtualMachineManagerReadFeature.Hosts);
            AddAvailableFeature(features, PublicStorageApi, VirtualMachineManagerReadFeature.Storages);
            AddAvailableFeature(features, PublicNetworkApi, VirtualMachineManagerReadFeature.Networks);
            AddAvailableFeature(features, PublicImageApi, VirtualMachineManagerReadFeature.Images);
            return new(VirtualMachineManagerAvailabilityStatus.Available, features);
        }
    }

    public async Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(
        CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile();
        var availability = PublicVirtualMachineManagerAvailability;
        if (availability.Status != VirtualMachineManagerAvailabilityStatus.Available)
        {
            return UnavailableVirtualMachineManagerSnapshot();
        }

        var machines = await LoadPublicSectionAsync(
            PublicGuestApi,
            ParseMachines,
            cancellationToken).ConfigureAwait(false);
        var hosts = await LoadPublicResourceSectionAsync(
            PublicHostApi,
            "hosts",
            "host_id",
            "host_name",
            VirtualizationResourceKind.Host,
            cancellationToken).ConfigureAwait(false);
        var storages = await LoadPublicResourceSectionAsync(
            PublicStorageApi,
            "storages",
            "storage_id",
            "storage_name",
            VirtualizationResourceKind.Storage,
            cancellationToken).ConfigureAwait(false);
        var networks = await LoadPublicResourceSectionAsync(
            PublicNetworkApi,
            "networks",
            "network_id",
            "network_name",
            VirtualizationResourceKind.Network,
            cancellationToken).ConfigureAwait(false);
        var images = await LoadPublicResourceSectionAsync(
            PublicImageApi,
            "images",
            "image_id",
            "image_name",
            VirtualizationResourceKind.Image,
            cancellationToken).ConfigureAwait(false);

        return new(_profile.Id, machines, hosts, storages, networks, images);
    }

    private VirtualMachineManagerSnapshot UnavailableVirtualMachineManagerSnapshot() =>
        new(
            _profile.Id,
            VirtualMachineManagerSection<VirtualMachineSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable);

    private async Task<VirtualMachineManagerSection<VirtualizationResourceSummary>>
        LoadPublicResourceSectionAsync(
            string apiName,
            string root,
            string idKey,
            string nameKey,
            VirtualizationResourceKind kind,
            CancellationToken cancellationToken)
    {
        if (!HasPublicVirtualMachineVersion(apiName))
        {
            return VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable;
        }

        return await LoadPublicSectionAsync(
            apiName,
            data => ParseResources(data, root, idKey, nameKey, kind),
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<VirtualMachineManagerSection<T>> LoadPublicSectionAsync<T>(
        string apiName,
        Func<JsonObject, IReadOnlyList<T>> parse,
        CancellationToken cancellationToken)
    {
        try
        {
            var data = await CallPublicVirtualMachineAsync(
                apiName,
                "list",
                parameters: null,
                cancellationToken).ConfigureAwait(false);
            return VirtualMachineManagerSection<T>.Available(parse(data));
        }
        catch (DsmException error) when (!error.AuthenticationFailure)
        {
            return VirtualMachineManagerSection<T>.Failed;
        }
    }

    private Task<JsonObject> CallPublicVirtualMachineAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken)
    {
        if (!_capabilities.TryGetValue(apiName, out var capability) ||
            capability.MinVersion > PublicVirtualMachineApiVersion ||
            capability.MaxVersion < PublicVirtualMachineApiVersion)
        {
            throw UnavailableVirtualMachineManagerError();
        }

        return _api.CallAsync(
            _profile,
            _session,
            capability with
            {
                MinVersion = PublicVirtualMachineApiVersion,
                MaxVersion = PublicVirtualMachineApiVersion,
            },
            method,
            parameters,
            cancellationToken);
    }

    private bool HasPublicVirtualMachineVersion(string apiName) =>
        _capabilities.TryGetValue(apiName, out var capability) &&
        capability.MinVersion <= PublicVirtualMachineApiVersion &&
        capability.MaxVersion >= PublicVirtualMachineApiVersion;

    private void EnsureVirtualMachineManagerProfile()
    {
        if (_session.ProfileId != _profile.Id)
        {
            throw new DsmException(
                UserText.Key("WinShared11a208e43c34b77c"),
                UserText.Key("WinShared371d84f48836296f"),
                authenticationFailure: true);
        }
    }

    private void AddAvailableFeature(
        HashSet<VirtualMachineManagerReadFeature> features,
        string apiName,
        VirtualMachineManagerReadFeature feature)
    {
        if (HasPublicVirtualMachineVersion(apiName))
        {
            features.Add(feature);
        }
    }

    private static IReadOnlyList<VirtualMachineSummary> ParseMachines(JsonObject data)
    {
        var objects = RequiredObjectArray(data, "guests");
        var result = new List<VirtualMachineSummary>(objects.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in objects)
        {
            var id = RequiredStableId(item, "guest_id");
            var name = VirtualMachineRequiredString(item, "guest_name", "name");
            var status = VirtualMachineRequiredString(item, "status");
            if (!ids.Add(id))
            {
                throw InvalidVirtualMachineManagerResponse();
            }

            result.Add(new(
                id,
                name,
                ParseMachineState(status),
                item.Int("vcpu_num"),
                MiBToBytes(item.Long("vram_size")),
                ParseVirtualDiskBytes(item),
                OptionalStableId(item, "host_id"),
                VirtualMachineOptionalString(item, "host_name")));
        }
        return result;
    }

    private static IReadOnlyList<VirtualizationResourceSummary> ParseResources(
        JsonObject data,
        string root,
        string idKey,
        string nameKey,
        VirtualizationResourceKind kind)
    {
        var objects = RequiredObjectArray(data, root);
        var result = new List<VirtualizationResourceSummary>(objects.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in objects)
        {
            var id = RequiredStableId(item, idKey);
            var name = VirtualMachineRequiredString(item, nameKey);
            if (!ids.Add(id))
            {
                throw InvalidVirtualMachineManagerResponse();
            }

            result.Add(new(
                id,
                name,
                kind,
                ParseResourceHealth(VirtualMachineOptionalString(item, "status")),
                item.Long("allocated_size"),
                item.Long("size"),
                kind == VirtualizationResourceKind.Image
                    ? VirtualMachineOptionalString(item, "type")
                    : null));
        }
        return result;
    }

    private static List<JsonObject> RequiredObjectArray(JsonObject data, string root)
    {
        if (data[root] is not JsonArray array)
        {
            throw InvalidVirtualMachineManagerResponse();
        }

        var result = new List<JsonObject>(array.Count);
        foreach (var node in array)
        {
            if (node is not JsonObject item)
            {
                throw InvalidVirtualMachineManagerResponse();
            }
            result.Add(item);
        }
        return result;
    }

    private static string RequiredStableId(JsonObject item, string key) =>
        OptionalStableId(item, key) ?? throw InvalidVirtualMachineManagerResponse();

    private static string? OptionalStableId(JsonObject item, string key)
    {
        if (item[key] is not JsonValue value)
        {
            return null;
        }
        if (value.TryGetValue<string>(out var text))
        {
            var normalized = text.Trim();
            return normalized.Length == 0 ? null : normalized;
        }
        if (value.TryGetValue<long>(out var number))
        {
            return number.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<ulong>(out var unsignedLong))
        {
            return unsignedLong.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<int>(out var integer))
        {
            return integer.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        if (value.TryGetValue<uint>(out var unsignedInteger))
        {
            return unsignedInteger.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        return null;
    }

    private static string VirtualMachineRequiredString(JsonObject item, params string[] keys) =>
        keys.Select(key => VirtualMachineOptionalString(item, key))
            .FirstOrDefault(value => value is not null)
        ?? throw InvalidVirtualMachineManagerResponse();

    private static string? VirtualMachineOptionalString(JsonObject item, string key)
    {
        var value = item.String(key);
        return string.IsNullOrWhiteSpace(value) ? null : value;
    }

    private static long? ParseVirtualDiskBytes(JsonObject item)
    {
        if (item["vdisks"] is null)
        {
            return null;
        }
        if (item["vdisks"] is not JsonArray disks)
        {
            throw InvalidVirtualMachineManagerResponse();
        }

        long totalMiB = 0;
        foreach (var node in disks)
        {
            if (node is not JsonObject disk || disk.Long("vdisk_size") is not long size || size < 0)
            {
                throw InvalidVirtualMachineManagerResponse();
            }
            try
            {
                totalMiB = checked(totalMiB + size);
            }
            catch (OverflowException)
            {
                throw InvalidVirtualMachineManagerResponse();
            }
        }
        return MiBToBytes(totalMiB);
    }

    private static long? MiBToBytes(long? value)
    {
        if (value is null)
        {
            return null;
        }
        if (value < 0)
        {
            throw InvalidVirtualMachineManagerResponse();
        }
        try
        {
            return checked(value.Value * 1_024L * 1_024L);
        }
        catch (OverflowException)
        {
            throw InvalidVirtualMachineManagerResponse();
        }
    }

    private static VirtualMachineOperationalState ParseMachineState(string value) =>
        value.ToLowerInvariant() switch
        {
            "running" or "started" or "online" => VirtualMachineOperationalState.Running,
            "shutdown" or "stopped" or "offline" => VirtualMachineOperationalState.Stopped,
            "paused" or "suspended" => VirtualMachineOperationalState.Paused,
            "creating" or "starting" or "stopping" => VirtualMachineOperationalState.Transitional,
            "error" or "failed" => VirtualMachineOperationalState.Error,
            _ => VirtualMachineOperationalState.Unknown,
        };

    private static VirtualizationResourceHealth ParseResourceHealth(string? value) =>
        value?.ToLowerInvariant() switch
        {
            "running" or "online" or "healthy" or "normal" => VirtualizationResourceHealth.Healthy,
            "warning" or "degraded" => VirtualizationResourceHealth.Warning,
            "error" or "failed" or "critical" => VirtualizationResourceHealth.Error,
            "offline" or "stopped" => VirtualizationResourceHealth.Offline,
            _ => VirtualizationResourceHealth.Unknown,
        };

    private static DsmException InvalidVirtualMachineManagerResponse() =>
        new(
            UserText.Key("WinShared9cb9ec075b03b6cb"),
            UserText.Key("WinShared09f262a53ad074ca"));

    private static DsmException UnavailableVirtualMachineManagerError() =>
        new(
            UserText.Key("WinShared11a208e43c34b77c"),
            UserText.Key("WinShared371d84f48836296f"),
            102);
}
