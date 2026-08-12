namespace LanStash.Domain;

public interface IChatRepository
{
    Guid ProfileId { get; }
    ChatAvailability Availability { get; }

    Task<IReadOnlyList<ChatUser>> ListUsersAsync(
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<ChatUser>> ListConversationMembersAsync(
        string conversationId,
        CancellationToken cancellationToken = default);

    Task<IReadOnlyList<ChatPinnedMessage>> ListPinnedMessagesAsync(
        string conversationId,
        CancellationToken cancellationToken = default) =>
        Task.FromException<IReadOnlyList<ChatPinnedMessage>>(
            new NotSupportedException("Chat pinned message reading is not implemented by this repository."));

    Task<IReadOnlyList<ChatConversation>> ListConversationsAsync(
        CancellationToken cancellationToken = default);

    Task<ChatMessagePage> ListMessagesAsync(
        string conversationId,
        string? beforeCursor,
        int limit,
        CancellationToken cancellationToken = default);

    Task<ChatTextSendOutcome> SendTextAsync(
        ChatTextSendRequest request,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// 仅表示单附件发送能力。未实现的旧仓储应由可用性门禁保持该能力关闭。
    /// </summary>
    Task<ChatAttachmentSendOutcome> SendAttachmentAsync(
        ChatAttachmentSendRequest request,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default) =>
        Task.FromException<ChatAttachmentSendOutcome>(
            new NotSupportedException("Chat attachment sending is not implemented by this repository."));

    Task<ChatConversationCreateOutcome> OpenDirectConversationAsync(
        ChatDirectConversationRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(ChatConversationCreateUnsupported(request.ClientRequestId, "chatDirectConversation"));

    Task<ChatConversationCreateOutcome> CreatePrivateGroupAsync(
        ChatPrivateGroupCreateRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(ChatConversationCreateUnsupported(request.ClientRequestId, "chatPrivateGroupCreate"));

    Task<ChatAttachmentThumbnail> ReadAttachmentThumbnailAsync(
        string messageId,
        ChatAttachment attachment,
        CancellationToken cancellationToken = default) =>
        Task.FromException<ChatAttachmentThumbnail>(
            new NotSupportedException("Chat attachment thumbnail reading is not implemented by this repository."));

    /// <summary>
    /// 目标流由调用方创建和关闭，并必须是空的可写可定位流；附件须包含非负大小以校验长度。
    /// 接口从不接收或构造本机路径。
    /// </summary>
    Task<ChatAttachmentContentReadResult> SaveAttachmentAsync(
        string messageId,
        ChatAttachment attachment,
        Stream destination,
        IProgress<long>? progress = null,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new ChatAttachmentContentReadResult(
            ChatAttachmentContentReadStatus.Unsupported,
            BytesWritten: 0,
            DestinationWasCleared: false,
            ErrorCategory: MutationErrorCategory.Unsupported,
            DiagnosticTag: "chat.attachment-save.unsupported"));

    private static ChatConversationCreateOutcome ChatConversationCreateUnsupported(
        Guid clientRequestId,
        string operation) => new(
            new MutationResult(
                1,
                MutationResultStatus.Unsupported,
                operation,
                submitted: false,
                requiresRefresh: false,
                new MutationResultCounts(0, 1, 0),
                MutationErrorCategory.Unsupported,
                diagnosticTag: "chat.conversation-create.unsupported"),
            clientRequestId,
            ConfirmedConversation: null);

    // ── 消息删除 ──

    Task<MutationResult> DeleteOwnMessageAsync(
        ChatDeleteMessageRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(
            1, MutationResultStatus.Unsupported, "deleteOwnMessage",
            submitted: false, requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: "chat.deleteOwnMessage"));

    // ── 会话关闭 ──

    Task<MutationResult> CloseConversationAsync(
        ChatCloseConversationRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(
            1, MutationResultStatus.Unsupported, "closeConversation",
            submitted: false, requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: "chat.closeConversation"));

    // ── 提醒 ──

    Task<ChatReminderSetOutcome> SetReminderAsync(
        string messageId,
        string conversationId,
        DateTimeOffset remindAt,
        Guid clientRequestId,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new ChatReminderSetOutcome(
            new MutationResult(1, MutationResultStatus.Unsupported, "setReminder",
                submitted: false, requiresRefresh: false,
                new MutationResultCounts(0, 1, 0), MutationErrorCategory.Unsupported,
                diagnosticTag: "chat.setReminder.unsupported"),
            messageId, conversationId, clientRequestId, ConfirmedReminder: null));

    Task<IReadOnlyList<ChatReminder>> ListRemindersAsync(
        string conversationId,
        CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ChatReminder>>([]);

    Task<MutationResult> DeleteReminderAsync(
        string messageId,
        string conversationId,
        Guid clientRequestId,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(
            1, MutationResultStatus.Unsupported, "deleteReminder",
            submitted: false, requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: "chat.deleteReminder"));

    // ── 定时消息 ──

    Task<ChatScheduledMessageCreateOutcome> CreateScheduledMessageAsync(
        ChatScheduledMessageDraft draft,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new ChatScheduledMessageCreateOutcome(
            new MutationResult(1, MutationResultStatus.Unsupported, "createScheduledMessage",
                submitted: false, requiresRefresh: false,
                new MutationResultCounts(0, 1, 0), MutationErrorCategory.Unsupported,
                diagnosticTag: "chat.createScheduledMessage.unsupported"),
            draft.ClientRequestId, ConfirmedMessage: null));

    Task<IReadOnlyList<ChatScheduledMessage>> ListScheduledMessagesAsync(
        string conversationId,
        CancellationToken cancellationToken = default) =>
        Task.FromResult<IReadOnlyList<ChatScheduledMessage>>([]);

    Task<MutationResult> DeleteScheduledMessageAsync(
        string scheduledId,
        string conversationId,
        Guid clientRequestId,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(
            1, MutationResultStatus.Unsupported, "deleteScheduledMessage",
            submitted: false, requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: "chat.deleteScheduledMessage"));

    // ── 投票 ──

    Task<ChatPollCreateOutcome> CreatePollAsync(
        ChatPollDraft draft,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new ChatPollCreateOutcome(
            new MutationResult(1, MutationResultStatus.Unsupported, "createPoll",
                submitted: false, requiresRefresh: false,
                new MutationResultCounts(0, 1, 0), MutationErrorCategory.Unsupported,
                diagnosticTag: "chat.createPoll.unsupported"),
            draft.ClientRequestId, ConfirmedMessage: null));

    // ── 消息转发 ──

    Task<MutationResult> ForwardMessageAsync(
        ChatForwardRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(
            1, MutationResultStatus.Unsupported, "forwardMessage",
            submitted: false, requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Unsupported,
            diagnosticTag: "chat.forwardMessage"));
}
