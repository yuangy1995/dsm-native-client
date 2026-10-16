
using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private const int ChatAttachmentSendVersion = 5;
    private const int ChatAttachmentFileReadVersion = 2;




    private bool HasAttachmentMessageSendContract =>
        HasReadableChatContract &&
        HasExactChatVersion("SYNO.Chat.Post", ChatAttachmentSendVersion);

    private bool HasAttachmentBinaryReadContract =>
        HasReadableChatContract &&
        HasExactChatVersion("SYNO.Chat.Post.File", ChatAttachmentFileReadVersion) &&
        _capabilities.TryGetValue("SYNO.Chat.Post.File", out var capability) &&
        string.Equals(capability.RequestFormat, "FORM", StringComparison.OrdinalIgnoreCase);

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
        if (!HasBoundChatSession) return features;
        if (HasTextMessageSendContract)
        {
            features.Add(ChatWriteFeature.TextMessage);
            features.Add(ChatWriteFeature.ThreadedReplies);
        }
        if (HasAttachmentMessageSendContract)
        {
            features.Add(ChatWriteFeature.AttachmentMessage);
        }
        if (HasDirectConversationCreateContract)
        {
            features.Add(ChatWriteFeature.DirectConversation);
        }
        if (HasPrivateGroupCreateContract)
        {
            features.Add(ChatWriteFeature.PrivateGroup);
        }
        if (HasDeleteOwnMessageContract)
        {
            features.Add(ChatWriteFeature.DeleteOwnMessage);
        }
        if (HasBoundChatSession)
        {
            if (HasAdvancedApi("SYNO.Chat.Post.Reminder")) features.Add(ChatWriteFeature.Reminders);
            if (HasAdvancedApi("SYNO.Chat.Post.Schedule")) features.Add(ChatWriteFeature.ScheduledMessages);
            if (HasAdvancedApi("SYNO.Chat.Post.Vote")) features.Add(ChatWriteFeature.Polls);
            if (HasAdvancedApi("SYNO.Chat.Post.Vote")) features.Add(ChatWriteFeature.PollVoting);
            if (HasAdvancedApi("SYNO.Chat.Post", 8) && HasAdvancedApi("SYNO.Chat.Admin.Setting", 3)) features.Add(ChatWriteFeature.MessageEditing);
            if (HasAdvancedApi("SYNO.Chat.Channel", 2)) features.Add(ChatWriteFeature.ReadSynchronization);
            if (HasAdvancedApi("SYNO.Chat.Channel", 5)) features.Add(ChatWriteFeature.CloseConversation);
            if (HasAdvancedApi("SYNO.Chat.Post", 5)) { features.Add(ChatWriteFeature.ForwardMessage); features.Add(ChatWriteFeature.PinnedMessages); }
        }
        return features;
    }

    private IReadOnlySet<ChatReadFeature> SupportedChatReadFeatures()
    {
        var features = new HashSet<ChatReadFeature>(ChatReadFeatures);
        features.Add(ChatReadFeature.MessageSearch);
        features.Add(ChatReadFeature.ThreadedReplies);
        if (HasConversationMembersContract)
        {
            features.Add(ChatReadFeature.Members);
        }
        if (HasPinnedMessageReadContract)
        {
            features.Add(ChatReadFeature.PinnedMessages);
        }
        if (HasAttachmentBinaryReadContract)
        {
            features.Add(ChatReadFeature.AttachmentThumbnail);
            features.Add(ChatReadFeature.AttachmentContent);
        }
        if (HasAdvancedApi("SYNO.Chat.Post.Reminder")) features.Add(ChatReadFeature.Reminders);
        if (HasAdvancedApi("SYNO.Chat.Post.Schedule")) features.Add(ChatReadFeature.ScheduledMessages);
        if (HasAdvancedApi("SYNO.Chat.Post.Vote")) features.Add(ChatReadFeature.Polls);
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

}
