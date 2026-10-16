using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<ChatMessageUpdateOutcome> EditMessageAsync(ChatEditMessageRequest request,
        CancellationToken cancellationToken = default)
    {
        var original = request.Original;
        var text = request.Text.Trim();
        if (text.Length == 0 || text.Contains('\0')) return new(ChatFailure("editMessage", "chat.edit.empty"), null);
        if (!HasAdvancedApi("SYNO.Chat.Admin.Setting", 3)) return new(ChatUnsupported("editMessage"), null);
        var expected = ActionMessageFingerprint(original);
        var result = await ExecuteAdvancedChatAsync(request.ClientRequestId, "editMessage",
            new { expected, text }, "SYNO.Chat.Post", original.ConversationId, null, original.Id,
            async (_, token) => { await AdvancedChatCallAsync("SYNO.Chat.Post", 8, "set",
                [("channel_id", original.ConversationId), ("post_id", original.Id), ("message", text)], token).ConfigureAwait(false); },
            async (state, token) =>
            {
                await RequireAdvancedConversationAsync(original.ConversationId, null, token).ConfigureAwait(false);
                var current = await LocateMessageAsync(original.ConversationId, original.Id, original.ThreadId, token).ConfigureAwait(false)
                    ?? throw new AdvancedChatTargetChangedException();
                if (!state.Submitted)
                {
                    if (ActionMessageFingerprint(current) != expected) throw new AdvancedChatTargetChangedException();
                    if (!(await GetEditingPolicyAsync(token).ConfigureAwait(false)).Permits(current, DateTimeOffset.UtcNow))
                        throw new AdvancedChatPermissionException();
                    return (false, null);
                }
                return (current.SenderId == original.SenderId && current.IsFromCurrentUser == true && current.Text == text &&
                    current.ThreadId == original.ThreadId && current.Kind == original.Kind && current.Poll is null &&
                    current.EncryptionState == ChatEncryptionState.NotEncrypted &&
                    current.Attachments.SequenceEqual(original.Attachments), current);
            }, cancellationToken, requiredVersion: 8).ConfigureAwait(false);
        return new(result.Result, result.Value as ChatMessage);
    }

    public async Task<ChatMessageUpdateOutcome> VoteAsync(ChatVoteRequest request, CancellationToken cancellationToken = default)
    {
        var original = request.Original;
        var choices = request.ChoiceIds.Order(StringComparer.Ordinal).ToArray();
        if (choices.Length == 0 || choices.Distinct(StringComparer.Ordinal).Count() != choices.Length || choices.Any(id => !ValidAdvancedId(id)))
            return new(ChatFailure("vote", "chat.vote.invalid-selection"), null);
        var baseline = ChatPollIdentity(original);
        var result = await ExecuteAdvancedChatAsync(request.ClientRequestId, "vote", new { baseline, choices },
            "SYNO.Chat.Post.Vote", original.ConversationId, null, original.Id,
            async (_, token) => { await AdvancedChatCallAsync("SYNO.Chat.Post.Vote", 1, "vote",
                [("post_id", original.Id), ("choice_ids", choices)], token).ConfigureAwait(false); },
            async (state, token) =>
            {
                var current = await GetPollMessageAsync(original, token).ConfigureAwait(false);
                if (current.Poll is not { HasStableOptionIds: true } poll || baseline != ChatPollIdentity(current))
                    throw new AdvancedChatTargetChangedException();
                if (!state.Submitted)
                {
                    if (poll.IsClosed || poll.ClosesAt <= DateTimeOffset.UtcNow ||
                        (!poll.AllowsMultipleSelection && choices.Length != 1) ||
                        choices.Any(id => !poll.Options.Any(option => option.Id == id))) throw new AdvancedChatPermissionException();
                    state.OwnerId = _chatCurrentUserId;
                    return (false, null);
                }
                return (state.OwnerId is not null && _chatCurrentUserId == state.OwnerId &&
                    poll.Options.Where(option => option.IsSelectedByCurrentUser == true).Select(option => option.Id)
                        .Order(StringComparer.Ordinal).SequenceEqual(choices), current);
            }, cancellationToken).ConfigureAwait(false);
        return new(result.Result, result.Value as ChatMessage);
    }

    private static string ChatPollIdentity(ChatMessage message) => AdvancedFingerprint(new
    {
        message.Id, message.ConversationId, message.ThreadId, message.SenderId, message.SentAt,
        poll = message.Poll is { } poll ? new { poll.Id, poll.Question, poll.AllowsMultipleSelection, poll.IsAnonymous,
            poll.ClosesAt, poll.HasStableOptionIds, options = poll.Options.Select(value => new { value.Id, value.Text }).ToArray() } : null,
    });

    public async Task<ChatTextSendOutcome> SendTextAsync(ChatTextSendRequest request, CancellationToken cancellationToken = default)
    {
        var normalized = request with { ConversationId = request.ConversationId.Trim(), Text = request.Text.Trim() };
        if (normalized.Text.Length == 0 || normalized.Text.Contains('\0') ||
            normalized.ThreadId is not null && (!ValidAdvancedId(normalized.ThreadId) || normalized.ThreadId == "0"))
            return new(ChatFailure("chatTextSend", "chat.text-send.invalid-input"), normalized.ConversationId, request.ClientRequestId, null);
        var result = await ExecuteAdvancedChatAsync(request.ClientRequestId, "chatTextSend",
            new { normalized.ConversationId, normalized.Text, normalized.ThreadId }, "SYNO.Chat.Post", normalized.ConversationId, null,
            AdvancedFingerprint(new { normalized.Text, normalized.ThreadId }),
            async (state, token) =>
            {
                var parameters = new List<(string Key, object Value)> { ("channel_id", normalized.ConversationId), ("message", normalized.Text) };
                if (normalized.ThreadId is { } thread)
                {
                    parameters.Add(("type", "normal")); parameters.Add(("is_thread", false)); parameters.Add(("thread_id", thread));
                }
                var response = await AdvancedChatCallAsync("SYNO.Chat.Post", 5, "create", parameters.ToArray(), token).ConfigureAwait(false);
                state.CandidateId = ChatTextCreateMessageId(response);
            },
            async (state, token) =>
            {
                if (!state.Submitted)
                {
                    if (normalized.ThreadId is { } thread)
                    {
                        var root = await LocateMessageAsync(normalized.ConversationId, thread, null, token).ConfigureAwait(false);
                        if (root is null || root.IsThreadReply || root.Kind is ChatMessageKind.System or ChatMessageKind.Unknown)
                            throw new AdvancedChatTargetChangedException();
                    }
                    state.OwnerId = _chatCurrentUserId;
                    return (false, null);
                }
                if (!state.Accepted || state.CandidateId is null) return (false, null);
                await RequireAdvancedConversationAsync(normalized.ConversationId, null, token).ConfigureAwait(false);
                var message = await LocateMessageAsync(normalized.ConversationId, state.CandidateId, normalized.ThreadId, token).ConfigureAwait(false);
                // 本次认证创建回执、稳定编号与精确正文允许补齐缺少的本人布尔标记；明确他人身份永远拒绝。
                var confirmed = message is not null && message.Text == normalized.Text && message.Attachments.Count == 0 && message.Poll is null &&
                    message.Kind == ChatMessageKind.Normal && message.IsFromCurrentUser != false && message.SenderId != "unknown" &&
                    (state.OwnerId is null || message.SenderId == state.OwnerId) &&
                    (normalized.ThreadId is null ? !message.IsThreadReply : message.ThreadId == normalized.ThreadId);
                return (confirmed, confirmed ? message! with { IsFromCurrentUser = true } : null);
            }, cancellationToken, requiredVersion: 5).ConfigureAwait(false);
        var status = result.Result;
        if (status.ErrorCategory == MutationErrorCategory.Permission && status.Status == MutationResultStatus.ConfirmedFailure)
            status = new(status.SchemaVersion, MutationResultStatus.PermissionDenied, status.Operation, status.Submitted,
                status.RequiresRefresh, status.Counts, status.ErrorCategory, status.LocalizationKey, status.DiagnosticTag);
        return new(status, normalized.ConversationId, request.ClientRequestId, result.Value as ChatMessage);
    }
}
