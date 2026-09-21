using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const string InternalObservedRegistryApi = "SYNO.Docker.Registry";
    public bool CanBrowseRegistry => HasInternalObservedContainerVersion(InternalObservedRegistryApi);

    // 内部只读 v1；仅搜索首批结果，不自动访问第三方仓库或猜测分页契约。
    public async Task<IReadOnlyList<ContainerRegistryImage>> SearchRegistryAsync(string query, CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile(); cancellationToken.ThrowIfCancellationRequested();
        if (!ContainerRegistryRules.IsValidQuery(query)) throw new ArgumentException("container.registry.query.invalid", nameof(query));
        EnsureRegistryCapability();
        var data = await CallInternalObservedContainerAsync(InternalObservedRegistryApi, "search", new Dictionary<string, string>
        { ["offset"] = "0", ["limit"] = "50", ["page_size"] = "50", ["q"] = query.Trim() }, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        var rows = RegistryArray(data, "data", "items", "results", DsmApiResponseKeys.RootArray);
        if (rows.Count > ContainerRegistryRules.SearchLimit) throw InvalidContainerManagerResponse();
        var result = new List<ContainerRegistryImage>(); var seen = new HashSet<(string Registry, string Name)>();
        foreach (var node in rows)
        {
            if (node is not JsonObject row) throw InvalidContainerManagerResponse();
            var name = NativeNetworkString(row, "name", "repository", "repo");
            if (!ContainerRegistryRules.IsValidRepository(name)) throw InvalidContainerManagerResponse();
            var registry = row["registry"] is null ? "docker.io" : NativeNetworkString(row, "registry");
            if (string.IsNullOrWhiteSpace(registry)) throw InvalidContainerManagerResponse();
            var description = row["description"] is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
            var image = new ContainerRegistryImage(name!.Trim(), registry.Trim(), description,
                RegistryStars(row), RegistryFlag(row, "is_official", "official"), RegistryFlag(row, "is_automated", "automated"), RegistryFlag(row, "is_trusted", "trusted"));
            if (seen.Add((image.Registry, image.Name))) result.Add(image);
        }
        return result.AsReadOnly();
    }
    public async Task<IReadOnlyList<string>> LoadRegistryTagsAsync(string repository, CancellationToken cancellationToken = default)
    {
        EnsureContainerManagerProfile(); cancellationToken.ThrowIfCancellationRequested();
        if (!ContainerRegistryRules.IsValidRepository(repository)) throw new ArgumentException("container.registry.repository.invalid", nameof(repository));
        EnsureRegistryCapability();
        var data = await CallInternalObservedContainerAsync(InternalObservedRegistryApi, "tags", new Dictionary<string, string> { ["repo"] = repository.Trim() }, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        var result = new List<string>(); var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var node in RegistryArray(data, "data", "tags", "items", DsmApiResponseKeys.RootArray))
        {
            var tag = node is JsonObject row ? NativeNetworkString(row, "tag", "name") :
                node is JsonValue scalar && scalar.TryGetValue<string>(out var text) ? text : null;
            if (string.IsNullOrWhiteSpace(tag) || tag.Any(char.IsControl)) throw InvalidContainerManagerResponse();
            if (seen.Add(tag.Trim())) result.Add(tag.Trim());
        }
        return result.AsReadOnly();
    }
    private void EnsureRegistryCapability()
    {
        if (!CanBrowseRegistry) throw new DsmException(UserText.Key("ContainerRegistryUnavailable"), UserText.Key("ContainerRegistryUnavailable"), 102);
    }
    private static JsonArray RegistryArray(JsonObject data, params string[] roots)
    {
        JsonArray? result = null;
        foreach (var key in roots.Where(data.ContainsKey))
        {
            if (data[key] is not JsonArray array || result is not null && !JsonNode.DeepEquals(result, array)) throw InvalidContainerManagerResponse();
            result = array;
        }
        return result ?? throw InvalidContainerManagerResponse();
    }
    private static bool? RegistryFlag(JsonObject row, params string[] keys)
    {
        bool? result = null;
        foreach (var key in keys.Where(row.ContainsKey))
        {
            if (row[key] is not JsonValue scalar || !scalar.TryGetValue<bool>(out var flag) || result is not null && result != flag) return null;
            result = flag;
        }
        return result;
    }
    private static long? RegistryStars(JsonObject row)
    {
        long? result = null;
        foreach (var key in new[] { "star_count", "stars" }.Where(row.ContainsKey))
        {
            if (row[key] is not JsonValue scalar) return null;
            long value;
            if (!scalar.TryGetValue<long>(out value) && !(scalar.TryGetValue<string>(out var text) && long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out value))) return null;
            if (value < 0 || result is not null && result != value) return null;
            result = value;
        }
        return result;
    }
}
