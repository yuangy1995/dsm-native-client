using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 对齐 macOS 已有投票只读映射；无法解析的附加投票不掩盖普通消息正文。
    private static ChatPoll? ParseChatPoll(JsonObject message, string messageId)
    {
        JsonObject? Decode(JsonNode? value)
        {
            if (value is JsonObject obj) return obj;
            if (value is JsonValue text && text.TryGetValue<string>(out var json))
            {
                try { return JsonNode.Parse(json) as JsonObject; }
                catch (JsonException) { return null; }
            }
            return null;
        }
        var poll = Decode(message["vote"] ?? message["poll"] ?? message["vote_info"]);
        if (poll is null) return null;
        var raw = poll["choices"] as JsonArray ?? poll["options"] as JsonArray;
        if (raw is null || raw.Count == 0) return null;
        var options = new List<ChatPollOption>();
        foreach (var node in raw)
        {
            var item = node as JsonObject;
            var text = item is not null ? FirstNonEmpty(item, "choice", "text", "name", "title")
                : node is JsonValue value && value.TryGetValue<string>(out var label) ? label : null;
            if (string.IsNullOrWhiteSpace(text)) return null;
            var count = item is null ? 0 : FirstLong(item, "vote_count", "count", "votes") ?? 0;
            if (count is < 0 or > int.MaxValue) return null;
            options.Add(new(item is null ? $"{messageId}-choice-{options.Count}"
                : FirstStableId(item, "choice_id", "option_id", "id") ?? $"{messageId}-choice-{options.Count}",
                text, (int)count, item is null ? null : FirstBool(item, "selected", "is_selected", "is_voted", "voted")));
        }
        var settings = Decode(poll["options"]) ?? poll;
        var question = FirstNonEmpty(poll, "message", "question", "title") ?? FirstNonEmpty(message, "message", "text", "content");
        if (question is null) return null;
        return new(FirstStableId(poll, "vote_id", "poll_id", "id") ?? messageId, question,
            FirstBool(settings, "multiple", "allow_multiple") ?? false,
            FirstBool(settings, "anonymous", "is_anonymous") ?? false,
            FirstDate(settings, "expire_at", "close_at", "closes_at"), FirstBool(poll, "closed", "is_closed", "expired") ?? false, options);
    }
}
