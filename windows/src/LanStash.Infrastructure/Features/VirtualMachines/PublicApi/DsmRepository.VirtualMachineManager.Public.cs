using System.Text.Json.Nodes;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Virtual Machine Manager 隐私白名单只读适配器。
/// 五个资源分区优先使用官方公开 v1；保护和事件只使用已记录的内部读取契约。
/// </summary>
public sealed partial class DsmRepository
{
    private const int PublicVirtualMachineApiVersion = 1;
    private const string PublicGuestApi = "SYNO.Virtualization.API.Guest";
    private const string PublicHostApi = "SYNO.Virtualization.API.Host";
    private const string PublicStorageApi = "SYNO.Virtualization.API.Storage";
    private const string PublicNetworkApi = "SYNO.Virtualization.API.Network";
    private const string PublicImageApi = "SYNO.Virtualization.API.Guest.Image";
    private const string InternalProtectionApi = "SYNO.Virtualization.GuestProtect.Plan";
    private const string InternalEventApi = "SYNO.Virtualization.Log";

    private bool HasReadableVirtualMachineManagerContract =>
        HasPublicVirtualMachineVersion(PublicGuestApi) || HasInternalVirtualMachineVersion(InternalSettingsGuestApi, 2, 2);

    VirtualMachineManagerAvailability IVirtualMachineManagerRepository.Availability =>
        PublicVirtualMachineManagerAvailability;

    private VirtualMachineManagerAvailability PublicVirtualMachineManagerAvailability
    {
        get
        {
            if (!HasReadableVirtualMachineManagerContract)
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
            AddAvailableInternalFeature(features, InternalHostApi, VirtualMachineManagerReadFeature.Hosts, 2, 2);
            AddAvailableInternalFeature(features, InternalCreationRepoApi, VirtualMachineManagerReadFeature.Storages, 2, 2);
            AddAvailableInternalFeature(features, ManagedNetworkApi, VirtualMachineManagerReadFeature.Networks, 2, 2);
            AddAvailableInternalFeature(features, InternalCreationImageApi, VirtualMachineManagerReadFeature.Images, 2, 2);
            AddAvailableInternalFeature(features, InternalProtectionApi, VirtualMachineManagerReadFeature.Protection, 1, 2);
            AddAvailableInternalFeature(features, InternalEventApi, VirtualMachineManagerReadFeature.Events, 1, 1);
            return new(VirtualMachineManagerAvailabilityStatus.Available, features);
        }
    }

    public Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default) =>
        LoadVirtualMachineSnapshotAsync(includeActivity: true, cancellationToken);
    Task<VirtualMachineManagerSnapshot> IVirtualMachineManagerRepository.LoadInventoryAsync(CancellationToken cancellationToken) =>
        LoadVirtualMachineSnapshotAsync(includeActivity: false, cancellationToken);
    Task<VirtualMachineManagerSection<ServiceActivityEntry>> IVirtualMachineManagerRepository.LoadActivityAsync(CancellationToken cancellationToken) =>
        LoadVirtualMachineActivityAsync(includeBody: true, cancellationToken);

    private async Task<VirtualMachineManagerSnapshot> LoadVirtualMachineSnapshotAsync(bool includeActivity, CancellationToken cancellationToken)
    {
        EnsureVirtualMachineManagerProfile();
        var availability = PublicVirtualMachineManagerAvailability;
        if (availability.Status != VirtualMachineManagerAvailabilityStatus.Available)
        {
            return UnavailableVirtualMachineManagerSnapshot();
        }

        var machines = HasPublicVirtualMachineVersion(PublicGuestApi)
            ? await LoadPublicSectionAsync(PublicGuestApi, ParseMachines, cancellationToken).ConfigureAwait(false)
            : await LoadInternalVirtualMachineSectionAsync(InternalSettingsGuestApi, ["list"], null, ParseInternalMachines, 2, 2, cancellationToken).ConfigureAwait(false);
        var hosts = await LoadVirtualMachineResourceSectionAsync(
            PublicHostApi,
            "hosts",
            "host_id",
            "host_name",
            VirtualizationResourceKind.Host,
            cancellationToken).ConfigureAwait(false);
        var storages = await LoadVirtualMachineResourceSectionAsync(
            PublicStorageApi,
            "storages",
            "storage_id",
            "storage_name",
            VirtualizationResourceKind.Storage,
            cancellationToken).ConfigureAwait(false);
        var networks = await LoadVirtualMachineResourceSectionAsync(
            PublicNetworkApi,
            "networks",
            "network_id",
            "network_name",
            VirtualizationResourceKind.Network,
            cancellationToken).ConfigureAwait(false);
        var images = await LoadVirtualMachineResourceSectionAsync(
            PublicImageApi,
            "images",
            "image_id",
            "image_name",
            VirtualizationResourceKind.Image,
            cancellationToken).ConfigureAwait(false);
        var protection = await LoadProtectionSectionAsync(cancellationToken).ConfigureAwait(false);
        var activity = includeActivity ? await LoadVirtualMachineActivityAsync(includeBody: false, cancellationToken).ConfigureAwait(false) :
            new VirtualMachineManagerSection<ServiceActivityEntry>(HasInternalVirtualMachineVersion(InternalEventApi, 1, 1) ?
                VirtualMachineManagerSectionStatus.Available : VirtualMachineManagerSectionStatus.Unavailable, []);
        var events = new VirtualMachineManagerSection<ServiceEventSummary>(activity.Status, activity.Items.Select(item => item.Summary).ToArray());

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

    private async Task<VirtualMachineManagerSection<ServiceActivityEntry>> LoadVirtualMachineActivityAsync(bool includeBody, CancellationToken cancellationToken)
    {
        EnsureVirtualMachineManagerProfile();
        if (!HasInternalVirtualMachineVersion(InternalEventApi, 1, 1))
            return VirtualMachineManagerSection<ServiceActivityEntry>.Unavailable;
        const int pageSize = 1000;
        var events = new List<ServiceActivityEntry>(); var ids = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            while (true)
            {
                var offset = events.Count;
                var data = await CallInternalVirtualMachineAsync(InternalEventApi, "list", new Dictionary<string, string>
                {
                    ["offset"] = offset.ToString(System.Globalization.CultureInfo.InvariantCulture), ["limit"] = pageSize.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    ["loglevel"] = "", ["filter_content"] = "", ["datefrom"] = "0", ["dateto"] = "0", ["sort_by"] = "time", ["sort_dir"] = "DESC",
                }, 1, 1, cancellationToken).ConfigureAwait(false);
                if (OptionalVirtualMachineInteger(data, "offset", 0, int.MaxValue) is { } returnedOffset && returnedOffset != offset) throw InvalidVirtualMachineManagerResponse();
                var total = OptionalVirtualMachineInteger(data, "total", 0, int.MaxValue);
                var page = ParseServiceActivity(RequiredObjectArray(data, "logs", "log", "events", "records", "entries", "items", "data", "list"), offset, includeBody);
                if (page.Count > pageSize || page.Any(item => !ids.Add(item.Summary.Id))) throw InvalidVirtualMachineManagerResponse();
                events.AddRange(page);
                if (total is null || total == events.Count) return VirtualMachineManagerSection<ServiceActivityEntry>.Available(events);
                if (events.Count > total || page.Count == 0) throw InvalidVirtualMachineManagerResponse();
            }
        }
        catch (DsmException error) when (!IsMutationAuthenticationFailure(error)) { return VirtualMachineManagerSection<ServiceActivityEntry>.Failed; }
        catch (HttpRequestException) { return VirtualMachineManagerSection<ServiceActivityEntry>.Failed; }
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
            catch (HttpRequestException) { return VirtualMachineManagerSection<T>.Failed; }
        }
        return VirtualMachineManagerSection<T>.Failed;
    }

    private async Task<VirtualMachineManagerSection<VirtualizationResourceSummary>>
        LoadVirtualMachineResourceSectionAsync(
            string apiName,
            string root,
            string idKey,
            string nameKey,
            VirtualizationResourceKind kind,
            CancellationToken cancellationToken)
    {
        if (!HasPublicVirtualMachineVersion(apiName))
        {
            var internalApi = InternalVirtualMachineResourceApi(kind);
            if (!HasInternalVirtualMachineVersion(internalApi, 2, 2)) return VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable;
            return await LoadInternalVirtualMachineSectionAsync(internalApi, ["list"], null,
                data => ParseInternalVirtualMachineResources(data, kind), 2, 2, cancellationToken).ConfigureAwait(false);
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
        catch (HttpRequestException) { return VirtualMachineManagerSection<T>.Failed; }
    }

    private Task<JsonObject> CallPublicVirtualMachineAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!HasPublicVirtualMachineVersion(apiName))
        {
            throw UnavailableVirtualMachineManagerError();
        }

        var capability = _capabilities[apiName];

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
        cancellationToken.ThrowIfCancellationRequested();
        if (!HasInternalVirtualMachineVersion(apiName, minimumVersion, maximumVersion))
            throw UnavailableVirtualMachineManagerError();
        var capability = _capabilities[apiName];
        // 内部日志的分页/日期是数字，筛选和排序字段按声明编码为 JSON 字符串。
        if (capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase) && parameters is not null)
            parameters = parameters.ToDictionary(pair => pair.Key,
                pair => pair.Key is "offset" or "limit" or "datefrom" or "dateto" ? pair.Value : JsonSerializer.Serialize(pair.Value), StringComparer.Ordinal);
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
        ValidVirtualMachineCapability(apiName, capability) &&
        capability.MinVersion <= PublicVirtualMachineApiVersion &&
        capability.MaxVersion >= PublicVirtualMachineApiVersion;

    private bool HasInternalVirtualMachineVersion(
        string apiName,
        int minimumVersion,
        int maximumVersion) =>
        _capabilities.TryGetValue(apiName, out var capability) &&
        ValidVirtualMachineCapability(apiName, capability) &&
        capability.MaxVersion >= minimumVersion &&
        capability.MinVersion <= maximumVersion;

    private static bool ValidVirtualMachineCapability(string apiName, ApiCapability capability) =>
        capability.Name == apiName && capability.MinVersion >= 1 && capability.MaxVersion >= capability.MinVersion &&
        (capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) || capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase));

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
        RequireCompleteVirtualMachineList(data, objects.Count);
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
        RequireCompleteVirtualMachineList(data, objects.Count);
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
                kind == VirtualizationResourceKind.Storage ? MiBToBytes(item.Long("used")) : item.Long("allocated_size"),
                kind == VirtualizationResourceKind.Storage ? MiBToBytes(item.Long("size")) : item.Long("size"),
                kind == VirtualizationResourceKind.Image
                    ? VirtualMachineOptionalString(item, "type")
                    : null) { Detail = VirtualMachineResourceDetail(item) });
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
        // 官方 Plan.list v2 在没有保护计划时返回 protect_ids 空数组。
        // 非空编号不是完整计划详情，不能当作空列表或猜测后续请求。
        var hasEmptyProtectionIds = false;
        if (data.TryGetPropertyValue("protect_ids", out var protectionIds))
        {
            if (protectionIds is not JsonArray { Count: 0 })
                throw InvalidVirtualMachineManagerResponse();
            hasEmptyProtectionIds = true;
            knownRootNames.Add("protect_ids");
        }
        if (data.Any(pair => pair.Value is JsonArray && !knownRootNames.Contains(pair.Key)))
        {
            throw InvalidVirtualMachineManagerResponse();
        }

        var recognizedRoot = hasEmptyProtectionIds;
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
        if (!recognizedRoot || hasEmptyProtectionIds && result.Count > 0)
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
        var array = VirtualMachineArray(data, roots);
        if (array is null)
        {
            return;
        }
        recognizedRoot = true;
        foreach (var node in array)
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

    private static List<JsonObject> RequiredObjectArray(JsonObject data, params string[] roots)
    {
        var array = VirtualMachineArray(data, roots)
            ?? throw InvalidVirtualMachineManagerResponse();

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

    private static JsonArray? VirtualMachineArray(JsonObject data, string[] roots)
    {
        JsonArray? result = null;
        foreach (var key in roots.Where(data.ContainsKey))
        {
            if (data[key] is not JsonArray array || result is not null && !JsonNode.DeepEquals(result, array))
                throw InvalidVirtualMachineManagerResponse();
            result = array;
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
            "creating" or "starting" or "stopping" or "booting" or "shutting_down" => VirtualMachineOperationalState.Transitional,
            "error" or "failed" or "crashed" => VirtualMachineOperationalState.Error,
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
