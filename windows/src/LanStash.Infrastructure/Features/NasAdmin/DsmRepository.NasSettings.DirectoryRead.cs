using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<IReadOnlyList<NasDirectoryEntry>> LoadDirectoryAsync(NasDirectoryKind kind, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var capability = DirectoryCapability(kind) ?? throw new DsmException(UserText.Key("NasSettingsLoadError"), UserText.Key("NasSettingsUnavailable"), 102);
        var user = kind == NasDirectoryKind.User;
        var additional = user ? new[] { "uid", "description", "email", "expired", "groups", "can_edit", "can_delete" } :
            new[] { "gid", "description", "can_edit", "can_delete" };
        var data = await _api.CallReadJsonObjectAsync(_profile, _session, capability, 1, "list", new Dictionary<string, string>
        { ["offset"] = "0", ["limit"] = "1000", ["additional"] = JsonSerializer.Serialize(additional) }, cancellationToken).ConfigureAwait(false);
        if (data[user ? "users" : "groups"] is not JsonArray rows || rows.Count >= 1000) throw InvalidNasServiceSettings();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase); var result = new List<NasDirectoryEntry>();
        foreach (var node in rows)
        {
            if (node is not JsonObject row) throw InvalidNasServiceSettings();
            var name = DirectoryText(row["name"]);
            if (!StableDirectoryName(name) || !seen.Add(name!)) throw InvalidNasServiceSettings();
            var extra = row["additional"] is null ? null : row["additional"] as JsonObject ?? throw InvalidNasServiceSettings();
            JsonNode? Field(string key)
            {
                var direct = row[key]; var nested = extra?[key];
                if (direct is not null && nested is not null && !JsonNode.DeepEquals(direct, nested)) throw InvalidNasServiceSettings();
                return nested ?? direct;
            }
            var numeric = Field(user ? "uid" : "gid");
            long? id = numeric is null ? null : numeric is JsonValue scalar && scalar.TryGetValue<long>(out var value) && value >= 0 ? value : throw InvalidNasServiceSettings();
            var membership = user ? Field("groups") : null;
            IReadOnlyList<string>? groups = null;
            if (membership is not null)
            {
                if (membership is not JsonArray array) throw InvalidNasServiceSettings();
                var names = array.Select(item => DirectoryText(item)).ToArray();
                if (names.Any(item => !StableDirectoryName(item)) || names.Distinct(StringComparer.OrdinalIgnoreCase).Count() != names.Length) throw InvalidNasServiceSettings();
                groups = Array.AsReadOnly(names.Select(item => item!).ToArray());
            }
            result.Add(new(kind, name!, id, DirectoryText(Field("description")), user ? DirectoryText(Field("email")) : null,
                user ? DirectoryBoolean(Field("expired")) : null, groups, DirectoryBoolean(Field("can_edit")), DirectoryBoolean(Field("can_delete")))
            { IsCurrentAccount = user && string.Equals(name, _profile.Username, StringComparison.OrdinalIgnoreCase) });
        }
        return result.AsReadOnly();
    }
    private ApiCapability? DirectoryCapability(NasDirectoryKind kind) => Enum.IsDefined(kind)
        ? SecurityCapability(kind == NasDirectoryKind.User ? "SYNO.Core.User" : "SYNO.Core.Group", 1) : null;
    private static bool StableDirectoryName(string? name) => !string.IsNullOrWhiteSpace(name) && !name.Any(char.IsControl);
    private static string? DirectoryText(JsonNode? node) => node is null ? null : node is JsonValue scalar && scalar.TryGetValue<string>(out var value)
        ? value : throw InvalidNasServiceSettings();
    private static bool? DirectoryBoolean(JsonNode? node) => node is null ? null : node is JsonValue scalar && scalar.TryGetValue<bool>(out var value)
        ? value : throw InvalidNasServiceSettings();
}
