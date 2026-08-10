using System.Text.Json;
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int ChatAttachmentSendVersion = 5;
    private const int ChatAttachmentFileReadVersion = 2;
    private const int ChatAttachmentReadbackLimit = 50;

    private readonly Dictionary<Guid, PendingChatAttachmentSendReview> _pendingChatAttachmentSends = [];

    private bool HasAttachmentMessageSendContract =>
        HasReadableChatContract &&
        HasExactChatVersion("SYNO.Chat.Post", ChatAttachmentSendVersion);

    private bool HasAttachmentBinaryReadContract =>
        HasReadableChatContract &&
        HasExactChatVersion("SYNO.Chat.Post.File", ChatAttachmentFileReadVersion) &&
        _capabilities.TryGetValue("SYNO.Chat.Post.File", out var capability) &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

    public async Task<ChatAttachmentSendOutcome> SendAttachmentAsync(
        ChatAttachmentSendRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var conversationId = request.ConversationId?.Trim() ?? string.Empty;
        var text = request.Text?.Trim() ?? string.Empty;
        var normalizedRequest = request with
        {
            ConversationId = conversationId,
            Text = text,
        };
        if (cancellationToken.IsCancellationRequested)
        {
            return ChatAttachmentSendOutcome(
                normalizedRequest,
                MutationResultStatus.CancelledBeforeSubmission,
                submitted: false,
                requiresRefresh: false,
                confirmedMessage: null,
                errorCategory: null,
                diagnosticTag: "chat.attachment-send.cancelled-before");
        }
        if (request.ClientRequestId == Guid.Empty ||
            !ValidChatAttachmentInput(normalizedRequest) ||
            _profile.Id != _session.ProfileId)
        {
            return ChatAttachmentSendOutcome(
                normalizedRequest,
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                confirmedMessage: null,
                errorCategory: MutationErrorCategory.Validation,
                diagnosticTag: "chat.attachment-send.invalid-input");
        }
        if (!HasAttachmentMessageSendContract)
        {
            return ChatAttachmentSendOutcome(
                normalizedRequest,
                MutationResultStatus.Unsupported,
                submitted: false,
                requiresRefresh: false,
                confirmedMessage: null,
                errorCategory: MutationErrorCategory.Unsupported,
                diagnosticTag: "chat.attachment-send.unsupported");
        }

        if (_pendingChatAttachmentSends.TryGetValue(request.ClientRequestId, out var pendingReview))
        {
            return await FinishPendingChatAttachmentSendAsync(
                pendingReview,
                MutationResultStatus.SubmittedButUnverified).ConfigureAwait(false);
        }

        IReadOnlyList<ChatConversation> conversations;
        try
        {
            conversations = await ListConversationsAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ChatAttachmentSendOutcome(
                normalizedRequest,
                MutationResultStatus.CancelledBeforeSubmission,
                submitted: false,
                requiresRefresh: false,
                confirmedMessage: null,
                errorCategory: null,
                diagnosticTag: "chat.attachment-send.cancelled-before");
        }
        catch (DsmException error)
        {
            return ChatAttachmentSendOutcome(
                normalizedRequest,
                error.Code == 105
                    ? MutationResultStatus.PermissionDenied
                    : MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                confirmedMessage: null,
                errorCategory: ChatTextSendErrorCategory(error),
                diagnosticTag: "chat.attachment-send.preflight-failed");
        }

        var conversation = conversations.FirstOrDefault(value =>
            string.Equals(value.Id, conversationId, StringComparison.Ordinal));
        if (conversation is null || conversation.IsEncrypted)
        {
            return ChatAttachmentSendOutcome(
                normalizedRequest,
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                confirmedMessage: null,
                errorCategory: MutationErrorCategory.Validation,
                diagnosticTag: conversation is null
                    ? "chat.attachment-send.conversation-missing"
                    : "chat.attachment-send.encrypted-conversation");
        }

        Stream content;
        try
        {
            content = await normalizedRequest.Attachment.OpenReadAsync(cancellationToken)
                .ConfigureAwait(false);
            if (!content.CanRead)
            {
                content.Dispose();
                return ChatAttachmentSendOutcome(
                    normalizedRequest,
                    MutationResultStatus.ConfirmedFailure,
                    submitted: false,
                    requiresRefresh: false,
                    confirmedMessage: null,
                    errorCategory: MutationErrorCategory.Validation,
                    diagnosticTag: "chat.attachment-send.source-unavailable");
            }
        }
        catch (OperationCanceledException)
        {
            return ChatAttachmentSendOutcome(
                normalizedRequest,
                MutationResultStatus.CancelledBeforeSubmission,
                submitted: false,
                requiresRefresh: false,
                confirmedMessage: null,
                errorCategory: null,
                diagnosticTag: "chat.attachment-send.cancelled-before");
        }
        catch (Exception error) when (
            error is DsmException or IOException or UnauthorizedAccessException or NotSupportedException)
        {
            return ChatAttachmentSendOutcome(
                normalizedRequest,
                MutationResultStatus.ConfirmedFailure,
                submitted: false,
                requiresRefresh: false,
                confirmedMessage: null,
                errorCategory: MutationErrorCategory.Validation,
                diagnosticTag: "chat.attachment-send.source-unavailable");
        }

        using (content)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return ChatAttachmentSendOutcome(
                    normalizedRequest,
                    MutationResultStatus.CancelledBeforeSubmission,
                    submitted: false,
                    requiresRefresh: false,
                    confirmedMessage: null,
                    errorCategory: null,
                    diagnosticTag: "chat.attachment-send.cancelled-before");
            }

            var review = new PendingChatAttachmentSendReview(
                _profile.Id,
                conversationId,
                text,
                normalizedRequest.Attachment.FileName,
                normalizedRequest.Attachment.Length,
                request.ClientRequestId,
                CandidateMessageId: null);
            try
            {
                var capability = _capabilities["SYNO.Chat.Post"] with
                {
                    MinVersion = ChatAttachmentSendVersion,
                    MaxVersion = ChatAttachmentSendVersion,
                };
                var submission = await _api.SendChatAttachmentAsync(
                    _profile,
                    _session,
                    capability,
                    new ChatAttachmentUploadRequest(
                        conversationId,
                        text,
                        normalizedRequest.Attachment.FileName,
                        content,
                        normalizedRequest.Attachment.Length),
                    progress,
                    cancellationToken).ConfigureAwait(false);
                review = review with { CandidateMessageId = submission.CandidateMessageId };
                return await HandleChatAttachmentSubmissionAsync(
                    normalizedRequest,
                    review,
                    submission).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                _pendingChatAttachmentSends[request.ClientRequestId] = review;
                return ChatAttachmentSendOutcome(
                    normalizedRequest,
                    MutationResultStatus.CancellationRequestedAfterSubmission,
                    submitted: true,
                    requiresRefresh: true,
                    confirmedMessage: null,
                    errorCategory: MutationErrorCategory.Network,
                    diagnosticTag: "chat.attachment-send.cancelled-after");
            }
            catch (Exception error) when (
                error is DsmException or JsonException or IOException or HttpRequestException)
            {
                _pendingChatAttachmentSends[request.ClientRequestId] = review;
                return ChatAttachmentSendOutcome(
                    normalizedRequest,
                    MutationResultStatus.SubmittedButUnverified,
                    submitted: true,
                    requiresRefresh: true,
                    confirmedMessage: null,
                    errorCategory: MutationErrorCategory.Unknown,
                    diagnosticTag: "chat.attachment-send.submitted-unverified");
            }
        }
    }

    public async Task<ChatAttachmentThumbnail> ReadAttachmentThumbnailAsync(
        string messageId,
        ChatAttachment attachment,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(attachment);
        var normalizedMessageId = NormalizeChatPostId(messageId);
        if (attachment.Kind != ChatAttachmentKind.Image)
        {
            throw new ArgumentException(
                "Chat attachment thumbnails are restricted to image attachments.",
                nameof(attachment));
        }

        EnsureAttachmentBinaryReadContract();
        var response = await _api.ReadBinaryAsync(
            _profile,
            _session,
            AttachmentFileCapability(),
            "thumbnail",
            new Dictionary<string, string>
            {
                ["post_id"] = normalizedMessageId,
                ["type"] = "sm",
            },
            "image/",
            ChatAttachmentThumbnail.MaximumBytes,
            cancellationToken).ConfigureAwait(false);
        return ValidChatAttachmentThumbnail(response);
    }

    public async Task<ChatAttachmentContentReadResult> SaveAttachmentAsync(
        string messageId,
        ChatAttachment attachment,
        Stream destination,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default)
    {
        if (!TryNormalizeChatPostId(messageId, out var normalizedMessageId) ||
            attachment?.SizeBytes is not long expectedLength ||
            expectedLength < 0 ||
            destination is null ||
            !IsEmptyWritableChatAttachmentDestination(destination) ||
            _profile.Id != _session.ProfileId)
        {
            return new ChatAttachmentContentReadResult(
                ChatAttachmentContentReadStatus.Failed,
                BytesWritten: 0,
                DestinationWasCleared: false,
                ErrorCategory: MutationErrorCategory.Validation,
                DiagnosticTag: "chat.attachment-save.invalid-input");
        }
        if (!HasAttachmentBinaryReadContract)
        {
            return new ChatAttachmentContentReadResult(
                ChatAttachmentContentReadStatus.Unsupported,
                BytesWritten: 0,
                DestinationWasCleared: false,
                ErrorCategory: MutationErrorCategory.Unsupported,
                DiagnosticTag: "chat.attachment-save.unsupported");
        }

        return await _api.ReadChatAttachmentContentAsync(
            _profile,
            _session,
            AttachmentFileCapability(),
            new ChatAttachmentContentReadRequest(
                normalizedMessageId,
                destination,
                expectedLength),
            progress,
            cancellationToken).ConfigureAwait(false);
    }

    private IReadOnlySet<ChatWriteFeature> SupportedChatWriteFeatures()
    {
        var features = new HashSet<ChatWriteFeature>();
        if (HasTextMessageSendContract)
        {
            features.Add(ChatWriteFeature.TextMessage);
        }
        if (HasAttachmentMessageSendContract)
        {
            features.Add(ChatWriteFeature.AttachmentMessage);
        }
        return features;
    }

    private IReadOnlySet<ChatReadFeature> SupportedChatReadFeatures()
    {
        var features = new HashSet<ChatReadFeature>(ChatReadFeatures);
        if (HasAttachmentBinaryReadContract)
        {
            features.Add(ChatReadFeature.AttachmentThumbnail);
            features.Add(ChatReadFeature.AttachmentContent);
        }
        return features;
    }

    private static bool ValidChatAttachmentInput(ChatAttachmentSendRequest request)
    {
        var attachment = request.Attachment;
        return !string.IsNullOrWhiteSpace(request.ConversationId) &&
            request.ConversationId == request.ConversationId.Trim() &&
            request.ConversationId.IndexOfAny(['\r', '\n', '\0']) < 0 &&
            (request.Text ?? string.Empty).IndexOf('\0') < 0 &&
            attachment is not null &&
            !string.IsNullOrWhiteSpace(attachment.FileName) &&
            attachment.FileName == attachment.FileName.Trim() &&
            attachment.FileName is not ("." or "..") &&
            attachment.FileName.IndexOfAny(['/', '\\', '"', '\r', '\n', '\0']) < 0 &&
            attachment.Length >= 0 &&
            attachment.OpenReadAsync is not null;
    }

    private void EnsureAttachmentBinaryReadContract()
    {
        EnsureReadableChatContract();
        if (!HasAttachmentBinaryReadContract)
        {
            throw new DsmException(
                UserText.Key("WinShared11a208e43c34b77c"),
                UserText.Key("WinShared371d84f48836296f"),
                102);
        }
    }

    private ApiCapability AttachmentFileCapability() =>
        _capabilities["SYNO.Chat.Post.File"] with
        {
            MinVersion = ChatAttachmentFileReadVersion,
            MaxVersion = ChatAttachmentFileReadVersion,
        };

    private static string NormalizeChatPostId(string? messageId)
    {
        if (!TryNormalizeChatPostId(messageId, out var normalized))
        {
            throw new ArgumentException("The Chat message ID is invalid.", nameof(messageId));
        }
        return normalized;
    }

    private static bool TryNormalizeChatPostId(string? messageId, out string normalized)
    {
        normalized = messageId?.Trim() ?? string.Empty;
        return normalized.Length > 0 &&
            normalized.IndexOfAny(['\r', '\n', '\0']) < 0;
    }

    private static bool IsEmptyWritableChatAttachmentDestination(Stream destination)
    {
        try
        {
            return destination.CanWrite &&
                destination.CanSeek &&
                destination.Position == 0 &&
                destination.Length == 0;
        }
        catch (Exception error) when (
            error is IOException or NotSupportedException or ObjectDisposedException)
        {
            return false;
        }
    }

    private static ChatAttachmentThumbnail ValidChatAttachmentThumbnail(DsmBinaryResponse response)
    {
        if (response.Bytes.Length == 0)
        {
            throw new DsmBinaryResponseException(
                DsmBinaryResponseFailure.EmptyBody,
                "The Chat attachment thumbnail is empty.");
        }
        if (response.Bytes.Length > ChatAttachmentThumbnail.MaximumBytes)
        {
            throw new DsmBinaryResponseException(
                DsmBinaryResponseFailure.ResponseTooLarge,
                "The Chat attachment thumbnail exceeds the configured byte limit.");
        }
        if (string.IsNullOrWhiteSpace(response.MediaType) ||
            !response.MediaType.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
        {
            throw new DsmBinaryResponseException(
                DsmBinaryResponseFailure.UnexpectedMediaType,
                "The Chat attachment thumbnail response is not an image.");
        }
        return new ChatAttachmentThumbnail(response.Bytes, response.MediaType);
    }

    private async Task<ChatAttachmentSendOutcome> HandleChatAttachmentSubmissionAsync(
        ChatAttachmentSendRequest request,
        PendingChatAttachmentSendReview review,
        ChatAttachmentUploadTransportResult submission)
    {
        switch (submission.Status)
        {
            case ChatAttachmentUploadTransportStatus.CancelledBeforeSubmission:
                return ChatAttachmentSendOutcome(
                    request,
                    MutationResultStatus.CancelledBeforeSubmission,
                    submitted: false,
                    requiresRefresh: false,
                    confirmedMessage: null,
                    errorCategory: null,
                    diagnosticTag: submission.DiagnosticTag ?? "chat.attachment-send.cancelled-before");
            case ChatAttachmentUploadTransportStatus.Unsupported:
                return ChatAttachmentSendOutcome(
                    request,
                    MutationResultStatus.Unsupported,
                    submitted: false,
                    requiresRefresh: false,
                    confirmedMessage: null,
                    errorCategory: MutationErrorCategory.Unsupported,
                    diagnosticTag: submission.DiagnosticTag ?? "chat.attachment-send.unsupported");
            case ChatAttachmentUploadTransportStatus.ConfirmedFailure:
            {
                var category = submission.ErrorCategory ?? MutationErrorCategory.Server;
                var status = category switch
                {
                    MutationErrorCategory.Permission => MutationResultStatus.PermissionDenied,
                    MutationErrorCategory.Unsupported => MutationResultStatus.Unsupported,
                    _ => MutationResultStatus.ConfirmedFailure,
                };
                return ChatAttachmentSendOutcome(
                    request,
                    status,
                    submitted: true,
                    requiresRefresh: false,
                    confirmedMessage: null,
                    errorCategory: category,
                    diagnosticTag: submission.DiagnosticTag ?? "chat.attachment-send.confirmed-failure");
            }
            case ChatAttachmentUploadTransportStatus.Accepted:
                _pendingChatAttachmentSends[review.ClientRequestId] = review;
                return await FinishPendingChatAttachmentSendAsync(
                    review,
                    MutationResultStatus.SubmittedButUnverified).ConfigureAwait(false);
            case ChatAttachmentUploadTransportStatus.CancellationRequestedAfterSubmission:
                _pendingChatAttachmentSends[review.ClientRequestId] = review;
                return ChatAttachmentSendOutcome(
                    request,
                    MutationResultStatus.CancellationRequestedAfterSubmission,
                    submitted: true,
                    requiresRefresh: true,
                    confirmedMessage: null,
                    errorCategory: submission.ErrorCategory ?? MutationErrorCategory.Network,
                    diagnosticTag: submission.DiagnosticTag ?? "chat.attachment-send.cancelled-after");
            case ChatAttachmentUploadTransportStatus.SubmittedButUnverified:
            default:
                _pendingChatAttachmentSends[review.ClientRequestId] = review;
                return ChatAttachmentSendOutcome(
                    request,
                    MutationResultStatus.SubmittedButUnverified,
                    submitted: true,
                    requiresRefresh: true,
                    confirmedMessage: null,
                    errorCategory: submission.ErrorCategory ?? MutationErrorCategory.Unknown,
                    diagnosticTag: submission.DiagnosticTag ?? "chat.attachment-send.submitted-unverified");
        }
    }

    private async Task<ChatAttachmentSendOutcome> FinishPendingChatAttachmentSendAsync(
        PendingChatAttachmentSendReview review,
        MutationResultStatus submittedStatus)
    {
        try
        {
            var page = await ListMessagesAsync(
                review.ConversationId,
                null,
                ChatAttachmentReadbackLimit,
                CancellationToken.None).ConfigureAwait(false);
            var confirmed = page.Messages.FirstOrDefault(message =>
                string.Equals(message.Id, review.CandidateMessageId, StringComparison.Ordinal) &&
                string.Equals(message.ConversationId, review.ConversationId, StringComparison.Ordinal) &&
                message.IsFromCurrentUser == true &&
                string.Equals(message.Text ?? string.Empty, review.Text, StringComparison.Ordinal) &&
                message.Attachments.Count == 1 &&
                string.Equals(
                    message.Attachments[0].FileName,
                    review.FileName,
                    StringComparison.Ordinal) &&
                message.Attachments[0].SizeBytes == review.Length);
            if (confirmed is not null)
            {
                _pendingChatAttachmentSends.Remove(review.ClientRequestId);
                return ChatAttachmentSendOutcome(
                    review.ConversationId,
                    review.ClientRequestId,
                    MutationResultStatus.ConfirmedSuccess,
                    submitted: true,
                    requiresRefresh: false,
                    confirmedMessage: confirmed,
                    errorCategory: null,
                    diagnosticTag: "chat.attachment-send.confirmed");
            }
        }
        catch (Exception error) when (
            error is DsmException or JsonException or IOException or HttpRequestException or
                OperationCanceledException)
        {
            // 结果未知时保留同一请求的核对记录，后续只能回读，不能自动重传附件。
        }

        return ChatAttachmentSendOutcome(
            review.ConversationId,
            review.ClientRequestId,
            submittedStatus,
            submitted: true,
            requiresRefresh: true,
            confirmedMessage: null,
            errorCategory: MutationErrorCategory.Unknown,
            diagnosticTag: submittedStatus == MutationResultStatus.CancellationRequestedAfterSubmission
                ? "chat.attachment-send.cancelled-after"
                : "chat.attachment-send.submitted-unverified");
    }

    private static ChatAttachmentSendOutcome ChatAttachmentSendOutcome(
        ChatAttachmentSendRequest request,
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh,
        ChatMessage? confirmedMessage,
        MutationErrorCategory? errorCategory,
        string diagnosticTag) =>
        ChatAttachmentSendOutcome(
            request.ConversationId,
            request.ClientRequestId,
            status,
            submitted,
            requiresRefresh,
            confirmedMessage,
            errorCategory,
            diagnosticTag);

    private static ChatAttachmentSendOutcome ChatAttachmentSendOutcome(
        string conversationId,
        Guid clientRequestId,
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh,
        ChatMessage? confirmedMessage,
        MutationErrorCategory? errorCategory,
        string diagnosticTag)
    {
        var succeeded = status == MutationResultStatus.ConfirmedSuccess ? 1 : 0;
        var failed = status is MutationResultStatus.ConfirmedFailure or
            MutationResultStatus.PermissionDenied or MutationResultStatus.Unsupported ? 1 : 0;
        var unknown = status is MutationResultStatus.SubmittedButUnverified or
            MutationResultStatus.CancellationRequestedAfterSubmission ? 1 : 0;
        return new(
            new MutationResult(
                1,
                status,
                "chatAttachmentSend",
                submitted,
                requiresRefresh,
                new MutationResultCounts(succeeded, failed, unknown),
                errorCategory,
                localizationKey: $"chat.attachment-send.{status.ToString().ToLowerInvariant()}",
                diagnosticTag),
            conversationId,
            clientRequestId,
            confirmedMessage);
    }

    private sealed record PendingChatAttachmentSendReview(
        Guid ProfileId,
        string ConversationId,
        string Text,
        string FileName,
        long Length,
        Guid ClientRequestId,
        string? CandidateMessageId);
}
