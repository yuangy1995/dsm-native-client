using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Container Manager 内部 v1 隐私白名单只读适配器。
/// 仅发送已记录的 list 请求；常规清单不保留日志正文，正文只由活动页显式读取。
/// </summary>
public sealed partial class DsmRepository
{
    private const int InternalObservedContainerVersion = 1;
    private const int ContainerLogPageSize = 1000;
    private const string InternalObservedContainerApi = "SYNO.Docker.Container";
    private const string InternalObservedImageApi = "SYNO.Docker.Image";
    private const string InternalObservedNetworkApi = "SYNO.Docker.Network";
    private const string InternalObservedProjectApi = "SYNO.Docker.Project";
    private const string InternalObservedEventApi = "SYNO.Docker.Log";

    private bool HasInternalObservedContainerContract =>
        HasInternalObservedContainerVersion(InternalObservedContainerApi);

    ContainerManagerAvailability IContainerManagerRepository.Availability =>
        InternalObservedContainerAvailability;

    private ContainerManagerAvailability InternalObservedContainerAvailability
    {
        get
        {
            if (!HasInternalObservedContainerContract)
            {
                return new(
                    ContainerManagerAvailabilityStatus.Unavailable,
                    new HashSet<ContainerManagerReadFeature>());
            }

            var features = new HashSet<ContainerManagerReadFeature>
            {
                ContainerManagerReadFeature.Containers,
            };
            AddInternalContainerFeature(features, InternalObservedImageApi, ContainerManagerReadFeature.Images);
            AddInternalContainerFeature(features, InternalObservedNetworkApi, ContainerManagerReadFeature.Networks);
            AddInternalContainerFeature(features, InternalObservedProjectApi, ContainerManagerReadFeature.Projects);
            AddInternalContainerFeature(features, InternalObservedEventApi, ContainerManagerReadFeature.Events);
            return new(ContainerManagerAvailabilityStatus.InternalObserved, features);
        }
    }

    Task<ContainerManagerSnapshot> IContainerManagerRepository.LoadSnapshotAsync(CancellationToken cancellationToken) =>
        LoadContainerSnapshotAsync(includeActivity: true, cancellationToken);
    Task<ContainerManagerSnapshot> IContainerManagerRepository.LoadInventoryAsync(CancellationToken cancellationToken) =>
        LoadContainerSnapshotAsync(includeActivity: false, cancellationToken);
    Task<ContainerManagerSection<ServiceActivityEntry>> IContainerManagerRepository.LoadActivityAsync(CancellationToken cancellationToken) =>
        LoadContainerActivityAsync(includeBody: true, cancellationToken);
    private async Task<ContainerManagerSnapshot> LoadContainerSnapshotAsync(bool includeActivity, CancellationToken cancellationToken)
    {
        var availability = InternalObservedContainerAvailability;
        if (availability.Status != ContainerManagerAvailabilityStatus.InternalObserved)
        {
            return UnavailableContainerManagerSnapshot();
        }
        EnsureContainerManagerProfile();

        JsonObject? containerData = null;
        var containers = await LoadContainerSectionAsync(
            InternalObservedContainerApi,
            new Dictionary<string, string>
            {
                ["offset"] = "0",
                ["limit"] = "-1",
                ["type"] = "all",
            },
            data => { containerData = data; return ParseInternalObservedContainers(data); },
            cancellationToken).ConfigureAwait(false);
        var images = await LoadContainerResourceSectionAsync(
            InternalObservedImageApi,
            ContainerResourceKind.Image,
            ["images", "image", "data", "list"],
            ["id", "image_id", "Id"],
            ["repository", "repo", "name"],
            cancellationToken).ConfigureAwait(false);
        if (containers.Status == ContainerManagerSectionStatus.Available && containerData is not null &&
            images.Status == ContainerManagerSectionStatus.Available)
        {
            try
            {
                var used = ContainerImageUsage(images.Items, containerData);
                images = ContainerManagerSection<ContainerResourceSummary>.Available(images.Items.Select(item =>
                    item with { IsImageInUse = item.Image is null ? null : used.Contains(item.Id) }).ToArray());
            }
            catch (DsmException)
            {
                // 占用字段不能完整解释时仅隐藏使用状态；删除仍执行严格的实时预检。
            }
        }
        var networks = await LoadContainerResourceSectionAsync(
            InternalObservedNetworkApi,
            ContainerResourceKind.Network,
            ["networks", "network", "data", "list"],
            ["id", "network_id", "Id"],
            ["name", "Name"],
            cancellationToken).ConfigureAwait(false);
        var projects = await LoadContainerResourceSectionAsync(
            InternalObservedProjectApi,
            ContainerResourceKind.Project,
            ["projects", "project", "data", "list"],
            ["id", "project_id", "name", "project_name"],
            ["name", "project_name", "id"],
            cancellationToken).ConfigureAwait(false);
        var activity = includeActivity ? await LoadContainerActivityAsync(includeBody: false, cancellationToken).ConfigureAwait(false) :
            new ContainerManagerSection<ServiceActivityEntry>(HasInternalObservedContainerVersion(InternalObservedEventApi) ?
                ContainerManagerSectionStatus.Available : ContainerManagerSectionStatus.Unavailable, []);
        var events = new ContainerManagerSection<ServiceEventSummary>(activity.Status, activity.Items.Select(item => item.Summary).ToArray());

        return new(_profile.Id, containers, images, networks, projects, events);
    }

    private ContainerManagerSnapshot UnavailableContainerManagerSnapshot() => new(
        _profile.Id,
        ContainerManagerSection<ContainerSummary>.Unavailable,
        ContainerManagerSection<ContainerResourceSummary>.Unavailable,
        ContainerManagerSection<ContainerResourceSummary>.Unavailable,
        ContainerManagerSection<ContainerResourceSummary>.Unavailable,
        ContainerManagerSection<ServiceEventSummary>.Unavailable);

    // 同一分页器用于活动正文和兼容摘要；生产清单读取不请求日志。
    private async Task<ContainerManagerSection<ServiceActivityEntry>> LoadContainerActivityAsync(bool includeBody, CancellationToken cancellationToken)
    {
        EnsureContainerManagerProfile();
        if (!HasInternalObservedContainerVersion(InternalObservedEventApi))
            return ContainerManagerSection<ServiceActivityEntry>.Unavailable;
        var events = new List<ServiceActivityEntry>();
        var ids = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var offset = events.Count;
                var data = await CallInternalObservedContainerAsync(InternalObservedEventApi, "list",
                    new Dictionary<string, string>
                    {
                        ["action"] = "load", ["offset"] = offset.ToString(CultureInfo.InvariantCulture),
                        ["limit"] = ContainerLogPageSize.ToString(CultureInfo.InvariantCulture),
                        ["sort_by"] = "time", ["sort_dir"] = "DESC", ["loglevel"] = "",
                        ["filter_content"] = "", ["datefrom"] = "0", ["dateto"] = "0",
                    }, cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested();
                if (ContainerPageNumber(data, "offset") is { } returnedOffset && returnedOffset != offset)
                    throw InvalidContainerManagerResponse();
                var total = ContainerPageNumber(data, "total");
                var page = ParseServiceActivity(RequiredContainerObjectArray(data, ["logs", "events", "data", "list"]), offset, includeBody);
                if (page.Count > ContainerLogPageSize || page.Any(item => !ids.Add(item.Summary.Id)))
                    throw InvalidContainerManagerResponse();
                events.AddRange(page);
                if (total is null || events.Count == total) return ContainerManagerSection<ServiceActivityEntry>.Available(events);
                if (events.Count > total || page.Count == 0) throw InvalidContainerManagerResponse();
            }
        }
        catch (DsmException error) when (!IsMutationAuthenticationFailure(error))
        {
            return ContainerManagerSection<ServiceActivityEntry>.Failed;
        }
        catch (HttpRequestException) { return ContainerManagerSection<ServiceActivityEntry>.Failed; }
    }

    private static int? ContainerPageNumber(JsonObject data, string key)
    {
        if (!data.ContainsKey(key)) return null;
        if (data[key] is JsonValue value && value.TryGetValue<int>(out var number) && number >= 0) return number;
        throw InvalidContainerManagerResponse();
    }

    private async Task<ContainerManagerSection<ContainerResourceSummary>>
        LoadContainerResourceSectionAsync(
            string apiName,
            ContainerResourceKind kind,
            string[] roots,
            string[] idKeys,
            string[] nameKeys,
            CancellationToken cancellationToken)
    {
        if (!HasInternalObservedContainerVersion(apiName))
        {
            return ContainerManagerSection<ContainerResourceSummary>.Unavailable;
        }
        return await LoadContainerSectionAsync(
            apiName,
            parameters: kind == ContainerResourceKind.Image ? new Dictionary<string, string>
                { ["offset"] = "0", ["limit"] = "-1", ["show_dsm"] = "false" } : null,
            data =>
            {
                if (kind == ContainerResourceKind.Image) return ParseContainerImages(data);
                var items = kind == ContainerResourceKind.Project ? ParseContainerProjects(data, roots, idKeys, nameKeys) :
                    ParseContainerResources(data, kind, roots, idKeys, nameKeys);
                return items;
            },
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<ContainerManagerSection<T>> LoadContainerSectionAsync<T>(
        string apiName,
        IReadOnlyDictionary<string, string>? parameters,
        Func<JsonObject, IReadOnlyList<T>> parse,
        CancellationToken cancellationToken)
    {
        if (!HasInternalObservedContainerVersion(apiName))
        {
            return ContainerManagerSection<T>.Unavailable;
        }
        try
        {
            var data = await CallInternalObservedContainerAsync(
                apiName,
                "list",
                parameters,
                cancellationToken).ConfigureAwait(false);
            return ContainerManagerSection<T>.Available(parse(data));
        }
        catch (DsmException error) when (!IsMutationAuthenticationFailure(error))
        {
            return ContainerManagerSection<T>.Failed;
        }
    }

    private Task<JsonObject> CallInternalObservedContainerAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var capability = _capabilities[apiName] with
        {
            MinVersion = InternalObservedContainerVersion,
            MaxVersion = InternalObservedContainerVersion,
        };
        // 已记录的分页/日期字段为数字，show_dsm 为布尔；其余业务参数为字符串。
        // FORM 原样发送；JSON 声明与 macOS 一样编码字符串，不改变数字类型。
        if (capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase) && parameters is not null)
            parameters = parameters.ToDictionary(pair => pair.Key,
                pair => pair.Key is "offset" or "limit" or "page_size" or "datefrom" or "dateto" or "show_dsm"
                    ? pair.Value : JsonSerializer.Serialize(pair.Value), StringComparer.Ordinal);
        return _api.CallAsync(
            _profile,
            _session,
            capability,
            method,
            parameters,
            cancellationToken);
    }

    private bool HasInternalObservedContainerVersion(string apiName) =>
        _capabilities.TryGetValue(apiName, out var capability) &&
        capability.Name == apiName && capability.MinVersion >= 1 && capability.MinVersion <= InternalObservedContainerVersion &&
        capability.MaxVersion >= InternalObservedContainerVersion &&
        (capability.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) ||
         capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase));

    private void AddInternalContainerFeature(
        HashSet<ContainerManagerReadFeature> features,
        string apiName,
        ContainerManagerReadFeature feature)
    {
        if (HasInternalObservedContainerVersion(apiName))
        {
            features.Add(feature);
        }
    }

    private void EnsureContainerManagerProfile()
    {
        if (_profile.Id != _session.ProfileId)
        {
            throw new InvalidOperationException(
                "Container Manager requests require a session for the active NAS profile.");
        }
    }

    private static IReadOnlyList<ContainerSummary> ParseInternalObservedContainers(JsonObject data)
    {
        var source = RequiredContainerObjectArray(data, ["containers"]);
        var containers = new List<ContainerSummary>(source.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in source)
        {
            var id = RequiredContainerString(item, "id");
            var status = RequiredContainerString(item, "status");
            if (!ids.Add(id))
            {
                throw InvalidContainerManagerResponse();
            }
            containers.Add(new(
                id,
                RequiredContainerString(item, "name"),
                item["State"] is JsonObject runtime && runtime["Restarting"] is JsonValue marker && marker.TryGetValue<bool>(out var restarting) && restarting
                    ? ContainerOperationalState.Restarting : ParseContainerState(status),
                OptionalContainerString(item, "image")));
        }
        return containers;
    }

    // Project.list 的官方空响应是 {}；仅该分区接受以项目 ID 为键的对象。
    private static IReadOnlyList<ContainerResourceSummary> ParseContainerProjects(
        JsonObject data, string[] roots, string[] idKeys, string[] nameKeys)
    {
        if (roots.Concat(new[] { "result", "items" }).Any(data.ContainsKey))
            return ParseContainerResources(data, ContainerResourceKind.Project, roots, idKeys, nameKeys);
        return data.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair =>
        {
            if (string.IsNullOrWhiteSpace(pair.Key) || pair.Value is not JsonObject item)
                throw InvalidContainerManagerResponse();
            return new ContainerResourceSummary(pair.Key,
                FirstContainerString(item, nameKeys) ?? throw InvalidContainerManagerResponse(),
                ContainerResourceKind.Project, ParseContainerState(FirstContainerString(item, "status", "state")))
                { ProjectContainerCount = ContainerProjectCount(item) };
        }).ToArray();
    }

    private static IReadOnlyList<ContainerResourceSummary> ParseContainerResources(
        JsonObject data,
        ContainerResourceKind kind,
        string[] roots,
        string[] idKeys,
        string[] nameKeys)
    {
        var source = RequiredContainerObjectArray(data, roots);
        var resources = new List<ContainerResourceSummary>(source.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in source)
        {
            var id = FirstContainerString(item, idKeys) ?? throw InvalidContainerManagerResponse();
            var name = FirstContainerString(item, nameKeys) ?? throw InvalidContainerManagerResponse();
            if (!ids.Add(id))
            {
                throw InvalidContainerManagerResponse();
            }
            resources.Add(new(
                id,
                name,
                kind,
                ParseContainerState(FirstContainerString(item, "status", "state")))
                {
                    Network = kind == ContainerResourceKind.Network ? ParseContainerNetworkDetails(item) : null,
                    ProjectContainerCount = kind == ContainerResourceKind.Project ? ContainerProjectCount(item) : null,
                });
        }
        return resources;
    }

    private static int? ContainerProjectCount(JsonObject item)
    {
        if (item.ContainsKey("containerIds")) return item["containerIds"] is JsonArray ids ? ids.Count : null;
        var count = OptionalContainerNonnegativeInteger(item, "container_count", "services");
        return count is >= 0 and <= int.MaxValue ? (int)count.Value : null;
    }

    private static ContainerNetworkDetails ParseContainerNetworkDetails(JsonObject item)
    {
        IReadOnlyList<string>? names = null; int count;
        if (item.ContainsKey("containers"))
        {
            if (item["containers"] is not JsonArray array) throw InvalidContainerManagerResponse();
            var parsed = new List<string>();
            foreach (var node in array)
            {
                if (node is not JsonValue scalar || !scalar.TryGetValue<string>(out var name) ||
                    string.IsNullOrWhiteSpace(name) || name.Length > 256 || name.Any(char.IsControl)) throw InvalidContainerManagerResponse();
                parsed.Add(name);
            }
            names = parsed.AsReadOnly(); count = parsed.Count;
        }
        else
        {
            var values = new[] { "container_count", "containers_count", "using" }.Where(item.ContainsKey)
                .Select(key => NetworkCount(item[key])).ToArray();
            if (values.Length == 0 || values.Distinct().Count() != 1) throw InvalidContainerManagerResponse();
            count = values[0];
        }
        var driver = NetworkText(item["driver"] ?? item["Driver"] ?? item["type"]);
        if (driver?.Any(c => !(char.IsLetterOrDigit(c) || "_.-".Contains(c))) == true) driver = null;
        bool? ipv6 = item["enable_ipv6"] is JsonValue boolean && boolean.TryGetValue<bool>(out var enabled) ? enabled : null;
        return new(driver, count, names, NetworkAddress(item["subnet"], true), NetworkAddress(item["gateway"], false), NetworkAddress(item["iprange"], true), ipv6);
    }
    private static int NetworkCount(JsonNode? node)
    {
        if (node is JsonValue scalar)
        {
            if (scalar.TryGetValue<int>(out var number) && number >= 0) return number;
            if (scalar.TryGetValue<decimal>(out var real) && real == decimal.Truncate(real) && real is >= 0 and <= int.MaxValue) return (int)real;
            if (scalar.TryGetValue<string>(out var text) && int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed)) return parsed;
        }
        throw InvalidContainerManagerResponse();
    }
    private static string? NetworkText(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) &&
        !string.IsNullOrWhiteSpace(text) && text.Length <= 256 && !text.Any(char.IsControl) ? text.Trim() : null;
    private static string? NetworkAddress(JsonNode? node, bool permitsPrefix)
    {
        var text = NetworkText(node); if (text is null) return null;
        var parts = text.Split('/');
        if (parts.Length > (permitsPrefix ? 2 : 1) || !IPAddress.TryParse(parts[0], out var address)) return null;
        if (parts[0].Contains('%') || address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork && parts[0].Split('.').Length != 4) return null;
        if (parts.Length == 2 && (!int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var prefix) ||
            prefix > (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork ? 32 : 128))) return null;
        return text;
    }

    private static IReadOnlyList<ServiceActivityEntry> ParseServiceActivity(IReadOnlyList<JsonObject> source, int offset, bool includeBody)
    {
        var events = new List<ServiceActivityEntry>(source.Count);
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in source.Select((item, index) => (item, index)))
        {
            var occurredAt = FirstContainerDate(entry.item);
            var id = FirstContainerString(entry.item, "id", "log_id") ??
                $"event-{occurredAt?.ToUnixTimeSeconds() ?? 0}-{checked(offset + entry.index)}";
            if (!ids.Add(id))
            {
                throw InvalidContainerManagerResponse();
            }
            DateTime? localTime = null;
            if (includeBody)
            {
                var time = FirstContainerString(entry.item, "time", "timestamp", "date", "event_time", "create_time", "created_at");
                if (time is not null && !long.TryParse(time, NumberStyles.Integer, CultureInfo.InvariantCulture, out _) &&
                    !time.EndsWith('Z') && !time.EndsWith('z') && time.LastIndexOf('+') <= 9 && time.LastIndexOf('-') <= 9)
                    occurredAt = null;
                if (time is not null && DateTime.TryParseExact(time, ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss.FFFFFFF", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF"],
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out var local))
                { localTime = DateTime.SpecifyKind(local, DateTimeKind.Unspecified); occurredAt = null; }
            }
            var summary = new ServiceEventSummary(
                id,
                occurredAt,
                ParseServiceEventLevel(FirstContainerString(
                    entry.item,
                    "level",
                    "severity",
                    "type",
                    "priority")));
            var message = includeBody ? ActivityText(entry.item, "event", "message", "description", "msg", "content", "detail") ?? throw InvalidContainerManagerResponse() : "";
            var account = includeBody ? ActivityText(entry.item, "user", "username", "owner", "account", "user_name") : null;
            events.Add(new(summary, message, account, localTime));
        }
        return events;
    }
    private static string? ActivityText(JsonObject row, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (row[key] is null) continue;
            if (row[key] is JsonValue value && value.TryGetValue<string>(out var text)) return text;
            throw InvalidContainerManagerResponse();
        }
        return null;
    }

    private static List<JsonObject> RequiredContainerObjectArray(JsonObject data, string[] roots)
    {
        var array = roots.Select(root => data[root]).OfType<JsonArray>().FirstOrDefault()
            ?? throw InvalidContainerManagerResponse();
        var result = new List<JsonObject>(array.Count);
        foreach (var node in array)
        {
            if (node is not JsonObject item)
            {
                throw InvalidContainerManagerResponse();
            }
            result.Add(item);
        }
        return result;
    }

    private static string RequiredContainerString(JsonObject item, string key) =>
        FirstContainerString(item, key) ?? throw InvalidContainerManagerResponse();

    private static string? OptionalContainerString(JsonObject item, string key)
    {
        if (item[key] is null)
        {
            return null;
        }
        return RequiredContainerString(item, key);
    }

    private static string? FirstContainerString(JsonObject item, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (item[key] is not JsonValue value)
            {
                continue;
            }
            if (value.TryGetValue<string>(out var text) && !string.IsNullOrWhiteSpace(text))
            {
                return text.Trim();
            }
            if (value.TryGetValue<long>(out var number))
            {
                return number.ToString(CultureInfo.InvariantCulture);
            }
        }
        return null;
    }

    private static DateTimeOffset? FirstContainerDate(JsonObject item) =>
        item.Date("time") ?? item.Date("timestamp") ?? item.Date("date") ??
        item.Date("event_time") ?? item.Date("create_time") ?? item.Date("created_at");

    private static ContainerOperationalState ParseContainerState(string? status) =>
        status?.Trim().ToLowerInvariant() switch
        {
            "running" or "online" or "healthy" or "normal" => ContainerOperationalState.Running,
            "stopped" or "offline" => ContainerOperationalState.Stopped,
            "restarting" => ContainerOperationalState.Restarting,
            "error" or "failed" or "warning" or "degraded" => ContainerOperationalState.Attention,
            _ => ContainerOperationalState.Unknown,
        };

    private static ServiceEventLevel ParseServiceEventLevel(string? level) =>
        level?.Trim().ToLowerInvariant() switch
        {
            "info" or "information" or "0" => ServiceEventLevel.Information,
            "warning" or "warn" or "1" => ServiceEventLevel.Warning,
            "error" or "err" or "2" => ServiceEventLevel.Error,
            _ => ServiceEventLevel.Unknown,
        };

    private static DsmException InvalidContainerManagerResponse() => new(
        UserText.Key("WinShared11a208e43c34b77c"),
        UserText.Key("WinShared2580b8992c005ea7"));
}
