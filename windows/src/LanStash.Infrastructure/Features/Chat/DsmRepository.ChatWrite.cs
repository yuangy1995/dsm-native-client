using LanStash.Domain;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // Chat 高级写必须同时满足冻结契约、强类型未知结果和回读规则，当前保持关闭。
    private const bool ChatAdvancedWritesEnabled = false;
    private const int ChatDeleteOwnMessageVersion = 5;

    private readonly Dictionary<Guid, PendingChatMessageDeleteReview> _pendingChatMessageDeletes = [];
    // ── 消息删除 ──

    async Task<MutationResult> IChatRepository.DeleteOwnMessageAsync(
        ChatDeleteMessageRequest request,
        CancellationToken cancellationToken)
    {
        var messageId = request.MessageId?.Trim() ?? string.Empty;
        var conversationId = request.ConversationId?.Trim() ?? string.Empty;
        var normalizedRequest = request with
        {
            MessageId = messageId,
            ConversationId = conversationId,
        };
        if (cancellationToken.IsCancellationRequested)
        {
            return ChatCancelled("deleteOwnMessage");
        }
        if (request.ClientRequestId == Guid.Empty ||
            string.IsNullOrWhiteSpace(messageId) ||
            string.IsNullOrWhiteSpace(conversationId) ||
            _profile.Id != _session.ProfileId)
        {
            return ChatFailure("deleteOwnMessage", "chat.delete-own-message.validation");
        }
        if (!HasDeleteOwnMessageContract)
        {
            return ChatUnsupported("deleteOwnMessage");
        }
        if (_pendingChatMessageDeletes.TryGetValue(request.ClientRequestId, out var pendingReview))
        {
            return await FinishPendingChatMessageDeleteAsync(pendingReview, cancellationToken)
                .ConfigureAwait(false);
        }

        IReadOnlyList<ChatConversation> conversations;
        try
        {
            conversations = await ListConversationsAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ChatCancelled("deleteOwnMessage");
        }
        catch (DsmException error) when (error.AuthenticationFailure == true)
        {
            return ChatFailure("deleteOwnMessage", "chat.delete-own-message.authentication",
                MutationErrorCategory.Authentication);
        }
        catch
        {
            return ChatFailure("deleteOwnMessage", "chat.delete-own-message.preflight",
                MutationErrorCategory.Unknown);
        }

        var conversation = conversations.FirstOrDefault(value =>
            string.Equals(value.Id, conversationId, StringComparison.Ordinal));
        if (conversation is null || conversation.IsEncrypted)
        {
            return ChatFailure(
                "deleteOwnMessage",
                conversation is null
                    ? "chat.delete-own-message.conversation-missing"
                    : "chat.delete-own-message.encrypted-conversation",
                MutationErrorCategory.Validation);
        }

        ChatMessage? message;
        try
        {
            var currentPage = await ListMessagesAsync(
                conversationId, beforeCursor: null, limit: 100, cancellationToken)
                .ConfigureAwait(false);
            message = currentPage.Messages.FirstOrDefault(value =>
                string.Equals(value.Id, messageId, StringComparison.Ordinal));
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ChatCancelled("deleteOwnMessage");
        }
        catch (DsmException error) when (error.Code == 105)
        {
            return ChatFailure("deleteOwnMessage", "chat.delete-own-message.permission",
                MutationErrorCategory.Permission);
        }
        catch
        {
            return ChatFailure("deleteOwnMessage", "chat.delete-own-message.preflight",
                MutationErrorCategory.Unknown);
        }

        if (message is null ||
            message.IsFromCurrentUser != true ||
            message.EncryptionState != ChatEncryptionState.NotEncrypted)
        {
            return ChatFailure(
                "deleteOwnMessage",
                message is null
                    ? "chat.delete-own-message.message-missing"
                    : "chat.delete-own-message.not-owned",
                message is null ? MutationErrorCategory.Conflict : MutationErrorCategory.Permission,
                submitted: false);
        }

        var review = new PendingChatMessageDeleteReview(
            _profile.Id,
            conversationId,
            messageId,
            normalizedRequest.ClientRequestId);
        try
        {
            await CallChatExactVersionAsync(
                "SYNO.Chat.Post",
                "delete",
                ChatDeleteOwnMessageVersion,
                new Dictionary<string, string> { ["post_id"] = messageId },
                cancellationToken).ConfigureAwait(false);
            _pendingChatMessageDeletes[request.ClientRequestId] = review;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            _pendingChatMessageDeletes[request.ClientRequestId] = review;
            return ChatCancelledAfterSubmission("deleteOwnMessage");
        }
        catch (DsmException error) when (error.Code == 105)
        {
            return ChatFailure("deleteOwnMessage", "chat.delete-own-message.permission",
                MutationErrorCategory.Permission, submitted: true);
        }
        catch
        {
            _pendingChatMessageDeletes[request.ClientRequestId] = review;
            return ChatUnknown("deleteOwnMessage", "chat.delete-own-message.submitted-unverified");
        }

        return await FinishPendingChatMessageDeleteAsync(review, cancellationToken)
            .ConfigureAwait(false);
    }

    private async Task<MutationResult> FinishPendingChatMessageDeleteAsync(
        PendingChatMessageDeleteReview review,
        CancellationToken cancellationToken)
    {
        try
        {
            var verifiedPage = await ListMessagesAsync(
                review.ConversationId, beforeCursor: null, limit: 100, cancellationToken)
                .ConfigureAwait(false);
            var gone = !verifiedPage.Messages.Any(value =>
                string.Equals(value.Id, review.MessageId, StringComparison.Ordinal));
            if (gone)
            {
                _pendingChatMessageDeletes.Remove(review.ClientRequestId);
                return ChatSuccess("deleteOwnMessage");
            }
            return ChatUnknown("deleteOwnMessage", "chat.delete-own-message.readback-mismatch");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ChatCancelledAfterSubmission("deleteOwnMessage");
        }
        catch
        {
            return ChatUnknown("deleteOwnMessage", "chat.delete-own-message.readback-unavailable");
        }
    }

    // ── 会话关闭 ──

    async Task<MutationResult> IChatRepository.CloseConversationAsync(
        ChatCloseConversationRequest request,
        CancellationToken cancellationToken)
    {
        if (!HasChatWriteCapability("SYNO.Chat.Channel"))
        {
            return ChatUnsupported("chat.closeConversation");
        }

        try
        {
            await CallChatMethodAsync("SYNO.Chat.Channel", "close",
                new Dictionary<string, string> { ["channel_id"] = request.ConversationId },
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new MutationResult(1, MutationResultStatus.CancelledBeforeSubmission,
                "closeConversation", submitted: false, requiresRefresh: false,
                new MutationResultCounts(0, 0, 0));
        }
        catch
        {
            return new MutationResult(1, MutationResultStatus.SubmittedButUnverified,
                "closeConversation", submitted: true, requiresRefresh: true,
                new MutationResultCounts(0, 0, 1), MutationErrorCategory.Unknown,
                diagnosticTag: "chat.close-conversation.readback-failed");
        }

        try
        {
            var conversations = await ListConversationsAsync(cancellationToken).ConfigureAwait(false);
            var gone = !conversations.Any(c => c.Id == request.ConversationId);
            return new MutationResult(1,
                gone ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
                "closeConversation", submitted: true, requiresRefresh: !gone,
                new MutationResultCounts(gone ? 1 : 0, 0, gone ? 0 : 1));
        }
        catch
        {
            return new MutationResult(1, MutationResultStatus.SubmittedButUnverified,
                "closeConversation", submitted: true, requiresRefresh: true,
                new MutationResultCounts(0, 0, 1), MutationErrorCategory.Unknown,
                diagnosticTag: "chat.close-conversation.readback-unavailable");
        }
    }

    // ── 高级写：契约固定为 v1，当前仍由生产能力门关闭 ──

    async Task<ChatReminderSetOutcome> IChatRepository.SetReminderAsync(
        string messageId, string conversationId, DateTimeOffset remindAt,
        Guid clientRequestId, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(messageId) || string.IsNullOrWhiteSpace(conversationId) ||
            remindAt <= DateTimeOffset.UtcNow)
        {
            return new(ChatFailure("setReminder", "chat.setReminder.validation"),
                messageId, conversationId, clientRequestId, null);
        }
        if (!HasFrozenChatWriteCapability("SYNO.Chat.Post.Reminder", 1))
        {
            return new(ChatUnsupported("setReminder"), messageId, conversationId,
                clientRequestId, null);
        }
        if (cancellationToken.IsCancellationRequested)
        {
            return new(ChatCancelled("setReminder"), messageId, conversationId,
                clientRequestId, null);
        }

        try
        {
            await CallChatWriteMethodAsync("SYNO.Chat.Post.Reminder", 1, "set",
                new Dictionary<string, string>
                {
                    ["post_id"] = messageId,
                    ["remind_at"] = remindAt.ToUnixTimeMilliseconds().ToString(),
                }, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new(ChatCancelledAfterSubmission("setReminder"), messageId,
                conversationId, clientRequestId, null);
        }
        catch (DsmException error) when (error.AuthenticationFailure == true)
        {
            return new(ChatFailure("setReminder", "chat.setReminder.authentication", MutationErrorCategory.Authentication),
                messageId, conversationId, clientRequestId, null);
        }
        catch (DsmException error) when (error.Code == 105)
        {
            return new(ChatFailure("setReminder", "chat.setReminder.permission", MutationErrorCategory.Permission),
                messageId, conversationId, clientRequestId, null);
        }
        catch
        {
            return new(ChatUnknown("setReminder"), messageId, conversationId, clientRequestId, null);
        }

        try
        {
            var reminders = await ReadRemindersAsync(conversationId, cancellationToken).ConfigureAwait(false);
            var match = reminders.SingleOrDefault(reminder =>
                reminder.MessageId == messageId && reminder.RemindAt == remindAt);
            return match is null
                ? new(ChatUnknown("setReminder", "chat.setReminder.readback-mismatch"),
                    messageId, conversationId, clientRequestId, null)
                : new(ChatSuccess("setReminder"), messageId, conversationId,
                    clientRequestId, match);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new(ChatCancelledAfterSubmission("setReminder"), messageId,
                conversationId, clientRequestId, null);
        }
        catch
        {
            return new(ChatUnknown("setReminder", "chat.setReminder.readback-unavailable"),
                messageId, conversationId, clientRequestId, null);
        }
    }

    async Task<IReadOnlyList<ChatReminder>> IChatRepository.ListRemindersAsync(
        string conversationId, CancellationToken cancellationToken)
    {
        if (!HasFrozenChatWriteCapability("SYNO.Chat.Post.Reminder", 1)) return [];
        try { return await ReadRemindersAsync(conversationId, cancellationToken).ConfigureAwait(false); }
        catch { return []; }
    }

    async Task<MutationResult> IChatRepository.DeleteReminderAsync(
        string messageId, string conversationId, Guid clientRequestId,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(messageId) || string.IsNullOrWhiteSpace(conversationId))
            return ChatFailure("deleteReminder", "chat.deleteReminder.validation");
        if (!HasFrozenChatWriteCapability("SYNO.Chat.Post.Reminder", 1))
            return ChatUnsupported("deleteReminder");
        if (cancellationToken.IsCancellationRequested) return ChatCancelled("deleteReminder");
        try
        {
            await CallChatWriteMethodAsync("SYNO.Chat.Post.Reminder", 1, "delete",
                new Dictionary<string, string> { ["post_id"] = messageId }, cancellationToken)
                .ConfigureAwait(false);
            var remaining = await ReadRemindersAsync(conversationId, cancellationToken).ConfigureAwait(false);
            return remaining.Any(item => item.MessageId == messageId)
                ? ChatUnknown("deleteReminder", "chat.deleteReminder.readback-mismatch")
                : ChatSuccess("deleteReminder");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ChatCancelledAfterSubmission("deleteReminder");
        }
        catch (DsmException error) when (error.AuthenticationFailure == true)
        {
            return ChatFailure("deleteReminder", "chat.deleteReminder.authentication", MutationErrorCategory.Authentication);
        }
        catch (DsmException error) when (error.Code == 105)
        {
            return ChatFailure("deleteReminder", "chat.deleteReminder.permission", MutationErrorCategory.Permission);
        }
        catch
        {
            return ChatUnknown("deleteReminder", "chat.deleteReminder.readback-unavailable");
        }
    }

    async Task<ChatScheduledMessageCreateOutcome> IChatRepository.CreateScheduledMessageAsync(
        ChatScheduledMessageDraft draft, CancellationToken cancellationToken)
    {
        if (!draft.IsValid)
            return new(ChatFailure("createScheduledMessage", "chat.createScheduledMessage.validation"),
                draft.ClientRequestId, null);
        if (!HasFrozenChatWriteCapability("SYNO.Chat.Post.Schedule", 1))
            return new(ChatUnsupported("createScheduledMessage"), draft.ClientRequestId, null);
        if (cancellationToken.IsCancellationRequested)
            return new(ChatCancelled("createScheduledMessage"), draft.ClientRequestId, null);
        JsonObject data;
        try
        {
            data = await CallChatWriteMethodAsync("SYNO.Chat.Post.Schedule", 1, "create",
                new Dictionary<string, string>
                {
                    ["channel_id"] = draft.ConversationId,
                    ["message"] = draft.Text,
                    ["send_at"] = draft.SendAt.ToUnixTimeMilliseconds().ToString(),
                }, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new(ChatCancelledAfterSubmission("createScheduledMessage"), draft.ClientRequestId, null);
        }
        catch (DsmException error) when (error.AuthenticationFailure == true)
        {
            return new(ChatFailure("createScheduledMessage", "chat.createScheduledMessage.authentication", MutationErrorCategory.Authentication), draft.ClientRequestId, null);
        }
        catch (DsmException error) when (error.Code == 105)
        {
            return new(ChatFailure("createScheduledMessage", "chat.createScheduledMessage.permission", MutationErrorCategory.Permission), draft.ClientRequestId, null);
        }
        catch
        {
            return new(ChatUnknown("createScheduledMessage"), draft.ClientRequestId, null);
        }

        try
        {
            var schedules = await ReadScheduledMessagesAsync(draft.ConversationId, cancellationToken).ConfigureAwait(false);
            var returnedId = ChatStringField(data, "cronjob_id") ?? ChatStringField(data, "id");
            var candidates = schedules.Where(item =>
                item.Text == draft.Text && item.SendAt == draft.SendAt &&
                (returnedId is null || item.Id == returnedId)).ToArray();
            var match = candidates.Length == 1 ? candidates[0] : null;
            return match is null
                ? new(ChatUnknown("createScheduledMessage", "chat.createScheduledMessage.readback-mismatch"), draft.ClientRequestId, null)
                : new(ChatSuccess("createScheduledMessage"), draft.ClientRequestId, match);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new(ChatCancelledAfterSubmission("createScheduledMessage"), draft.ClientRequestId, null);
        }
        catch
        {
            return new(ChatUnknown("createScheduledMessage", "chat.createScheduledMessage.readback-unavailable"), draft.ClientRequestId, null);
        }
    }

    async Task<IReadOnlyList<ChatScheduledMessage>> IChatRepository.ListScheduledMessagesAsync(
        string conversationId, CancellationToken cancellationToken)
    {
        if (!HasFrozenChatWriteCapability("SYNO.Chat.Post.Schedule", 1)) return [];
        try { return await ReadScheduledMessagesAsync(conversationId, cancellationToken).ConfigureAwait(false); }
        catch { return []; }
    }

    async Task<MutationResult> IChatRepository.DeleteScheduledMessageAsync(
        string scheduledId, string conversationId, Guid clientRequestId,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(scheduledId) || string.IsNullOrWhiteSpace(conversationId))
            return ChatFailure("deleteScheduledMessage", "chat.deleteScheduledMessage.validation");
        if (!HasFrozenChatWriteCapability("SYNO.Chat.Post.Schedule", 1))
            return ChatUnsupported("deleteScheduledMessage");
        if (cancellationToken.IsCancellationRequested) return ChatCancelled("deleteScheduledMessage");
        try
        {
            await CallChatWriteMethodAsync("SYNO.Chat.Post.Schedule", 1, "delete",
                new Dictionary<string, string> { ["cronjob_id"] = scheduledId }, cancellationToken)
                .ConfigureAwait(false);
            var remaining = await ReadScheduledMessagesAsync(conversationId, cancellationToken).ConfigureAwait(false);
            return remaining.Any(item => item.Id == scheduledId)
                ? ChatUnknown("deleteScheduledMessage", "chat.deleteScheduledMessage.readback-mismatch")
                : ChatSuccess("deleteScheduledMessage");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ChatCancelledAfterSubmission("deleteScheduledMessage");
        }
        catch { return ChatUnknown("deleteScheduledMessage", "chat.deleteScheduledMessage.readback-unavailable"); }
    }

    async Task<ChatPollCreateOutcome> IChatRepository.CreatePollAsync(
        ChatPollDraft draft, CancellationToken cancellationToken)
    {
        if (!draft.IsValid)
            return new(ChatFailure("createPoll", "chat.createPoll.validation"), draft.ClientRequestId, null);
        if (!HasFrozenChatWriteCapability("SYNO.Chat.Post.Vote", 1))
            return new(ChatUnsupported("createPoll"), draft.ClientRequestId, null);
        if (cancellationToken.IsCancellationRequested)
            return new(ChatCancelled("createPoll"), draft.ClientRequestId, null);

        try
        {
            await CallChatWriteMethodAsync("SYNO.Chat.Post.Vote", 1, "create",
                new Dictionary<string, string>
                {
                    ["channel_id"] = draft.ConversationId,
                    ["message"] = draft.Question,
                    ["choices"] = JsonSerializer.Serialize(draft.Options),
                    ["options"] = JsonSerializer.Serialize(new
                    {
                        multiple = draft.AllowsMultipleSelection,
                        anonymous = draft.IsAnonymous,
                        add_option = false,
                    }),
                }, cancellationToken).ConfigureAwait(false);
            // ChatMessage 当前没有投票字段，无法逐字段回读，故不能宣称已确认。
            return new(ChatUnknown("createPoll", "chat.createPoll.readback-unavailable"),
                draft.ClientRequestId, null);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return new(ChatCancelledAfterSubmission("createPoll"), draft.ClientRequestId, null);
        }
        catch { return new(ChatUnknown("createPoll"), draft.ClientRequestId, null); }
    }

    // ── 消息转发 ──

    async Task<MutationResult> IChatRepository.ForwardMessageAsync(
        ChatForwardRequest request, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.MessageId) || request.TargetConversationIds.Count == 0)
            return ChatFailure("forwardMessage", "chat.forward.validation");
        if (!HasFrozenChatWriteCapability("SYNO.Chat.Post", 5))
            return ChatUnsupported("forwardMessage");
        if (cancellationToken.IsCancellationRequested) return ChatCancelled("forwardMessage");
        try
        {
            await CallChatWriteMethodAsync("SYNO.Chat.Post", 5, "forward",
                new Dictionary<string, string>
                {
                    ["post_id"] = request.MessageId,
                    ["channel_ids"] = JsonSerializer.Serialize(request.TargetConversationIds),
                }, cancellationToken).ConfigureAwait(false);
            return ChatUnknown("forwardMessage", "chat.forward.readback-unavailable");
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ChatCancelledAfterSubmission("forwardMessage");
        }
        catch { return ChatUnknown("forwardMessage", "chat.forward.submit-failed"); }
    }

    private async Task<IReadOnlyList<ChatReminder>> ReadRemindersAsync(
        string conversationId, CancellationToken cancellationToken)
    {
        var data = await CallChatReadMethodAsync("SYNO.Chat.Post.Reminder", 1, "list",
            new Dictionary<string, string> { ["channel_id"] = conversationId }, cancellationToken)
            .ConfigureAwait(false);
        var reminders = new List<ChatReminder>();
        foreach (var obj in data.Array("reminders").OfType<JsonObject>())
        {
            var messageId = ChatStringField(obj, "post_id");
            var remindAt = ChatUnixMilliseconds(obj, "remind_at");
            if (messageId is not null && remindAt is not null)
                reminders.Add(new ChatReminder(messageId, conversationId,
                    DateTimeOffset.FromUnixTimeMilliseconds(remindAt.Value)));
        }
        return reminders.OrderBy(item => item.RemindAt).ToArray();
    }

    private async Task<IReadOnlyList<ChatScheduledMessage>> ReadScheduledMessagesAsync(
        string conversationId, CancellationToken cancellationToken)
    {
        var data = await CallChatReadMethodAsync("SYNO.Chat.Post.Schedule", 1, "list",
            new Dictionary<string, string> { ["channel_id"] = conversationId }, cancellationToken)
            .ConfigureAwait(false);
        var messages = new List<ChatScheduledMessage>();
        foreach (var obj in data.Array("schedules").OfType<JsonObject>())
        {
            var id = ChatStringField(obj, "cronjob_id") ?? ChatStringField(obj, "id");
            var text = ChatStringField(obj, "message");
            var sendAt = ChatUnixMilliseconds(obj, "send_at");
            if (id is not null && text is not null && sendAt is not null)
                messages.Add(new ChatScheduledMessage(id, conversationId, text,
                    DateTimeOffset.FromUnixTimeMilliseconds(sendAt.Value)));
        }
        return messages.OrderBy(item => item.SendAt).ToArray();
    }

    // ── 辅助方法 ──

    private bool HasChatWriteCapability(string apiName) =>
        ChatAdvancedWritesEnabled && _capabilities.ContainsKey(apiName);

    private bool HasDeleteOwnMessageContract =>
        HasReadableChatContract &&
        HasExactChatVersion("SYNO.Chat.Post", ChatDeleteOwnMessageVersion) &&
        _capabilities.TryGetValue("SYNO.Chat.Post", out var capability) &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private bool HasFrozenChatWriteCapability(string apiName, int requiredVersion) =>
        ChatAdvancedWritesEnabled &&
        _capabilities.TryGetValue(apiName, out var capability) &&
        capability.MinVersion <= requiredVersion && capability.MaxVersion >= requiredVersion &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    private async Task<JsonObject> CallChatMethodAsync(
        string apiName,
        string method,
        Dictionary<string, string> parameters,
        CancellationToken cancellationToken)
    {
        if (!_capabilities.TryGetValue(apiName, out var capability) ||
            !string.Equals(capability.Name, apiName, StringComparison.Ordinal))
        {
            throw new NotSupportedException($"Chat API {apiName} is not available.");
        }
        return await _api.CallReadJsonObjectAsync(
            _profile, _session, capability,
            capability.MaxVersion, method, parameters, cancellationToken)
            .ConfigureAwait(false);
    }

    private Task<JsonObject> CallChatWriteMethodAsync(
        string apiName,
        int requiredVersion,
        string method,
        IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken)
    {
        var capability = RequiredChatCapability(apiName, requiredVersion);
        return _api.CallAsync(
            _profile, _session, capability, method, parameters, cancellationToken);
    }

    private Task<JsonObject> CallChatReadMethodAsync(
        string apiName,
        int requiredVersion,
        string method,
        IReadOnlyDictionary<string, string> parameters,
        CancellationToken cancellationToken)
    {
        var capability = RequiredChatCapability(apiName, requiredVersion);
        return _api.CallReadJsonObjectAsync(
            _profile, _session, capability, requiredVersion, method, parameters,
            cancellationToken);
    }

    private ApiCapability RequiredChatCapability(string apiName, int requiredVersion)
    {
        if (!HasFrozenChatWriteCapability(apiName, requiredVersion) ||
            !_capabilities.TryGetValue(apiName, out var capability))
        {
            throw new NotSupportedException($"Chat API {apiName} v{requiredVersion} is not available.");
        }
        // CallAsync 使用能力的 MaxVersion；复制为单版本能力，避免把冻结 v1/v5 升级发送。
        return new ApiCapability(
            capability.Name, capability.Path, requiredVersion, requiredVersion,
            capability.RequestFormat);
    }

    private static string? ChatStringField(JsonObject obj, string name) =>
        obj[name] is JsonValue value && value.TryGetValue<string>(out var result)
            ? result
            : null;

    private static long? ChatUnixMilliseconds(JsonObject obj, string name)
    {
        if (obj[name] is not JsonValue value) return null;
        if (value.TryGetValue<long>(out var number)) return number;
        return value.TryGetValue<string>(out var text) &&
            long.TryParse(text, out number) ? number : null;
    }

    private static MutationResult ChatSuccess(string operation) =>
        new(1, MutationResultStatus.ConfirmedSuccess, operation,
            submitted: true, requiresRefresh: false,
            new MutationResultCounts(1, 0, 0));

    private static MutationResult ChatFailure(
        string operation,
        string diagnosticTag,
        MutationErrorCategory category = MutationErrorCategory.Validation,
        bool submitted = false) =>
        new(1, MutationResultStatus.ConfirmedFailure, operation, submitted,
            requiresRefresh: false, new MutationResultCounts(0, 1, 0), category,
            diagnosticTag: diagnosticTag.ToLowerInvariant());

    private static MutationResult ChatUnknown(
        string operation,
        string diagnosticTag = "chat.write.unverified") =>
        new(1, MutationResultStatus.SubmittedButUnverified, operation,
            submitted: true, requiresRefresh: true,
            new MutationResultCounts(0, 0, 1), MutationErrorCategory.Unknown,
            diagnosticTag: diagnosticTag.ToLowerInvariant());

    private static MutationResult ChatCancelled(string operation) =>
        new(1, MutationResultStatus.CancelledBeforeSubmission, operation,
            submitted: false, requiresRefresh: false,
            new MutationResultCounts(0, 0, 0));

    private static MutationResult ChatCancelledAfterSubmission(string operation) =>
        new(1, MutationResultStatus.CancellationRequestedAfterSubmission, operation,
            submitted: true, requiresRefresh: true,
            new MutationResultCounts(0, 0, 1), MutationErrorCategory.Network,
            diagnosticTag: $"chat.{operation}.cancelled-after-submit".ToLowerInvariant());

    private static MutationResult ChatUnsupported(string operation) =>
        new(1, MutationResultStatus.Unsupported, operation,
            submitted: false, requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: operation.StartsWith("chat.", StringComparison.Ordinal)
                ? $"{operation}.unsupported".ToLowerInvariant()
                : $"chat.{operation}.unsupported".ToLowerInvariant());

    private sealed record PendingChatMessageDeleteReview(
        Guid ProfileId,
        string ConversationId,
        string MessageId,
        Guid ClientRequestId);
}
