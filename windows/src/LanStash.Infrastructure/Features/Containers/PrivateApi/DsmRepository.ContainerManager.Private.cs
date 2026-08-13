using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Container Manager 内部 v1 隐私白名单只读适配器。
/// 仅发送已记录的 list 请求，不保留路径、账号、日志正文或原始诊断字段。
/// </summary>
public sealed partial class DsmRepository
{
    private const int InternalObservedContainerVersion = 1;
    private const int ContainerSectionLimit = 200;
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

    async Task<ContainerManagerSnapshot> IContainerManagerRepository.LoadSnapshotAsync(
        CancellationToken cancellationToken)
    {
        var availability = InternalObservedContainerAvailability;
        if (availability.Status != ContainerManagerAvailabilityStatus.InternalObserved)
        {
            return UnavailableContainerManagerSnapshot();
        }
        EnsureContainerManagerProfile();

        var containers = await LoadContainerSectionAsync(
            InternalObservedContainerApi,
            new Dictionary<string, string>
            {
                ["offset"] = "0",
                ["limit"] = ContainerSectionLimit.ToString(CultureInfo.InvariantCulture),
                ["type"] = "all",
            },
            ParseInternalObservedContainers,
            cancellationToken).ConfigureAwait(false);
        var images = await LoadContainerResourceSectionAsync(
            InternalObservedImageApi,
            ContainerResourceKind.Image,
            ["images", "image", "data", "list"],
            ["id", "image_id", "Id"],
            ["repository", "repo", "name"],
            cancellationToken).ConfigureAwait(false);
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
        var events = await LoadContainerSectionAsync(
            InternalObservedEventApi,
            new Dictionary<string, string>
            {
                ["offset"] = "0",
                ["limit"] = ContainerSectionLimit.ToString(CultureInfo.InvariantCulture),
            },
            ParseContainerEvents,
            cancellationToken).ConfigureAwait(false);

        return new(_profile.Id, containers, images, networks, projects, events);
    }

    private ContainerManagerSnapshot UnavailableContainerManagerSnapshot() => new(
        _profile.Id,
        ContainerManagerSection<ContainerSummary>.Unavailable,
        ContainerManagerSection<ContainerResourceSummary>.Unavailable,
        ContainerManagerSection<ContainerResourceSummary>.Unavailable,
        ContainerManagerSection<ContainerResourceSummary>.Unavailable,
        ContainerManagerSection<ServiceEventSummary>.Unavailable);

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
            parameters: null,
            data => ParseContainerResources(data, kind, roots, idKeys, nameKeys),
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
        var capability = _capabilities[apiName] with
        {
            MinVersion = InternalObservedContainerVersion,
            MaxVersion = InternalObservedContainerVersion,
        };
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
        capability.MinVersion <= InternalObservedContainerVersion &&
        capability.MaxVersion >= InternalObservedContainerVersion;

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
        var containers = new List<ContainerSummary>(Math.Min(source.Count, ContainerSectionLimit));
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in source.Take(ContainerSectionLimit))
        {
            var id = RequiredContainerString(item, "id");
            if (!ids.Add(id))
            {
                throw InvalidContainerManagerResponse();
            }
            containers.Add(new(
                id,
                RequiredContainerString(item, "name"),
                ParseContainerState(RequiredContainerString(item, "status")),
                OptionalContainerString(item, "image")));
        }
        return containers;
    }

    private static IReadOnlyList<ContainerResourceSummary> ParseContainerResources(
        JsonObject data,
        ContainerResourceKind kind,
        string[] roots,
        string[] idKeys,
        string[] nameKeys)
    {
        var source = RequiredContainerObjectArray(data, roots);
        var resources = new List<ContainerResourceSummary>(Math.Min(source.Count, ContainerSectionLimit));
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in source.Take(ContainerSectionLimit))
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
                ParseContainerState(FirstContainerString(item, "status", "state"))));
        }
        return resources;
    }

    private static IReadOnlyList<ServiceEventSummary> ParseContainerEvents(JsonObject data)
    {
        var source = RequiredContainerObjectArray(data, ["logs", "events", "data", "list"]);
        var events = new List<ServiceEventSummary>(Math.Min(source.Count, ContainerSectionLimit));
        var ids = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in source.Take(ContainerSectionLimit).Select((item, index) => (item, index)))
        {
            var occurredAt = FirstContainerDate(entry.item);
            var id = FirstContainerString(entry.item, "id", "log_id") ??
                $"event-{occurredAt?.ToUnixTimeSeconds() ?? 0}-{entry.index}";
            if (!ids.Add(id))
            {
                throw InvalidContainerManagerResponse();
            }
            events.Add(new(
                id,
                occurredAt,
                ParseServiceEventLevel(FirstContainerString(
                    entry.item,
                    "level",
                    "severity",
                    "type",
                    "priority"))));
        }
        return events;
    }

    private static List<JsonObject> RequiredContainerObjectArray(JsonObject data, string[] roots)
    {
        var array = roots.Select(root => data[root]).OfType<JsonArray>().FirstOrDefault()
            ?? throw InvalidContainerManagerResponse();
        var result = new List<JsonObject>(Math.Min(array.Count, ContainerSectionLimit));
        foreach (var node in array.Take(ContainerSectionLimit))
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
