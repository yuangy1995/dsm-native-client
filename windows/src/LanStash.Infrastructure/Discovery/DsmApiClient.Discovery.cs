using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    public async Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
        NasProfile profile,
        CancellationToken cancellationToken = default) =>
        await DiscoverAsync(
            profile,
            DsmConnectionSource.DirectAddress,
            cancellationToken).ConfigureAwait(false);

    public async Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
        NasProfile profile,
        DsmConnectionSource source,
        CancellationToken cancellationToken = default)
    {
        var data = await PostAsync(
            profile,
            "/webapi/query.cgi",
            new Dictionary<string, string>
            {
                ["api"] = "SYNO.API.Info",
                ["version"] = "1",
                ["method"] = "query",
                ["query"] = "all",
            },
            session: null,
            source: source,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var result = new Dictionary<string, ApiCapability>(StringComparer.Ordinal);
        foreach (var (name, node) in data)
        {
            if (node is not JsonObject value ||
                value["path"]?.GetValue<string>() is not { Length: > 0 } path)
            {
                continue;
            }
            var minVersion = value["minVersion"]?.GetValue<int>() ?? 1;
            var maxVersion = value["maxVersion"]?.GetValue<int>() ?? minVersion;
            result[name] = new ApiCapability(
                name,
                path,
                minVersion,
                maxVersion,
                value["requestFormat"]?.GetValue<string>() ?? "FORM");
        }
        return result;
    }
}
