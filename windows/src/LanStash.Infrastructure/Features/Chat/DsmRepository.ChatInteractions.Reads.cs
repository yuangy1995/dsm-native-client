using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private string? _chatCurrentUserId;
    private readonly ConcurrentDictionary<(string Conversation, string Message), ChatMessage> _knownChatMessages = new();

    private string? ReadChatCurrentUserId(JsonObject data)
    {
        // 账号字段可以确定本人；昵称和显示名永远不参与权限判断。
        var ids = new HashSet<string>(StringComparer.Ordinal);
        if (FirstStableId(data, "current_user_id", "login_user_id", "my_user_id") is { } declared) ids.Add(declared);
        foreach (var row in ContainerObjects(data, "users", "user", "user_list", "list", "members", "items", "results"))
        {
            if (FirstBool(row, "is_login", "is_current", "is_current_user") == true ||
                string.Equals(FirstNonEmpty(row, "username", "account_name", "account"), _profile.Username, StringComparison.OrdinalIgnoreCase))
            {
                if (FirstStableId(row, "user_id", "member_id", "uid", "account_id", "id") is { } id) ids.Add(id);
            }
        }
        _chatCurrentUserId = null;
        if (ids.Count > 1) throw InvalidChatResponse();
        return _chatCurrentUserId = ids.SingleOrDefault();
    }

    public async Task<ChatSearchPage> SearchMessagesAsync(string query, string? conversationId, string? cursor, int limit,
        CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        var keyword = query.Trim();
        if (keyword.Length == 0) return new([], null, 0);
        if (keyword.Contains('\0') || limit < 1 || (cursor is not null &&
            (!int.TryParse(cursor, NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) || parsed < 0)))
            throw new ArgumentException("chat.search.invalid");
        var offset = cursor is null ? 0 : int.Parse(cursor, CultureInfo.InvariantCulture);
        var size = Math.Min(limit, 100);
        var conversations = await ListConversationsAsync(cancellationToken).ConfigureAwait(false);
        long[] channels = [];
        if (conversationId is not null)
        {
            if (!long.TryParse(conversationId, NumberStyles.None, CultureInfo.InvariantCulture, out var channel) || channel <= 0)
                throw new ArgumentException("chat.search.channel");
            if (!conversations.Any(value => value.Id == conversationId && !value.IsEncrypted)) throw new AdvancedChatPermissionException();
            channels = [channel];
        }
        var data = await AdvancedChatCallAsync("SYNO.Chat.Post", 5, "search",
            [("keyword", keyword), ("in", channels), ("offset", offset), ("limit", size)], cancellationToken).ConfigureAwait(false);
        if (data["search_results"] is not JsonArray rows || rows.Count > size ||
            FirstInt(data, "total") is not { } total || total < 0 || offset > int.MaxValue - rows.Count)
            throw InvalidChatResponse();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var messages = new List<ChatMessage>();
        foreach (var row in rows)
        {
            if (row is not JsonObject item || FirstStableId(item, "channel_id") is not { } channel ||
                (conversationId is not null && channel != conversationId) ||
                ParseMessage(item, channel) is not { } message || !seen.Add(message.Id)) throw InvalidChatResponse();
            if (message.EncryptionState == ChatEncryptionState.NotEncrypted &&
                conversations.Any(value => value.Id == channel && !value.IsEncrypted)) messages.Add(message);
        }
        var next = offset + rows.Count;
        if ((rows.Count == 0 && offset < total) || next > total) throw InvalidChatResponse();
        return new(messages, next < total ? next.ToString(CultureInfo.InvariantCulture) : null, total);
    }

    public async Task<ChatMessage?> LocateMessageAsync(string conversationId, string messageId, string? threadId = null,
        CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        if (!ValidAdvancedId(conversationId) || !ValidAdvancedId(messageId) ||
            threadId is not null && !ValidAdvancedId(threadId)) throw new ArgumentException("chat.locate.invalid");
        var data = await AdvancedChatCallAsync("SYNO.Chat.Post", 5, "list",
            [("channel_id", conversationId), ("post_id", messageId), ("thread_id", threadId ?? "0"),
                ("prev_count", 0), ("next_count", 0)], cancellationToken).ConfigureAwait(false);
        if (data["posts"] is not JsonArray rows || rows.Count > 1) throw InvalidChatResponse();
        if (rows.Count == 0) return null;
        if (rows[0] is not JsonObject item || ParseMessage(item, conversationId) is not { } message ||
            message.Id != messageId || message.ConversationId != conversationId ||
            (threadId is null ? message.IsThreadReply : message.Id != threadId && message.ThreadId != threadId))
            throw InvalidChatResponse();
        if (message.EncryptionState != ChatEncryptionState.NotEncrypted) throw new AdvancedChatPermissionException();
        return message;
    }

    public async Task<ChatMessagePage> ListRepliesAsync(string conversationId, string threadId, string? beforeCursor, int limit,
        CancellationToken cancellationToken = default)
    {
        if (!ValidAdvancedId(threadId) || threadId == "0") throw new ArgumentException("chat.thread.invalid");
        return await ListMessagesCoreAsync(conversationId, beforeCursor, limit, cancellationToken,
            threadId: threadId).ConfigureAwait(false);
    }

    public async Task<ChatEditingPolicy> GetEditingPolicyAsync(CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        var data = await AdvancedChatCallAsync("SYNO.Chat.Admin.Setting", 3, "get", [], cancellationToken).ConfigureAwait(false);
        if (FirstBool(data, "allow_edit_message") is not { } allows ||
            data["allow_edit_message_time_within_min"] is not JsonValue raw ||
            !raw.TryGetValue<double>(out var minutes) || !double.IsFinite(minutes) || minutes < 0 ||
            minutes > TimeSpan.MaxValue.TotalMinutes) throw InvalidChatResponse();
        return new(allows, minutes == 0 ? null : TimeSpan.FromMinutes(minutes));
    }

    public async Task<ChatMessage> GetPollMessageAsync(ChatMessage original, CancellationToken cancellationToken = default)
    {
        await RequireAdvancedConversationAsync(original.ConversationId, null, cancellationToken).ConfigureAwait(false);
        var current = await LocateMessageAsync(original.ConversationId, original.Id, original.ThreadId, cancellationToken).ConfigureAwait(false)
            ?? throw new AdvancedChatTargetChangedException();
        return await ReadChatPollChoicesAsync(current, cancellationToken).ConfigureAwait(false);
    }

    private async Task<ChatMessage> ReadChatPollChoicesAsync(ChatMessage message, CancellationToken token)
    {
        if (message.Poll is not { HasStableOptionIds: true } poll || _chatCurrentUserId is not { } user)
            throw InvalidChatResponse();
        var data = await AdvancedChatCallAsync("SYNO.Chat.Post.Vote", 1, "get_choices", [("post_id", message.Id)], token).ConfigureAwait(false);
        if (data["choices"] is not JsonArray rows || rows.Count != poll.Options.Count) throw InvalidChatResponse();
        var values = new Dictionary<string, (int Count, bool Selected)>(StringComparer.Ordinal);
        foreach (var raw in rows)
        {
            if (raw is not JsonObject row || FirstStableId(row, "id") is not { } id ||
                FirstInt(row, "count") is not { } count || count < 0 || row["voters"] is not JsonArray voters ||
                voters.Any(value => StableId(value) is null) || !values.TryAdd(id, (count, voters.Any(value => StableId(value) == user))))
                throw InvalidChatResponse();
        }
        if (poll.Options.Any(option => !values.ContainsKey(option.Id))) throw InvalidChatResponse();
        var updated = message with { Poll = poll with { Options = poll.Options.Select(option => option with
            { VoteCount = values[option.Id].Count, IsSelectedByCurrentUser = values[option.Id].Selected }).ToArray() } };
        _knownChatMessages[(message.ConversationId, message.Id)] = updated;
        return updated;
    }

    public async Task<ChatConversation> MarkReadAsync(string conversationId, string messageId, DateTimeOffset through,
        CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        if (!_knownChatMessages.TryGetValue((conversationId, messageId), out var visible) || visible.IsThreadReply ||
            visible.EncryptionState != ChatEncryptionState.NotEncrypted || visible.SentAt != through || through <= DateTimeOffset.UnixEpoch)
            throw new ArgumentException("chat.read.unseen-message");
        await RequireAdvancedConversationAsync(conversationId, null, cancellationToken).ConfigureAwait(false);
        await AdvancedChatCallAsync("SYNO.Chat.Channel", 2, "view",
            [("channel_id", conversationId), ("last_view_at", through.ToUnixTimeMilliseconds())], cancellationToken).ConfigureAwait(false);
        var updated = (await ListConversationsAsync(cancellationToken).ConfigureAwait(false)).SingleOrDefault(value => value.Id == conversationId);
        if (updated?.LastViewedAt is not { } viewed || viewed < through) throw InvalidChatResponse();
        return updated;
    }

    public async Task MarkThreadReadAsync(string conversationId, string threadId, string lastMessageId,
        CancellationToken cancellationToken = default)
    {
        EnsureReadableChatContract();
        if (!_knownChatMessages.TryGetValue((conversationId, lastMessageId), out var visible) ||
            !visible.IsThreadReply || visible.ThreadId != threadId || visible.EncryptionState != ChatEncryptionState.NotEncrypted)
            throw new ArgumentException("chat.read.unseen-thread");
        await RequireAdvancedConversationAsync(conversationId, null, cancellationToken).ConfigureAwait(false);
        var latest = await ListRepliesAsync(conversationId, threadId, null, 1, cancellationToken).ConfigureAwait(false);
        if (latest.Messages.LastOrDefault()?.Id != lastMessageId) throw new AdvancedChatTargetChangedException();
        await AdvancedChatCallAsync("SYNO.Chat.Post.Subscribe", 2, "view",
            [("channel_id", conversationId), ("thread_id", threadId)], cancellationToken).ConfigureAwait(false);
    }
}
