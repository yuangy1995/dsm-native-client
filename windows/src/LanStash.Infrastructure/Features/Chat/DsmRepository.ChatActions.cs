using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int ChatActionVersion = 5;
    public Task<ChatMessage> GetMessageAsync(string conversationId, string messageId, CancellationToken cancellationToken = default) =>
        FindActionMessageAsync(conversationId, messageId, cancellationToken);

    async Task<MutationResult> IChatRepository.CloseConversationAsync(ChatCloseConversationRequest request, CancellationToken token) =>
        (await ExecuteAdvancedChatAsync(request.ClientRequestId, "closeConversation", new { request.ConversationId },
            "SYNO.Chat.Channel", request.ConversationId, null, request.ConversationId,
            async (_, ct) => { await AdvancedChatCallAsync("SYNO.Chat.Channel", ChatActionVersion, "close", [("channel_id", request.ConversationId)], ct).ConfigureAwait(false); },
            async (_, ct) => (!(await LoadChatConversationsAsync(requireComplete: true, ct).ConfigureAwait(false)).Any(item => item.Id == request.ConversationId), null),
            token, requiredVersion: ChatActionVersion, allowMissingConversation: true, allowEncryptedConversation: true).ConfigureAwait(false)).Result;

    public async Task<MutationResult> SetMessagePinnedAsync(ChatPinMessageRequest request, CancellationToken token = default)
    {
        var expected = request.ExpectedMessage is { } baseline ? ActionMessageFingerprint(baseline) : null;
        var expectedPin = request.ExpectedPin is { } pinBaseline ? PinFingerprint(pinBaseline) : null;
        return (await ExecuteAdvancedChatAsync(request.ClientRequestId, "setMessagePinned",
            new { request.ConversationId, request.MessageId, request.IsPinned, expected, expectedPin }, "SYNO.Chat.Post",
            request.ConversationId, request.MessageId, request.MessageId,
            async (_, ct) => { await AdvancedChatCallAsync("SYNO.Chat.Post", ChatActionVersion, request.IsPinned ? "pin" : "unpin", [("post_id", request.MessageId)], ct).ConfigureAwait(false); },
            async (state, ct) =>
            {
                if (!state.Submitted)
                {
                    var group = (await ListConversationsAsync(ct).ConfigureAwait(false)).SingleOrDefault(item => item.Id == request.ConversationId);
                    if (group is not { Kind: ChatConversationKind.Group, IsEncrypted: false }) throw new AdvancedChatPermissionException();
                    var message = await FindActionMessageAsync(request.ConversationId, request.MessageId, ct).ConfigureAwait(false);
                    if (expected is not null && expected != ActionMessageFingerprint(message)) throw new AdvancedChatTargetChangedException();
                }
                var payload = await ReadAllPinnedPayloadAsync(request.ConversationId, ct).ConfigureAwait(false);
                var target = payload.SingleOrDefault(item => FirstStableId(item, "post_id", "id") == request.MessageId);
                if (target is not null && FirstLong(target, "last_pin_at", "pinned_at") is null) throw InvalidChatResponse();
                var pinned = target is not null && FirstLong(target, "last_pin_at", "pinned_at") > 0;
                if (!state.Submitted && pinned && expectedPin is not null &&
                    (ParsePinnedMessage(target!, request.ConversationId) is not { } current || PinFingerprint(current) != expectedPin))
                    throw new AdvancedChatTargetChangedException();
                return (pinned == request.IsPinned, null);
            }, token, requiredVersion: ChatActionVersion).ConfigureAwait(false)).Result;
    }

    async Task<MutationResult> IChatRepository.ForwardMessageAsync(ChatForwardRequest request, CancellationToken token)
    {
        if (!HasReadableChatContract || !HasAdvancedApi("SYNO.Chat.Post", ChatActionVersion)) return ChatUnsupported("forwardMessage");
        var targets = request.TargetConversationIds.Select(id => id.Trim()).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray();
        var numericTargets = new List<long>();
        foreach (var id in targets)
        {
            if (!long.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out var numeric) || numeric <= 0 || id == request.SourceConversationId)
                return ChatFailure("forwardMessage", "chat.forward.invalid-targets");
            numericTargets.Add(numeric);
        }
        if (targets.Length == 0 || numericTargets.Distinct().Count() != targets.Length) return ChatFailure("forwardMessage", "chat.forward.invalid-targets");
        var expected = request.ExpectedMessage is { } baseline ? ActionMessageFingerprint(baseline) : null;
        return (await ExecuteAdvancedChatAsync(request.ClientRequestId, "forwardMessage",
            new { request.MessageId, request.SourceConversationId, targets, expected }, "SYNO.Chat.Post",
            // 未确认转发按来源消息隔离，改变接收人不能绕过旧提交的防重保护。
            request.SourceConversationId, request.MessageId, request.MessageId,
            async (_, ct) => { await AdvancedChatCallAsync("SYNO.Chat.Post", ChatActionVersion, "forward", [("post_id", request.MessageId), ("channel_ids", numericTargets.ToArray())], ct).ConfigureAwait(false); },
            async (state, ct) =>
            {
                if (!state.Submitted)
                {
                    var conversations = await ListConversationsAsync(ct).ConfigureAwait(false);
                    if (targets.Any(id => !conversations.Any(item => item.Id == id && !item.IsEncrypted))) throw new AdvancedChatPermissionException();
                    var source = await FindActionMessageAsync(request.SourceConversationId, request.MessageId, ct).ConfigureAwait(false);
                    if (source.Poll is not null || (string.IsNullOrWhiteSpace(source.Text) && source.Attachments.Count == 0)) throw new AdvancedChatPermissionException();
                    if (expected is not null && expected != ActionMessageFingerprint(source)) throw new AdvancedChatTargetChangedException();
                    state.PayloadFingerprint = ForwardPayloadFingerprint(source);
                    foreach (var target in targets)
                    {
                        var page = await ListMessagesAsync(target, null, 100, ct).ConfigureAwait(false);
                        state.DestinationBaselines[target] = page.Messages.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
                    }
                    return (false, null);
                }
                foreach (var target in targets)
                {
                    if (state.ConfirmedDestinations.Contains(target)) continue;
                    var page = await ListMessagesAsync(target, null, 100, ct).ConfigureAwait(false);
                    var matches = page.Messages.Where(item => item.ConversationId == target && item.IsFromCurrentUser == true &&
                        item.EncryptionState == ChatEncryptionState.NotEncrypted && item.Poll is null &&
                        !state.DestinationBaselines[target].Contains(item.Id) &&
                        Math.Abs((item.SentAt - state.SubmittedAt).TotalSeconds) <= 180 &&
                        ForwardPayloadFingerprint(item) == state.PayloadFingerprint).ToArray();
                    if (matches.Length == 1) state.ConfirmedDestinations.Add(target);
                }
                return (targets.All(state.ConfirmedDestinations.Contains), null);
            }, token, requiredVersion: ChatActionVersion).ConfigureAwait(false)).Result;
    }

    private async Task<ChatMessage> FindActionMessageAsync(string conversationId, string messageId, CancellationToken token) =>
        await FindActionMessageOrNullAsync(conversationId, messageId, token).ConfigureAwait(false) ?? throw new AdvancedChatPermissionException();

    private async Task<ChatMessage?> FindActionMessageOrNullAsync(string conversationId, string messageId, CancellationToken token)
    {
        string? cursor = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var verifiedIds = new HashSet<string>(StringComparer.Ordinal);
        do
        {
            var page = await ListMessagesCoreAsync(conversationId, cursor, 100, token, verifiedIds, messageId).ConfigureAwait(false);
            var message = page.Messages.SingleOrDefault(item => item.Id == messageId && item.ConversationId == conversationId);
            if (message is not null)
                return message.EncryptionState == ChatEncryptionState.NotEncrypted ? message : throw new AdvancedChatPermissionException();
            if (!page.HasMoreBefore) return null;
            if (page.PreviousCursor is null || !seen.Add(page.PreviousCursor)) throw InvalidChatResponse();
            cursor = page.PreviousCursor;
        } while (true);
    }

    private static string ForwardPayloadFingerprint(ChatMessage message) => AdvancedFingerprint(new
    {
        message.Text,
        attachments = message.Attachments.Select(item => new { item.Kind, item.FileName, item.SizeBytes }).ToArray(),
    });
    private static string PinFingerprint(ChatPinnedMessage message) => AdvancedFingerprint(new
    { message.Id, message.ConversationId, message.SenderId, message.SentAt, message.PinnedAt, message.Text });
    private static string ActionMessageFingerprint(ChatMessage message) => AdvancedFingerprint(new
    {
        message.Id, message.ConversationId, message.SenderId, message.SentAt, message.EncryptionState,
        payload = ForwardPayloadFingerprint(message), poll = message.Poll is { } poll
            ? new { poll.Question, Options = poll.Options.Select(option => option.Text).ToArray() } : null,
    });

    private async Task<IReadOnlyList<JsonObject>> ReadAllPinnedPayloadAsync(string conversationId, CancellationToken token)
    {
        EnsureReadableChatContract();
        var rows = new List<JsonObject>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        while (true)
        {
            var data = await AdvancedChatCallAsync("SYNO.Chat.Post", ChatActionVersion, "search",
                [("channel_id", conversationId), ("offset", rows.Count), ("limit", 100), ("has", new[] { "pin" }),
                 ("sort_by", "last_pin_at"), ("sort_by_array", new[] { "is_sticky", "last_pin_at" })], token).ConfigureAwait(false);
            var raw = data["search_results"] as JsonArray ?? data["posts"] as JsonArray ?? throw InvalidChatResponse();
            if (raw.Count > 100) throw InvalidChatResponse();
            foreach (var node in raw)
            {
                var item = node as JsonObject ?? throw InvalidChatResponse();
                RequireAdvancedOwner(item, conversationId);
                var id = FirstStableId(item, "post_id", "id") ?? throw InvalidChatResponse();
                if (!seen.Add(id)) throw InvalidChatResponse();
                rows.Add(item);
            }
            if (raw.Count < 100) return rows;
        }
    }
}
