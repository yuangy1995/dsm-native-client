namespace LanStash.Domain;

public interface IChatRepository
{
    Guid ProfileId { get; }
    /// <summary>不含凭据的连接/账号摘要，用于隔离本机草稿及未知发送；旧合成提供者可省略。</summary>
    string? AccountIdentity => null;
    ChatAvailability Availability { get; }

    /// <summary>旧提供者默认不提供实时流，调用方继续轮询；取消枚举须释放连接。</summary>
    IAsyncEnumerable<ChatRealtimeEvent> ObserveRealtimeAsync(CancellationToken cancellationToken = default) =>
        ChatRealtimeStreams.Empty(cancellationToken);

    /// <summary>只读准备高级功能；按实际 API 能力与账号权限开放，不按系统版本白名单判断。</summary>
    Task<ChatAvailability> PrepareAdvancedFeaturesAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult(Availability);

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

    /// <summary>按现有历史分页读取指定消息，供确认前刷新；不代表新增 NAS get 接口。</summary>
    Task<ChatMessage> GetMessageAsync(string conversationId, string messageId, CancellationToken cancellationToken = default) =>
        Task.FromException<ChatMessage>(new NotSupportedException("Chat message lookup is not implemented."));

    Task<ChatSearchPage> SearchMessagesAsync(string query, string? conversationId, string? cursor, int limit,
        CancellationToken cancellationToken = default) =>
        Task.FromException<ChatSearchPage>(new NotSupportedException("chat.search.unsupported"));

    /// <summary>按已记录的 Post.list 定位原消息；线程编号与历史游标分开传递。</summary>
    Task<ChatMessage?> LocateMessageAsync(string conversationId, string messageId, string? threadId = null,
        CancellationToken cancellationToken = default) =>
        Task.FromException<ChatMessage?>(new NotSupportedException("chat.locate.unsupported"));

    Task<ChatMessagePage> ListRepliesAsync(string conversationId, string threadId, string? beforeCursor, int limit,
        CancellationToken cancellationToken = default) =>
        Task.FromException<ChatMessagePage>(new NotSupportedException("chat.thread.unsupported"));

    Task<ChatEditingPolicy> GetEditingPolicyAsync(CancellationToken cancellationToken = default) =>
        Task.FromException<ChatEditingPolicy>(new NotSupportedException("chat.edit.unsupported"));

    Task<ChatMessageUpdateOutcome> EditMessageAsync(ChatEditMessageRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(UnsupportedMessageUpdate("editMessage"));

    Task<ChatMessage> GetPollMessageAsync(ChatMessage original, CancellationToken cancellationToken = default) =>
        Task.FromException<ChatMessage>(new NotSupportedException("chat.vote.unsupported"));

    Task<ChatMessageUpdateOutcome> VoteAsync(ChatVoteRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(UnsupportedMessageUpdate("vote"));

    Task<ChatConversation> MarkReadAsync(string conversationId, string messageId, DateTimeOffset through,
        CancellationToken cancellationToken = default) =>
        Task.FromException<ChatConversation>(new NotSupportedException("chat.read.unsupported"));

    Task MarkThreadReadAsync(string conversationId, string threadId, string lastMessageId,
        CancellationToken cancellationToken = default) =>
        Task.FromException(new NotSupportedException("chat.thread-read.unsupported"));

    private static ChatMessageUpdateOutcome UnsupportedMessageUpdate(string operation) => new(
        new MutationResult(1, MutationResultStatus.Unsupported, operation, false, false,
            new MutationResultCounts(0, 1, 0), MutationErrorCategory.Unsupported,
            diagnosticTag: "chat.interaction.unsupported"), null);

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

    /// <summary>带确认时的提醒基线；新实现须在提交前核对该基线。</summary>
    Task<MutationResult> DeleteReminderAsync(ChatReminder expected, Guid clientRequestId,
        CancellationToken cancellationToken = default) =>
        DeleteReminderAsync(expected.MessageId, expected.ConversationId, clientRequestId, cancellationToken);

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

    /// <summary>带确认时的消息内容和时间基线，避免取消已被其他客户端修改的定时消息。</summary>
    Task<MutationResult> DeleteScheduledMessageAsync(ChatScheduledMessage expected, Guid clientRequestId,
        CancellationToken cancellationToken = default) =>
        DeleteScheduledMessageAsync(expected.Id, expected.ConversationId, clientRequestId, cancellationToken);

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

    Task<MutationResult> SetMessagePinnedAsync(ChatPinMessageRequest request, CancellationToken cancellationToken = default) =>
        Task.FromResult(new MutationResult(1, MutationResultStatus.Unsupported, "setMessagePinned", false, false,
            new MutationResultCounts(0, 1, 0), MutationErrorCategory.Unsupported, diagnosticTag: "chat.pin.unsupported"));

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
