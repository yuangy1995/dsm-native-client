using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository(
    NasProfile profile,
    DsmSession session,
    IDsmApiClient api,
    IReadOnlyDictionary<string, ApiCapability> capabilities) : IDsmRepository, IFilePreviewRepository, IFileShareLinkRepository, IFileLocationsRepository, IPhotoRepository, IChatRepository, IDownloadStationRepository, IVirtualMachineManagerRepository, IContainerManagerRepository
{
    private readonly NasProfile _profile = profile;
    private readonly DsmSession _session = session;
    private readonly IDsmApiClient _api = api;
    private readonly IReadOnlyDictionary<string, ApiCapability> _capabilities = capabilities;

    public Guid ProfileId => _profile.Id;

    public IReadOnlyList<AppModule> AvailableModules =>
    [
        AppModule.Files,
        AppModule.Photos,
        .. (HasReadableChatContract
            ? new[] { AppModule.Chat }
            : Array.Empty<AppModule>()),
        .. (HasReadablePublicDownloadStationContract
            ? new[] { AppModule.Downloads }
            : Array.Empty<AppModule>()),
        .. (HasInternalObservedContainerContract
            ? new[] { AppModule.Containers }
            : Array.Empty<AppModule>()),
        .. (HasReadablePublicVirtualMachineManagerContract
            ? new[] { AppModule.VirtualMachines }
            : Array.Empty<AppModule>()),
        .. (Supports("SYNO.Core.System")
            ? new[] { AppModule.NasSettings }
            : Array.Empty<AppModule>()),
        AppModule.Transfers,
        AppModule.Settings,
    ];

    private async Task<IReadOnlyList<ResourceItem>> LoadResourcesAsync(
        string apiName,
        string root,
        CancellationToken cancellationToken)
    {
        if (!Supports(apiName))
        {
            return [];
        }
        var data = await CallFirstAsync(
            apiName,
            ["list", "get"],
            parameters: null,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        return ParseResources(data, root, "items");
    }

    private async Task<IReadOnlyList<ResourceItem>> TryLoadResourcesAsync(
        string apiName,
        string root,
        CancellationToken cancellationToken)
    {
        try
        {
            return await LoadResourcesAsync(apiName, root, cancellationToken).ConfigureAwait(false);
        }
        catch (DsmException)
        {
            return [];
        }
    }

    private async Task<JsonObject> CallFirstAsync(
        string apiName,
        IReadOnlyList<string> methods,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken)
    {
        DsmException? lastError = null;
        foreach (var method in methods)
        {
            try
            {
                return await CallAsync(apiName, method, parameters, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (DsmException error) when (error.Code is 102 or 103)
            {
                lastError = error;
            }
        }
        throw lastError ?? new DsmException(
            UserText.Key("WinShared11a208e43c34b77c"),
            UserText.Key("WinShared2580b8992c005ea7"));
    }

    private async Task<JsonObject?> TryCallFirstAsync(
        string? apiName,
        IReadOnlyList<string> methods,
        CancellationToken cancellationToken)
    {
        if (apiName is null || !Supports(apiName))
        {
            return null;
        }
        try
        {
            return await CallFirstAsync(
                apiName,
                methods,
                parameters: null,
                cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (DsmException)
        {
            return null;
        }
    }

    private Task<JsonObject> CallAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken)
    {
        if (!_capabilities.TryGetValue(apiName, out var capability))
        {
            throw new DsmException(
                UserText.Key("WinShared11a208e43c34b77c"),
                UserText.Key("WinShared371d84f48836296f"),
                102);
        }
        return _api.CallAsync(
            _profile,
            _session,
            capability,
            method,
            parameters,
            cancellationToken);
    }

    private async Task CallVoidAsync(
        string apiName,
        string method,
        IReadOnlyDictionary<string, string>? parameters,
        CancellationToken cancellationToken) =>
        _ = await CallAsync(apiName, method, parameters, cancellationToken).ConfigureAwait(false);

    private static async Task WaitUntilAsync(
        Func<Task<bool>> predicate,
        string failureMessage,
        CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < 8; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (await predicate().ConfigureAwait(false))
            {
                return;
            }
            await Task.Delay(TimeSpan.FromMilliseconds(500), cancellationToken).ConfigureAwait(false);
        }
        throw new DsmException(
            failureMessage,
            UserText.Key("WinShared4470548cdf9d51c2"));
    }

}

public sealed partial class DsmRepository
{
    private static IReadOnlyList<ResourceItem> ParseResources(
        JsonObject data,
        params string[] roots)
    {
        var nodes = roots.SelectMany(data.Array).OfType<JsonObject>();
        return nodes.Select((item, index) =>
        {
            var id = item.String("id")
                ?? item.String("uuid")
                ?? item.String("name")
                ?? $"item-{index}";
            var name = item.String("name")
                ?? item.String("title")
                ?? item.String("guest_name")
                ?? item.String("repo")
                ?? id;
            var status = item.String("status") ?? item.String("state") ?? item.String("health");
            var metadata = item
                .Where(pair => pair.Value is JsonValue)
                .ToDictionary(
                    pair => pair.Key,
                    pair => pair.Value?.ToJsonString().Trim('"') ?? string.Empty,
                    StringComparer.Ordinal);
            return new ResourceItem(
                id,
                name,
                status ?? item.String("description") ?? string.Empty,
                ParseState(status),
                metadata);
        }).DistinctBy(item => item.Id).ToArray();
    }

    private static IReadOnlyList<LogEntry> ParseLogs(JsonObject data) =>
        new[] { "logs", "log", "events", "records", "entries", "items", "data", "list" }
            .SelectMany(data.Array)
            .OfType<JsonObject>()
            .Select((item, index) => new LogEntry(
                item.String("id") ?? item.String("log_id") ?? $"log-{index}",
                item.String("level")
                    ?? item.String("severity")
                    ?? item.String("type")
                    ?? item.String("priority")
                    ?? "unknown",
                item.Date("time")
                    ?? item.Date("timestamp")
                    ?? item.Date("date")
                    ?? item.Date("event_time")
                    ?? item.Date("create_time")
                    ?? item.Date("created_at"),
                item.String("user")
                    ?? item.String("username")
                    ?? item.String("owner")
                    ?? item.String("account")
                    ?? item.String("user_name")
                    ?? "SYSTEM",
                item.String("event")
                    ?? item.String("message")
                    ?? item.String("description")
                    ?? item.String("msg")
                    ?? item.String("content")
                    ?? item.String("detail")
                    ?? string.Empty))
            .Where(item => !string.IsNullOrWhiteSpace(item.Event))
            .DistinctBy(item => item.Id)
            .ToArray();

    private static ResourceState ParseState(string? value)
    {
        var state = value?.ToLowerInvariant() ?? string.Empty;
        if (state is "running" or "started" or "online" or "active" or "downloading" or "seeding")
        {
            return ResourceState.Running;
        }
        if (state is "stopped" or "shutdown" or "offline" or "inactive" or "finished")
        {
            return ResourceState.Stopped;
        }
        if (state is "paused" or "suspended")
        {
            return ResourceState.Paused;
        }
        if (state is "waiting" or "pending" or "creating" or "starting" or "stopping")
        {
            return ResourceState.Waiting;
        }
        if (state is "healthy" or "normal" or "good")
        {
            return ResourceState.Healthy;
        }
        if (state.Contains("warn", StringComparison.Ordinal) ||
            state.Contains("degrad", StringComparison.Ordinal))
        {
            return ResourceState.Warning;
        }
        if (state.Contains("error", StringComparison.Ordinal) ||
            state.Contains("fail", StringComparison.Ordinal) ||
            state.Contains("critical", StringComparison.Ordinal))
        {
            return ResourceState.Error;
        }
        return ResourceState.Unknown;
    }

    private static void ValidateName(string name)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        if (name.Contains('/'))
        {
            throw new ArgumentException(UserText.Key("WinSharedfa9066ff052e7270"), nameof(name));
        }
    }

    private bool Supports(string apiName) => _capabilities.ContainsKey(apiName);

    private ApiCapability Required(string apiName) =>
        _capabilities.TryGetValue(apiName, out var capability)
            ? capability
            : throw new DsmException(
                UserText.Key("WinShared11a208e43c34b77c"),
                UserText.Key("WinShared371d84f48836296f"),
                102);

    private string Preferred(params string[] names) =>
        names.FirstOrDefault(Supports)
        ?? throw new DsmException(
            UserText.Key("WinShared11a208e43c34b77c"),
            UserText.Key("WinShared371d84f48836296f"),
            102);

    private string? PreferredOptional(params string[] names) => names.FirstOrDefault(Supports);
}

internal static class JsonExtensions
{
    public static string? String(this JsonObject value, string key) =>
        value[key] is JsonValue node && node.TryGetValue<string>(out var result) ? result : null;

    public static int? Int(this JsonObject value, string key) =>
        value[key] is JsonValue node
            ? node.TryGetValue<int>(out var result)
                ? result
                : int.TryParse(node.ToString().Trim('"'), out result)
                    ? result
                    : null
            : null;

    public static long? Long(this JsonObject value, string key) =>
        value[key] is JsonValue node
            ? node.TryGetValue<long>(out var result)
                ? result
                : long.TryParse(node.ToString().Trim('"'), out result)
                    ? result
                    : null
            : null;

    public static bool? Bool(this JsonObject value, string key) =>
        value[key] is JsonValue node
            ? node.TryGetValue<bool>(out var result)
                ? result
                : node.ToString().Trim('"').ToLowerInvariant() switch
                {
                    "1" or "true" => true,
                    "0" or "false" => false,
                    _ => null,
                }
            : null;

    public static DateTimeOffset? Date(this JsonObject value, string key)
    {
        var epoch = value.Long(key);
        if (epoch is not null)
        {
            return epoch > 10_000_000_000
                ? DateTimeOffset.FromUnixTimeMilliseconds(epoch.Value)
                : DateTimeOffset.FromUnixTimeSeconds(epoch.Value);
        }
        var text = value.String(key);
        return DateTimeOffset.TryParse(text, out var result) ? result : null;
    }

    public static JsonObject? Object(this JsonObject value, string key) =>
        value[key] as JsonObject;

    public static IEnumerable<JsonNode?> Array(this JsonObject value, string key) =>
        value[key] as JsonArray ?? [];
}
