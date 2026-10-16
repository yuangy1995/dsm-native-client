using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public async Task<ChatAttachmentSendOutcome> SendAttachmentAsync(ChatAttachmentSendRequest request,
        IProgress<long>? progress = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var normalized = request with { ConversationId = request.ConversationId?.Trim() ?? "", Text = request.Text?.Trim() ?? "" };
        if (!ValidChatAttachmentInput(normalized))
            return new(ChatFailure("chatAttachmentSend", "chat.attachment-send.invalid-input"), normalized.ConversationId, request.ClientRequestId, null);
        Stream? content = null;
        try
        {
            var result = await ExecuteAdvancedChatAsync(request.ClientRequestId, "chatAttachmentSend",
                new { normalized.ConversationId, normalized.Text, normalized.Attachment.FileName, normalized.Attachment.MediaType, normalized.Attachment.Length },
                "SYNO.Chat.Post", normalized.ConversationId, null,
                // 修改说明不能绕过同一个未完成附件的防重；原内容源不会被未知恢复重新打开。
                AdvancedFingerprint(new { normalized.Attachment.FileName, normalized.Attachment.MediaType, normalized.Attachment.Length }),
                async (state, token) =>
                {
                    var capability = _capabilities["SYNO.Chat.Post"] with { MinVersion = ChatAttachmentSendVersion, MaxVersion = ChatAttachmentSendVersion };
                    var submission = await _api.SendChatAttachmentAsync(_profile, _session, capability,
                        new(normalized.ConversationId, normalized.Text!, normalized.Attachment.FileName, content!, normalized.Attachment.Length),
                        progress, token).ConfigureAwait(false);
                    switch (submission.Status)
                    {
                        case ChatAttachmentUploadTransportStatus.Accepted:
                            state.CandidateId = submission.CandidateMessageId; break;
                        case ChatAttachmentUploadTransportStatus.CancelledBeforeSubmission:
                            throw new AdvancedChatSubmissionStopped(ChatCancelled("chatAttachmentSend"));
                        case ChatAttachmentUploadTransportStatus.Unsupported:
                            throw new AdvancedChatSubmissionStopped(ChatUnsupported("chatAttachmentSend"));
                        case ChatAttachmentUploadTransportStatus.ConfirmedFailure:
                            var category = submission.ErrorCategory ?? MutationErrorCategory.Server;
                            throw new AdvancedChatSubmissionStopped(new(1,
                                category == MutationErrorCategory.Permission ? MutationResultStatus.PermissionDenied : MutationResultStatus.ConfirmedFailure,
                                "chatAttachmentSend", true, false, new(0, 1, 0), category, diagnosticTag: "chat.attachment-send.rejected"));
                        case ChatAttachmentUploadTransportStatus.CancellationRequestedAfterSubmission:
                            throw new OperationCanceledException();
                        default: throw new IOException("chat.attachment-send.unavailable-result");
                    }
                },
                async (state, token) =>
                {
                    if (!state.Submitted)
                    {
                        content = await normalized.Attachment.OpenReadAsync(token).ConfigureAwait(false);
                        if (!content.CanRead || content.CanSeek && content.Length - content.Position != normalized.Attachment.Length)
                            throw new InvalidDataException("chat.attachment-send.source-changed");
                        state.OwnerId = _chatCurrentUserId; return (false, null);
                    }
                    if (!state.Accepted || state.CandidateId is null) return (false, null);
                    await RequireAdvancedConversationAsync(normalized.ConversationId, null, token).ConfigureAwait(false);
                    var message = await LocateMessageAsync(normalized.ConversationId, state.CandidateId, null, token).ConfigureAwait(false);
                    var confirmed = message is { IsThreadReply: false, EncryptionState: ChatEncryptionState.NotEncrypted } &&
                        message.IsFromCurrentUser != false && message.SenderId != "unknown" && (state.OwnerId is null || message.SenderId == state.OwnerId) &&
                        (message.Text ?? "") == normalized.Text && message.Attachments.Count == 1 &&
                        message.Attachments[0].FileName == normalized.Attachment.FileName && message.Attachments[0].SizeBytes == normalized.Attachment.Length;
                    return (confirmed, confirmed ? message! with { IsFromCurrentUser = true } : null);
                }, cancellationToken, requiredVersion: ChatAttachmentSendVersion).ConfigureAwait(false);
            var status = result.Result;
            if (status.Status == MutationResultStatus.ConfirmedFailure && status.ErrorCategory == MutationErrorCategory.Permission)
                status = new(1, MutationResultStatus.PermissionDenied, status.Operation, status.Submitted, status.RequiresRefresh,
                    status.Counts, status.ErrorCategory, status.LocalizationKey, status.DiagnosticTag);
            return new(status, normalized.ConversationId, request.ClientRequestId, result.Value as ChatMessage);
        }
        finally { if (content is not null) await content.DisposeAsync().ConfigureAwait(false); }
    }
}
