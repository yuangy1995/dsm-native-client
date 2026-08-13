using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Virtual Machine Manager 隐私白名单只读适配器。
/// 五个资源分区优先使用官方公开 v1；保护和事件只使用已记录的内部读取契约。
/// </summary>
public sealed partial class DsmRepository
{
    private const int PublicVirtualMachineApiVersion = 1;
    private const int VirtualMachineManagerSectionLimit = 200;
    private const string PublicGuestApi = "SYNO.Virtualization.API.Guest";
    private const string PublicHostApi = "SYNO.Virtualization.API.Host";
    private const string PublicStorageApi = "SYNO.Virtualization.API.Storage";
    private const string PublicNetworkApi = "SYNO.Virtualization.API.Network";
    private const string PublicImageApi = "SYNO.Virtualization.API.Guest.Image";
    private const string InternalProtectionApi = "SYNO.Virtualization.GuestProtect.Plan";
    private const string InternalEventApi = "SYNO.Virtualization.Log";

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
            AddAvailableInternalFeature(features, InternalProtectionApi, VirtualMachineManagerReadFeature.Protection, 1, 2);
            AddAvailableInternalFeature(features, InternalEventApi, VirtualMachineManagerReadFeature.Events, 1, 1);
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
        var protection = await LoadProtectionSectionAsync(cancellationToken).ConfigureAwait(false);
        var events = await LoadVirtualMachineEventSectionAsync(cancellationToken).ConfigureAwait(false);

        return new(_profile.Id, machines, hosts, storages, networks, images, protection, events);
    }

    private VirtualMachineManagerSnapshot UnavailableVirtualMachineManagerSnapshot() =>
        new(
            _profile.Id,
            VirtualMachineManagerSection<VirtualMachineSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<ServiceEventSummary>.Unavailable);

    private async Task<VirtualMachineManagerSection<VirtualizationResourceSummary>>
        LoadProtectionSectionAsync(CancellationToken cancellationToken)
    {
        if (!HasInternalVirtualMachineVersion(InternalProtectionApi, 1, 2))
        {
            return VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable;
        }

        return await LoadInternalVirtualMachineSectionAsync(
            InternalProtectionApi,
            ["list"],
            parameters: null,
            ParseProtectionResources,
            minimumVersion: 1,
            maximumVersion: 2,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<VirtualMachineManagerSection<ServiceEventSummary>>
        LoadVirtualMachineEventSectionAsync(CancellationToken cancellationToken)
    {
        if (!HasInternalVirtualMachineVersion(InternalEventApi, 1, 1))
        {
            return VirtualMachineManagerSection<ServiceEventSummary>.Unavailable;
        }

        return await LoadInternalVirtualMachineSectionAsync(
            InternalEventApi,
            ["list"],
            new Dictionary<string, string>
            {
                ["offset"] = "0",
                ["limit"] = "1000",
                ["loglevel"] = string.Empty,
                ["filter_content"] = string.Empty,
                ["datefrom"] = "0",
                ["dateto"] = "0",
                ["sort_by"] = "time",
                ["sort_dir"] = "DESC",
            },
            ParseVirtualMachineEvents,
            minimumVersion: 1,
            maximumVersion: 1,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<VirtualMachineManagerSection<T>> LoadInternalVirtualMachineSectionAsync<T>(
        string apiName,
        string[] methods,
        IReadOnlyDictionary<string, string>? parameters,
        Func<JsonObject, IReadOnlyList<T>> parse,
        int minimumVersion,
        int maximumVersion,
        CancellationToken cancellationToken)
    {
        foreach (var method in methods)
        {
            try
            {
                var data = await CallInternalVirtualMachineAsync(
                    apiName,
                    method,
                    parameters,
                    minimumVersion,
                    maximumVersion,
                    cancellationToken).ConfigureAwait(false);
                return VirtualMachineManagerSection<T>.Available(parse(data));
            }
            catch (DsmException error) when (!IsMutationAuthenticationFailure(error))
            {
                if (method == methods[^1])
                {
                    return VirtualMachineManagerSection<T>.Failed;
                }
            }
        }
        return VirtualMachineManagerSection<T>.Failed;
    }

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
        catch (DsmException error) when (!IsMutationAuthenticationFailure(error))
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

    private Task<JsonObject> CallInternalVirtualMachineAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        int minimumVersion,
        int maximumVersion,
        CancellationToken cancellationToken)
    {
        var capability = _capabilities[apiName];
        return _api.CallAsync(
            _profile,
            _session,
            capability with
            {
                MinVersion = Math.Max(capability.MinVersion, minimumVersion),
                MaxVersion = Math.Min(capability.MaxVersion, maximumVersion),
            },
            method,
            parameters,
            cancellationToken);
    }

    private bool HasPublicVirtualMachineVersion(string apiName) =>
        _capabilities.TryGetValue(apiName, out var capability) &&
        capability.MinVersion <= PublicVirtualMachineApiVersion &&
        capability.MaxVersion >= PublicVirtualMachineApiVersion;

    private bool HasInternalVirtualMachineVersion(
        string apiName,
        int minimumVersion,
        int maximumVersion) =>
        _capabilities.TryGetValue(apiName, out var capability) &&
        capability.MaxVersion >= minimumVersion &&
        capability.MinVersion <= maximumVersion;

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

    private void AddAvailableInternalFeature(
        HashSet<VirtualMachineManagerReadFeature> features,
        string apiName,
        VirtualMachineManagerReadFeature feature,
        int minimumVersion,
        int maximumVersion)
    {
        if (HasInternalVirtualMachineVersion(apiName, minimumVersion, maximumVersion))
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

    private static IReadOnlyList<VirtualizationResourceSummary> ParseProtectionResources(
        JsonObject data)
    {
        var result = new List<VirtualizationResourceSummary>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        string[][] knownRoots =
        [
            ["plans", "plan", "protection_plans", "guest_protects"],
            ["schedule_policies", "schedules", "schedule_policy"],
            ["retention_policies", "retentions", "retention_policy"],
        ];
        var knownRootNames = knownRoots.SelectMany(roots => roots).ToHashSet(StringComparer.Ordinal);
        if (data.Any(pair => pair.Value is JsonArray && !knownRootNames.Contains(pair.Key)))
        {
            throw InvalidVirtualMachineManagerResponse();
        }

        var recognizedRoot = false;
        AppendProtectionResources(
            result,
            ids,
            data,
            knownRoots[0],
            VirtualizationResourceKind.ProtectionPlan,
            ref recognizedRoot);
        AppendProtectionResources(
            result,
            ids,
            data,
            knownRoots[1],
            VirtualizationResourceKind.ProtectionSchedule,
            ref recognizedRoot);
        AppendProtectionResources(
            result,
            ids,
            data,
            knownRoots[2],
            VirtualizationResourceKind.ProtectionRetention,
            ref recognizedRoot);
        if (!recognizedRoot)
        {
            throw InvalidVirtualMachineManagerResponse();
        }
        return result;
    }

    private static void AppendProtectionResources(
        List<VirtualizationResourceSummary> result,
        HashSet<string> ids,
        JsonObject data,
        string[] roots,
        VirtualizationResourceKind kind,
        ref bool recognizedRoot)
    {
        var array = roots.Select(root => data[root]).OfType<JsonArray>().FirstOrDefault();
        if (array is null)
        {
            return;
        }
        recognizedRoot = true;
        var remaining = VirtualMachineManagerSectionLimit - result.Count;
        foreach (var node in array.Take(remaining))
        {
            if (node is not JsonObject item)
            {
                throw InvalidVirtualMachineManagerResponse();
            }
            var name = VirtualMachineRequiredString(
                item,
                "name",
                "plan_name",
                "policy_name",
                "title",
                "id");
            var id = OptionalStableId(item, "id") ??
                OptionalStableId(item, "plan_id") ??
                OptionalStableId(item, "policy_id") ?? name;
            if (!ids.Add(id))
            {
                throw InvalidVirtualMachineManagerResponse();
            }
            result.Add(new(
                id,
                name,
                kind,
                ParseResourceHealth(VirtualMachineOptionalString(item, "status") ??
                    VirtualMachineOptionalString(item, "state"))));
        }
    }

    private static IReadOnlyList<ServiceEventSummary> ParseVirtualMachineEvents(JsonObject data)
    {
        var objects = RequiredObjectArray(
            data,
            "logs",
            "log",
            "events",
            "records",
            "entries",
            "items",
            "data",
            "list");
        var result = new List<ServiceEventSummary>(objects.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in objects.Select((item, index) => (item, index)))
        {
            var occurredAt = entry.item.Date("time") ?? entry.item.Date("timestamp") ??
                entry.item.Date("date") ?? entry.item.Date("event_time") ??
                entry.item.Date("create_time") ?? entry.item.Date("created_at");
            var id = OptionalStableId(entry.item, "id") ??
                OptionalStableId(entry.item, "log_id") ??
                $"event-{occurredAt?.ToUnixTimeSeconds() ?? 0}-{entry.index}";
            if (!ids.Add(id))
            {
                throw InvalidVirtualMachineManagerResponse();
            }
            result.Add(new(
                id,
                occurredAt,
                ParseVirtualMachineEventLevel(
                    VirtualMachineOptionalString(entry.item, "level") ??
                    VirtualMachineOptionalString(entry.item, "severity") ??
                    VirtualMachineOptionalString(entry.item, "type") ??
                    VirtualMachineOptionalString(entry.item, "priority"))));
        }
        return result;
    }

    private static List<JsonObject> RequiredObjectArray(JsonObject data, params string[] roots)
    {
        var array = roots.Select(root => data[root]).OfType<JsonArray>().FirstOrDefault()
            ?? throw InvalidVirtualMachineManagerResponse();

        var result = new List<JsonObject>(Math.Min(array.Count, VirtualMachineManagerSectionLimit));
        foreach (var node in array.Take(VirtualMachineManagerSectionLimit))
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

    private static ServiceEventLevel ParseVirtualMachineEventLevel(string? value) =>
        value?.ToLowerInvariant() switch
        {
            "info" or "information" or "0" => ServiceEventLevel.Information,
            "warning" or "warn" or "1" => ServiceEventLevel.Warning,
            "error" or "err" or "2" => ServiceEventLevel.Error,
            _ => ServiceEventLevel.Unknown,
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
