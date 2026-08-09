using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

/// <summary>
/// Container Manager 内部、仅观察级证据的实例清单适配器。
/// 只允许 SYNO.Docker.Container.list v1，不提供任何管理操作。
/// </summary>
public sealed partial class DsmRepository
{
    private const string InternalObservedContainerApi = "SYNO.Docker.Container";
    private const int InternalObservedContainerVersion = 1;

    private bool HasInternalObservedContainerContract =>
        _capabilities.TryGetValue(InternalObservedContainerApi, out var capability) &&
        capability.MinVersion <= InternalObservedContainerVersion &&
        capability.MaxVersion >= InternalObservedContainerVersion;

    ContainerManagerAvailability IContainerManagerRepository.Availability => new(
        HasInternalObservedContainerContract
            ? ContainerManagerAvailabilityStatus.InternalObserved
            : ContainerManagerAvailabilityStatus.Unavailable);

    async Task<ContainerManagerSnapshot> IContainerManagerRepository.LoadSnapshotAsync(
        CancellationToken cancellationToken)
    {
        if (!HasInternalObservedContainerContract)
        {
            return new(_profile.Id, []);
        }
        if (_profile.Id != _session.ProfileId)
        {
            throw new InvalidOperationException(
                "Container Manager requests require a session for the active NAS profile.");
        }

        var capability = _capabilities[InternalObservedContainerApi] with
        {
            MinVersion = InternalObservedContainerVersion,
            MaxVersion = InternalObservedContainerVersion,
        };
        var data = await _api.CallAsync(
            _profile,
            _session,
            capability,
            "list",
            new Dictionary<string, string>
            {
                ["offset"] = "0",
                ["limit"] = "-1",
                ["type"] = "all",
            },
            cancellationToken).ConfigureAwait(false);
        return new(_profile.Id, ParseInternalObservedContainers(data));
    }

    private static IReadOnlyList<ContainerSummary> ParseInternalObservedContainers(JsonObject data)
    {
        if (data["containers"] is not JsonArray source)
        {
            throw InvalidContainerManagerResponse();
        }

        var containers = new ContainerSummary[source.Count];
        var ids = new HashSet<string>(StringComparer.Ordinal);
        for (var index = 0; index < source.Count; index++)
        {
            if (source[index] is not JsonObject item)
            {
                throw InvalidContainerManagerResponse();
            }
            var id = RequiredContainerString(item, "id");
            var name = RequiredContainerString(item, "name");
            var status = RequiredContainerString(item, "status");
            var image = OptionalContainerString(item, "image");
            if (!ids.Add(id))
            {
                throw InvalidContainerManagerResponse();
            }
            containers[index] = new(
                id,
                name,
                ParseContainerState(status),
                image);
        }
        return containers;
    }

    private static string RequiredContainerString(JsonObject item, string key)
    {
        if (item[key] is not JsonValue value ||
            !value.TryGetValue<string>(out var text) ||
            string.IsNullOrWhiteSpace(text))
        {
            throw InvalidContainerManagerResponse();
        }
        return text.Trim();
    }

    private static string? OptionalContainerString(JsonObject item, string key)
    {
        if (item[key] is null)
        {
            return null;
        }
        return RequiredContainerString(item, key);
    }

    private static ContainerOperationalState ParseContainerState(string status) =>
        status.Trim().ToLowerInvariant() switch
        {
            "running" => ContainerOperationalState.Running,
            "stopped" => ContainerOperationalState.Stopped,
            "error" => ContainerOperationalState.Attention,
            _ => ContainerOperationalState.Unknown,
        };

    private static DsmException InvalidContainerManagerResponse() => new(
        UserText.Key("WinShared11a208e43c34b77c"),
        UserText.Key("WinShared2580b8992c005ea7"));
}
