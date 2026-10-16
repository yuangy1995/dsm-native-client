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
                    state.OwnerId = _chatCurrentUserId ?? throw InvalidChatResponse();
                    state.PayloadFingerprint = ForwardPayloadFingerprint(source);
                    foreach (var target in targets)
                    {
                        var page = await ListMessagesAsync(target, null, 100, ct).ConfigureAwait(false);
                        state.DestinationBaselines[target] = page.Messages.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
                        state.DestinationLatest[target] = page.Messages.Select(item => (DateTimeOffset?)item.SentAt).Max();
                    }
                    return (false, null);
                }
                if (!state.Accepted) return (false, null);
                var currentConversations = await ListConversationsAsync(ct).ConfigureAwait(false);
                if (state.OwnerId is null || state.OwnerId != _chatCurrentUserId) return (false, null);
                foreach (var target in targets)
                {
                    if (state.ConfirmedDestinations.Contains(target)) continue;
                    if (!currentConversations.Any(item => item.Id == target && !item.IsEncrypted)) continue;
                    try
                    {
                        if (await ConfirmForwardDestinationAsync(state, target, ct).ConfigureAwait(false)) state.ConfirmedDestinations.Add(target);
                    }
                    catch (OperationCanceledException) { throw; }
                    catch { /* 单个目标失败保留其他目标的独立确认，下次只读继续。 */ }
                }
                return (targets.All(state.ConfirmedDestinations.Contains), null);
            }, token, requiredVersion: ChatActionVersion).ConfigureAwait(false)).Result;
    }

    private async Task<bool> ConfirmForwardDestinationAsync(AdvancedChatOperation state, string target, CancellationToken token)
    {
        string? cursor = null;
        var cursors = new HashSet<string>(StringComparer.Ordinal); var ids = new HashSet<string>(StringComparer.Ordinal);
        var matches = new HashSet<string>(StringComparer.Ordinal);
        var latest = state.DestinationLatest[target];
        var earliest = state.SubmittedAt.AddSeconds(-180);
        if (latest > earliest) earliest = latest.Value;
        while (true)
        {
            var page = await ListMessagesAsync(target, cursor, 100, token).ConfigureAwait(false);
            foreach (var item in page.Messages)
            {
                if (!ids.Add(item.Id)) throw InvalidChatResponse();
                if (item.ConversationId == target && item.SenderId == state.OwnerId && item.IsFromCurrentUser == true &&
                    item.EncryptionState == ChatEncryptionState.NotEncrypted && item.Poll is null && !item.IsThreadReply &&
                    item.Kind == ChatMessageKind.Normal && !state.DestinationBaselines[target].Contains(item.Id) &&
                    Math.Abs((item.SentAt - state.SubmittedAt).TotalSeconds) <= 180 && (latest is null || item.SentAt > latest) &&
                    ForwardPayloadFingerprint(item) == state.PayloadFingerprint) matches.Add(item.Id);
            }
            if (matches.Count > 1) return false;
            if (!page.HasMoreBefore || page.Messages.Any(item => item.SentAt < earliest)) return matches.Count == 1;
            if (page.PreviousCursor is null || !cursors.Add(page.PreviousCursor)) throw InvalidChatResponse();
            cursor = page.PreviousCursor;
        }
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
        message.Kind, message.ThreadId, message.EditedAt,
        payload = ForwardPayloadFingerprint(message), poll = message.Poll is { } poll
            ? new { poll.Question, Options = poll.Options.Select(option => option.Text).ToArray() } : null,
    });

    private async Task<IReadOnlyList<JsonObject>> ReadAllPinnedPayloadAsync(string conversationId, CancellationToken token)
    {
        EnsureReadableChatContract();
        if (!long.TryParse(conversationId, NumberStyles.None, CultureInfo.InvariantCulture, out var channelId) || channelId <= 0)
            throw InvalidChatResponse();
        var rows = new List<JsonObject>();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        while (true)
        {
            var data = await AdvancedChatCallAsync("SYNO.Chat.Post", ChatActionVersion, "search",
                [("in", new[] { channelId }), ("offset", rows.Count), ("limit", 100), ("has", new[] { "pin" }),
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
