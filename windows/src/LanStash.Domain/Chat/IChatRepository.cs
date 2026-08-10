namespace LanStash.Domain;

public interface IChatRepository
{
    Guid ProfileId { get; }
    ChatAvailability Availability { get; }

    Task<IReadOnlyList<ChatUser>> ListUsersAsync(
        CancellationToken cancellationToken = default);

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
}
