using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmApiClient
{
    private static async Task<JsonObject> ReadMutationEnvelopeAsync(
        HttpResponseMessage response, CancellationToken cancellationToken)
    {
        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        return await JsonNode.ParseAsync(stream, cancellationToken: cancellationToken)
            .ConfigureAwait(false) as JsonObject ?? throw new JsonException();
    }

    private static int MutationErrorCode(JsonObject envelope) =>
        envelope["error"] is JsonObject error &&
        TryGetNativeInt32(error, "code", out var code) && code >= 0
            ? code : throw new JsonException();

    private static MutationErrorCategory MutationCategory(int code) => code switch
    {
        105 => MutationErrorCategory.Permission,
        106 or 107 or 119 or 401 => MutationErrorCategory.Authentication,
        400 or 408 or 900 or 1805 => MutationErrorCategory.Conflict,
        _ => MutationErrorCategory.Server,
    };

    private static bool TryGetNativeBoolean(JsonObject value, string name, out bool result)
    {
        result = default;
        return value[name] is JsonValue node && node.TryGetValue(out result);
    }

    private static bool TryGetNativeInt32(JsonObject value, string name, out int result)
    {
        result = default;
        return value[name] is JsonValue node && node.TryGetValue(out result);
    }

    private static DsmException InvalidReadEnvelope() => new(
        UserText.Key("WinShared9cb9ec075b03b6cb"),
        UserText.Key("WinShared09f262a53ad074ca"));
}
