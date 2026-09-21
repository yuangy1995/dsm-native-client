using System.Globalization;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private bool HasBoundChatSession => _profile.Id != Guid.Empty && _profile.Id == _session.ProfileId && !string.IsNullOrWhiteSpace(_session.Sid);
    private readonly SemaphoreSlim _chatAdvancedGate = new(1, 1);
    private readonly ConcurrentDictionary<Guid, AdvancedChatOperation> _chatAdvancedOperations = new();
    // 仅保留未确认目标，不保留 Repository/会话凭据；页面或 Repository 重建后仍不能重复写。
    private static readonly ConcurrentDictionary<(Guid Profile, string Account, string Resource), AdvancedChatOperation> PendingAdvancedChat = new();

    public Task<ChatAvailability> PrepareAdvancedFeaturesAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        EnsureReadableChatContract();
        // 普通 Chat 用户不应依赖系统管理员的套件读取权限；真正写权限在每次目标预检及 NAS 回执中核对。
        return Task.FromResult(Availability);
    }

    private bool HasAdvancedApi(string name, int version = 1) =>
        _capabilities.TryGetValue(name, out var value) && value.Name == name &&
        value.MinVersion >= 1 && value.MaxVersion >= value.MinVersion && value.MinVersion <= version && value.MaxVersion >= version &&
        value.Path is "entry.cgi" or "/webapi/entry.cgi" or "webapi/entry.cgi" &&
        (value.RequestFormat.Equals("FORM", StringComparison.OrdinalIgnoreCase) || value.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase));

    private Task<JsonObject> AdvancedChatCallAsync(string api, int version, string method,
        (string Key, object Value)[] parameters, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (!HasAdvancedApi(api, version)) throw new NotSupportedException("chat.advanced.unsupported");
        var capability = _capabilities[api];
        var json = capability.RequestFormat.Equals("JSON", StringComparison.OrdinalIgnoreCase);
        var values = parameters.ToDictionary(pair => pair.Key,
            pair => !json && pair.Value is string text ? text : JsonSerializer.Serialize(pair.Value), StringComparer.Ordinal);
        return _api.CallAsync(_profile, _session, capability with { Path = "entry.cgi", MinVersion = version, MaxVersion = version }, method, values, token);
    }

    private async Task RequireAdvancedConversationAsync(string conversationId, string? messageId, CancellationToken token,
        bool allowMissing = false, bool allowEncrypted = false)
    {
        EnsureReadableChatContract();
        var conversation = (await ListConversationsAsync(token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == conversationId);
        if (conversation is null && allowMissing) return;
        if (conversation is null || (conversation.IsEncrypted && !allowEncrypted)) throw new AdvancedChatPermissionException();
        if (messageId is null) return;
        string? cursor = null;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        do
        {
            var page = await ListMessagesAsync(conversationId, cursor, 100, token).ConfigureAwait(false);
            if (page.Messages.Any(item => item.Id == messageId && item.ConversationId == conversationId && item.EncryptionState == ChatEncryptionState.NotEncrypted)) return;
            if (!page.HasMoreBefore || page.PreviousCursor is null || !seen.Add(page.PreviousCursor)) break;
            cursor = page.PreviousCursor;
        } while (true);
        throw new AdvancedChatPermissionException();
    }

    // 一个固定请求 ID 拥有一个完整操作；提交未知只能回读，不能因重试、改草稿或取消而重放。
    private async Task<(MutationResult Result, object? Value)> ExecuteAdvancedChatAsync(
        Guid requestId, string operation, object draft, string api, string conversationId, string? messageId, string resourceId,
        Func<AdvancedChatOperation, CancellationToken, Task> submit,
        Func<AdvancedChatOperation, CancellationToken, Task<(bool Confirmed, object? Value)>> readback,
        CancellationToken token, Func<bool>? stillValid = null, int requiredVersion = 1,
        bool allowMissingConversation = false, bool allowEncryptedConversation = false)
    {
        var signature = AdvancedFingerprint(new { operation, draft });
        var resource = AdvancedFingerprint(new[] { api, conversationId, resourceId });
        if (requestId == Guid.Empty || _profile.Id == Guid.Empty || _profile.Id != _session.ProfileId || string.IsNullOrWhiteSpace(_session.Sid) ||
            !ValidAdvancedId(conversationId) || string.IsNullOrWhiteSpace(resourceId) || (messageId is not null && !ValidAdvancedId(messageId)))
            return (ChatFailure(operation, "chat.advanced.invalid", MutationErrorCategory.Validation), null);
        if (!HasReadableChatContract || !HasAdvancedApi(api, requiredVersion)) return (ChatUnsupported(operation), null);
        try { await _chatAdvancedGate.WaitAsync(token).ConfigureAwait(false); }
        catch (OperationCanceledException) { return (ChatCancelled(operation), null); }
        try
        {
            if (_chatAdvancedOperations.TryGetValue(requestId, out var state))
            {
                if (state.Signature != signature) return (ChatFailure(operation, "chat.advanced.changed", MutationErrorCategory.Conflict), null);
                if (state.Terminal is { } terminal) return (terminal, state.Value);
                return await ReviewAsync(state).ConfigureAwait(false);
            }
            var pendingKey = (_profile.Id, AdvancedFingerprint(_profile.Username), resource);
            if (PendingAdvancedChat.TryGetValue(pendingKey, out var shared))
            {
                if (shared.Signature != signature) return (ChatFailure(operation, "chat.advanced.pending", MutationErrorCategory.Conflict), null);
                _chatAdvancedOperations[requestId] = shared;
                return await ReviewAsync(shared).ConfigureAwait(false);
            }
            if (stillValid?.Invoke() == false) return (ChatFailure(operation, "chat.advanced.expired", MutationErrorCategory.Validation), null);
            try
            {
                await PrepareAdvancedFeaturesAsync(token).ConfigureAwait(false);
                if (!HasBoundChatSession) return (ChatUnsupported(operation), null);
                await RequireAdvancedConversationAsync(conversationId, messageId, token, allowMissingConversation, allowEncryptedConversation).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return (ChatCancelled(operation), null); }
            catch (Exception error) { return (AdvancedFailure(operation, error, false), null); }
            state = new(signature, resource, DateTimeOffset.UtcNow);
            try
            {
                var existing = await readback(state, token).ConfigureAwait(false);
                if (existing.Confirmed)
                {
                    // 目标已由其他操作改变：没有提交，不把零写入伪装成本次成功。
                    state.Terminal = ChatFailure(operation, "chat.advanced.already-changed", MutationErrorCategory.Conflict);
                    state.Value = existing.Value;
                    _chatAdvancedOperations[requestId] = state;
                    return (state.Terminal, state.Value);
                }
            }
            catch (OperationCanceledException) { return (ChatCancelled(operation), null); }
            catch (Exception error) { return (AdvancedFailure(operation, error, false), null); }
            if (token.IsCancellationRequested) return (ChatCancelled(operation), null);
            if (stillValid?.Invoke() == false) return (ChatFailure(operation, "chat.advanced.expired", MutationErrorCategory.Validation), null);
            state.Submitting = true;
            if (!PendingAdvancedChat.TryAdd(pendingKey, state))
                return (ChatFailure(operation, "chat.advanced.pending", MutationErrorCategory.Conflict), null);
            state.Submitted = true;
            _chatAdvancedOperations[requestId] = state;
            try { await submit(state, token).ConfigureAwait(false); }
            catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
            {
                state.Terminal = AdvancedFailure(operation, error, true);
                ClearAdvancedPending(state);
                return (state.Terminal, null);
            }
            catch (OperationCanceledException) { return (ChatCancelledAfterSubmission(operation), null); }
            catch { return (ChatUnknown(operation), null); }
            finally { state.Submitting = false; }
            return await ReviewAsync(state).ConfigureAwait(false);

            async Task<(MutationResult, object?)> ReviewAsync(AdvancedChatOperation pending)
            {
                if (pending.Submitting) return (ChatUnknown(operation), null);
                try { await pending.ReviewGate.WaitAsync(token).ConfigureAwait(false); }
                catch (OperationCanceledException) { return (ChatCancelledAfterSubmission(operation), null); }
                try
                {
                    if (pending.Terminal is { } finished) return (finished, pending.Value);
                    var result = await readback(pending, token).ConfigureAwait(false);
                    if (!result.Confirmed) return (ChatUnknown(operation), null);
                    pending.Value = result.Value; pending.Terminal = ChatSuccess(operation);
                    ClearAdvancedPending(pending);
                    return (pending.Terminal, result.Value);
                }
                catch (OperationCanceledException) { return (ChatCancelledAfterSubmission(operation), null); }
                catch { return (ChatUnknown(operation), null); }
                finally { pending.ReviewGate.Release(); }
            }
        }
        finally { _chatAdvancedGate.Release(); }
    }

    private static MutationResult AdvancedFailure(string operation, Exception error, bool submitted) =>
        ChatFailure(operation, "chat.advanced.failed", error is AdvancedChatTargetChangedException ? MutationErrorCategory.Conflict :
            error is AdvancedChatPermissionException ? MutationErrorCategory.Permission : error is DsmException dsm
            ? dsm.AuthenticationFailure ? MutationErrorCategory.Authentication : dsm.Code == 105 ? MutationErrorCategory.Permission : MutationErrorCategory.Server
            : MutationErrorCategory.Network, submitted);

    private void ClearAdvancedPending(AdvancedChatOperation state) =>
        ((ICollection<KeyValuePair<(Guid, string, string), AdvancedChatOperation>>)PendingAdvancedChat)
            .Remove(new((_profile.Id, AdvancedFingerprint(_profile.Username), state.Resource), state));

    private static string AdvancedFingerprint(object value) =>
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value))));

    private static bool ValidAdvancedId(string value) => !string.IsNullOrWhiteSpace(value) && value == value.Trim() && value.IndexOfAny(['\r', '\n', '\0']) < 0;
    private static DateTimeOffset Milliseconds(DateTimeOffset value) => DateTimeOffset.FromUnixTimeMilliseconds(value.ToUnixTimeMilliseconds());
    private sealed class AdvancedChatTargetChangedException : Exception;
    private sealed class AdvancedChatPermissionException : Exception;
    private sealed class AdvancedChatOperation(string signature, string resource, DateTimeOffset submittedAt)
    {
        public string Signature { get; } = signature;
        public string Resource { get; } = resource;
        public DateTimeOffset SubmittedAt { get; } = submittedAt;
        public bool Submitted { get; set; }
        public volatile bool Submitting;
        public HashSet<string> BaselineMessageIds { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, HashSet<string>> DestinationBaselines { get; } = new(StringComparer.Ordinal);
        public HashSet<string> ConfirmedDestinations { get; } = new(StringComparer.Ordinal);
        public string? PayloadFingerprint { get; set; }
        public SemaphoreSlim ReviewGate { get; } = new(1, 1);
        public string? CandidateId { get; set; }
        private volatile MutationResult? _terminal;
        public MutationResult? Terminal { get => _terminal; set => _terminal = value; }
        public object? Value { get; set; }
    }

    async Task<ChatReminderSetOutcome> IChatRepository.SetReminderAsync(string messageId, string conversationId,
        DateTimeOffset remindAt, Guid clientRequestId, CancellationToken cancellationToken)
    {
        remindAt = Milliseconds(remindAt);
        var result = await ExecuteAdvancedChatAsync(clientRequestId, "setReminder", new { messageId, conversationId, remindAt },
            "SYNO.Chat.Post.Reminder", conversationId, messageId, messageId,
            // 与 Apple 适配器一致：毫秒时间作为业务字符串；FORM 不带引号，JSON 声明时编码一次。
            async (_, token) => { await AdvancedChatCallAsync("SYNO.Chat.Post.Reminder", 1, "set", [("post_id", messageId), ("remind_at", remindAt.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture))], token).ConfigureAwait(false); },
            async (_, token) =>
            {
                var matches = (await ReadRemindersAsync(conversationId, token).ConfigureAwait(false)).Where(item => item.MessageId == messageId && item.RemindAt == remindAt).ToArray();
                return (matches.Length == 1, matches.SingleOrDefault());
            }, cancellationToken, () => remindAt > DateTimeOffset.UtcNow).ConfigureAwait(false);
        return new(result.Result, messageId, conversationId, clientRequestId, result.Value as ChatReminder);
    }

    Task<IReadOnlyList<ChatReminder>> IChatRepository.ListRemindersAsync(string conversationId, CancellationToken cancellationToken) => ReadRemindersAsync(conversationId, cancellationToken);
    Task<MutationResult> IChatRepository.DeleteReminderAsync(string messageId, string conversationId, Guid clientRequestId, CancellationToken cancellationToken) =>
        DeleteAdvancedReminderAsync(messageId, conversationId, clientRequestId, null, cancellationToken);
    Task<MutationResult> IChatRepository.DeleteReminderAsync(ChatReminder expected, Guid clientRequestId, CancellationToken cancellationToken) =>
        DeleteAdvancedReminderAsync(expected.MessageId, expected.ConversationId, clientRequestId, expected, cancellationToken);
    private async Task<MutationResult> DeleteAdvancedReminderAsync(string messageId, string conversationId, Guid clientRequestId, ChatReminder? expected, CancellationToken cancellationToken) =>
        (await ExecuteAdvancedChatAsync(clientRequestId, "deleteReminder", new { messageId, conversationId, expected }, "SYNO.Chat.Post.Reminder", conversationId, null, messageId,
            async (_, token) => { await AdvancedChatCallAsync("SYNO.Chat.Post.Reminder", 1, "delete", [("post_id", messageId)], token).ConfigureAwait(false); },
            async (state, token) =>
            {
                var current = (await ReadRemindersAsync(conversationId, token).ConfigureAwait(false)).SingleOrDefault(item => item.MessageId == messageId);
                if (!state.Submitted && current is not null && expected is not null && current != expected) throw new AdvancedChatTargetChangedException();
                return (current is null, null);
            }, cancellationToken).ConfigureAwait(false)).Result;

    async Task<ChatScheduledMessageCreateOutcome> IChatRepository.CreateScheduledMessageAsync(ChatScheduledMessageDraft draft, CancellationToken cancellationToken)
    {
        draft = draft with { Text = draft.Text.Trim(), SendAt = Milliseconds(draft.SendAt) };
        if (string.IsNullOrWhiteSpace(draft.Text) || draft.Text.Contains('\0'))
            return new(ChatFailure("createScheduledMessage", "chat.schedule.invalid", MutationErrorCategory.Validation), draft.ClientRequestId, null);
        var result = await ExecuteAdvancedChatAsync(draft.ClientRequestId, "createScheduledMessage", new { draft.ConversationId, draft.Text, draft.SendAt },
            "SYNO.Chat.Post.Schedule", draft.ConversationId, null, JsonSerializer.Serialize(new { draft.Text, draft.SendAt }),
            async (state, token) =>
            {
                var response = await AdvancedChatCallAsync("SYNO.Chat.Post.Schedule", 1, "create", [("channel_id", draft.ConversationId), ("message", draft.Text), ("send_at", draft.SendAt.ToUnixTimeMilliseconds().ToString(CultureInfo.InvariantCulture))], token).ConfigureAwait(false);
                state.CandidateId = response.String("cronjob_id") ?? response.String("id");
            },
            async (state, token) =>
            {
                var matches = (await ReadScheduledMessagesAsync(draft.ConversationId, token).ConfigureAwait(false)).Where(item => item.Text == draft.Text && item.SendAt == draft.SendAt && (state.CandidateId is null || item.Id == state.CandidateId)).ToArray();
                return (matches.Length == 1, matches.SingleOrDefault());
            }, cancellationToken, () => draft.SendAt > DateTimeOffset.UtcNow).ConfigureAwait(false);
        return new(result.Result, draft.ClientRequestId, result.Value as ChatScheduledMessage);
    }

    Task<IReadOnlyList<ChatScheduledMessage>> IChatRepository.ListScheduledMessagesAsync(string conversationId, CancellationToken cancellationToken) => ReadScheduledMessagesAsync(conversationId, cancellationToken);
    Task<MutationResult> IChatRepository.DeleteScheduledMessageAsync(string scheduledId, string conversationId, Guid clientRequestId, CancellationToken cancellationToken) =>
        DeleteAdvancedScheduleAsync(scheduledId, conversationId, clientRequestId, null, cancellationToken);
    Task<MutationResult> IChatRepository.DeleteScheduledMessageAsync(ChatScheduledMessage expected, Guid clientRequestId, CancellationToken cancellationToken) =>
        DeleteAdvancedScheduleAsync(expected.Id, expected.ConversationId, clientRequestId, expected, cancellationToken);
    private async Task<MutationResult> DeleteAdvancedScheduleAsync(string scheduledId, string conversationId, Guid clientRequestId, ChatScheduledMessage? expected, CancellationToken cancellationToken) =>
        (await ExecuteAdvancedChatAsync(clientRequestId, "deleteScheduledMessage", new { scheduledId, conversationId, expected }, "SYNO.Chat.Post.Schedule", conversationId, null, scheduledId,
            async (_, token) => { await AdvancedChatCallAsync("SYNO.Chat.Post.Schedule", 1, "delete", [("cronjob_id", scheduledId)], token).ConfigureAwait(false); },
            async (state, token) =>
            {
                var current = (await ReadScheduledMessagesAsync(conversationId, token).ConfigureAwait(false)).SingleOrDefault(item => item.Id == scheduledId);
                if (!state.Submitted && current is not null && expected is not null && current != expected) throw new AdvancedChatTargetChangedException();
                return (current is null, null);
            }, cancellationToken).ConfigureAwait(false)).Result;

    async Task<ChatPollCreateOutcome> IChatRepository.CreatePollAsync(ChatPollDraft draft, CancellationToken cancellationToken)
    {
        draft = draft with { Question = draft.Question.Trim(), Options = draft.Options.Select(value => value.Trim()).ToArray() };
        if (!draft.IsValid || draft.Question.Contains('\0') || draft.Options.Any(value => value.Contains('\0')))
            return new(ChatFailure("createPoll", "chat.poll.invalid", MutationErrorCategory.Validation), draft.ClientRequestId, null);
        var result = await ExecuteAdvancedChatAsync(draft.ClientRequestId, "createPoll",
            new { draft.ConversationId, draft.Question, draft.Options, draft.AllowsMultipleSelection, draft.IsAnonymous },
            "SYNO.Chat.Post.Vote", draft.ConversationId, null, JsonSerializer.Serialize(new { draft.Question, draft.Options, draft.AllowsMultipleSelection, draft.IsAnonymous }),
            async (state, token) =>
            {
                var options = JsonSerializer.Serialize(new { add_option = false, anonymous = draft.IsAnonymous, multiple = draft.AllowsMultipleSelection });
                var response = await AdvancedChatCallAsync("SYNO.Chat.Post.Vote", 1, "create",
                    [("channel_id", draft.ConversationId), ("message", draft.Question), ("choices", draft.Options), ("options", options)], token).ConfigureAwait(false);
                state.CandidateId = response.String("post_id") ?? response.String("id");
            },
            async (state, token) =>
            {
                var page = await ListMessagesAsync(draft.ConversationId, null, 100, token).ConfigureAwait(false);
                if (!state.Submitted)
                {
                    state.BaselineMessageIds.UnionWith(page.Messages.Select(message => message.Id));
                    return (false, null);
                }
                var matches = page.Messages.Where(message => message.IsFromCurrentUser == true &&
                    !state.BaselineMessageIds.Contains(message.Id) &&
                    message.EncryptionState == ChatEncryptionState.NotEncrypted &&
                    (state.CandidateId is null || message.Id == state.CandidateId) &&
                    Math.Abs((message.SentAt - state.SubmittedAt).TotalSeconds) <= 180 &&
                    message.Poll is { } poll && poll.Question == draft.Question &&
                    poll.AllowsMultipleSelection == draft.AllowsMultipleSelection && poll.IsAnonymous == draft.IsAnonymous &&
                    poll.Options.Select(option => option.Text).SequenceEqual(draft.Options, StringComparer.Ordinal)).ToArray();
                return (matches.Length == 1, matches.SingleOrDefault());
            }, cancellationToken).ConfigureAwait(false);
        return new(result.Result, draft.ClientRequestId, result.Value as ChatMessage);
    }

    private async Task<IReadOnlyList<ChatReminder>> ReadRemindersAsync(string conversationId, CancellationToken token)
    {
        EnsureReadableChatContract();
        if (!ValidAdvancedId(conversationId)) throw new ArgumentException("chat.reminder.invalid");
        var data = await AdvancedChatCallAsync("SYNO.Chat.Post.Reminder", 1, "list", [("channel_id", conversationId)], token).ConfigureAwait(false);
        return AdvancedList(data, "reminders", "posts", "reminder_list", "items", "list", "results").Select(item =>
        {
            RequireAdvancedOwner(item, conversationId);
            var id = item.String("post_id") ?? item.String("message_id") ?? throw InvalidChatResponse();
            string[] timeKeys = ["remind_at", "reminde_at", "reminder_at", "time"];
            var time = timeKeys.Any(key => ChatUnixMilliseconds(item, key) is not null) ? item : item["props"] as JsonObject ?? item;
            return new ChatReminder(id, conversationId, AdvancedTime(time, timeKeys));
        }).OrderBy(item => item.RemindAt).ToArray();
    }

    private async Task<IReadOnlyList<ChatScheduledMessage>> ReadScheduledMessagesAsync(string conversationId, CancellationToken token)
    {
        EnsureReadableChatContract();
        if (!ValidAdvancedId(conversationId)) throw new ArgumentException("chat.schedule.invalid");
        var data = await AdvancedChatCallAsync("SYNO.Chat.Post.Schedule", 1, "list", [("channel_id", conversationId)], token).ConfigureAwait(false);
        return AdvancedList(data, "schedules", "schedule_posts", "scheduled_posts", "cronjobs", "items", "list", "results").Select(item =>
        {
            RequireAdvancedOwner(item, conversationId);
            if ((item.String("channel_id") ?? item.String("conversation_id")) != conversationId) throw InvalidChatResponse();
            return new ChatScheduledMessage(item.String("cronjob_id") ?? item.String("schedule_id") ?? item.String("id") ?? throw InvalidChatResponse(), conversationId,
                item.String("message") ?? item.String("text") ?? item.String("content") ?? throw InvalidChatResponse(), AdvancedTime(item, "send_at", "scheduled_at", "time"));
        }).OrderBy(item => item.SendAt).ToArray();
    }

    private static JsonObject[] AdvancedList(JsonObject data, params string[] keys)
    {
        var array = keys.Append(DsmApiResponseKeys.RootArray).Select(key => data[key]).OfType<JsonArray>().FirstOrDefault();
        if (array is not null) return array.Select(node => node as JsonObject ?? throw InvalidChatResponse()).ToArray();
        // Apple 已有单条对象响应映射；仍由具体解析器严格核对身份、会话和时间。
        if (keys[0] == "reminders" && (data["post_id"] is not null || data["message_id"] is not null)) return [data];
        if (keys[0] == "schedules" && (data["cronjob_id"] is not null || data["id"] is not null)) return [data];
        throw InvalidChatResponse();
    }
    private static void RequireAdvancedOwner(JsonObject item, string conversationId)
    {
        foreach (var key in new[] { "channel_id", "conversation_id" })
            if (item[key] is not null && item.String(key) != conversationId) throw InvalidChatResponse();
    }
    private static DateTimeOffset AdvancedTime(JsonObject item, params string[] keys)
    {
        foreach (var key in keys) if (ChatUnixMilliseconds(item, key) is { } value)
        {
            try { return value > 10_000_000_000 ? DateTimeOffset.FromUnixTimeMilliseconds(value) : DateTimeOffset.FromUnixTimeSeconds(value); }
            catch (ArgumentOutOfRangeException) { throw InvalidChatResponse(); }
        }
        throw InvalidChatResponse();
    }
}
