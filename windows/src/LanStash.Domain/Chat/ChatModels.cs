namespace LanStash.Domain;

public enum ChatAvailabilityStatus
{
    Unavailable,
    RequiresValidation,
    Available,
}

public enum ChatReadFeature
{
    Users,
    Conversations,
    Members,
    PinnedMessages,
    Messages,
    AttachmentMetadata,
    AttachmentThumbnail,
    AttachmentContent,
    EncryptedContentMetadata,
}

public enum ChatWriteFeature
{
    TextMessage,
    AttachmentMessage,
    DirectConversation,
    PrivateGroup,
}

public sealed record ChatAvailability(
    ChatAvailabilityStatus Status,
    IReadOnlySet<ChatReadFeature> SupportedFeatures,
    IReadOnlySet<ChatWriteFeature> SupportedWriteFeatures)
{
    public ChatAvailability(
        ChatAvailabilityStatus status,
        IReadOnlySet<ChatReadFeature> supportedFeatures)
        : this(status, supportedFeatures, new HashSet<ChatWriteFeature>())
    {
    }
}

public sealed record ChatUser(
    string Id,
    string DisplayName,
    bool? AvatarAvailable,
    bool IsDisabled,
    bool? IsCurrentUser);

public enum ChatConversationKind
{
    Direct,
    Group,
}

public sealed record ChatConversation(
    string Id,
    ChatConversationKind Kind,
    string Title,
    IReadOnlyList<string> MemberIds,
    int? MemberCount,
    string? LastMessageSummary,
    DateTimeOffset? LastActivityAt,
    int UnreadCount,
    bool IsEncrypted)
{
    // 旧 Workspace 仍读取这两个名称；新 Chat 功能只使用强类型字段。
    public string? LatestMessage => LastMessageSummary;
    public DateTimeOffset? LatestAt => LastActivityAt;
}

public enum ChatAttachmentKind
{
    Image,
    Video,
    File,
    Voice,
}

public sealed record ChatAttachment(
    string Id,
    ChatAttachmentKind Kind,
    string FileName,
    string? MediaType,
    long? SizeBytes,
    long? DurationMilliseconds,
    bool? ThumbnailAvailable);

public enum ChatEncryptionState
{
    NotEncrypted,
    Locked,
}

public sealed record ChatMessage(
    string Id,
    string ConversationId,
    string SenderId,
    string? SenderDisplayName,
    bool? IsFromCurrentUser,
    DateTimeOffset SentAt,
    string? Text,
    IReadOnlyList<ChatAttachment> Attachments,
    ChatEncryptionState EncryptionState);

public sealed record ChatPinnedMessage(
    string Id,
    string ConversationId,
    string SenderId,
    string? SenderDisplayName,
    DateTimeOffset SentAt,
    DateTimeOffset PinnedAt,
    string? Text);

public sealed record ChatMessagePage(
    IReadOnlyList<ChatMessage> Messages,
    string? PreviousCursor,
    bool HasMoreBefore,
    int SourceOffset,
    int SourceRecordCount,
    int? SourceTotal);

public sealed record ChatTextSendRequest(
    string ConversationId,
    string Text,
    Guid ClientRequestId);

public sealed record ChatTextSendOutcome(
    MutationResult Result,
    string ConversationId,
    Guid ClientRequestId,
    ChatMessage? ConfirmedMessage);

/// <summary>
/// 单附件发送的可重开本地内容源。仓储在每次提交尝试后关闭返回的流；
/// 调用方应在重试时返回新的、位于开头的可读流。
/// </summary>
public sealed record ChatAttachmentSource(
    string FileName,
    string? MediaType,
    long Length,
    Func<CancellationToken, Task<Stream>> OpenReadAsync);

public sealed record ChatAttachmentSendRequest(
    string ConversationId,
    string? Text,
    ChatAttachmentSource Attachment,
    Guid ClientRequestId);

public sealed record ChatAttachmentSendOutcome(
    MutationResult Result,
    string ConversationId,
    Guid ClientRequestId,
    ChatMessage? ConfirmedMessage);

public sealed record ChatDirectConversationRequest(
    string UserId,
    Guid ClientRequestId);

public sealed record ChatPrivateGroupCreateRequest(
    string Title,
    IReadOnlyList<string> MemberIds,
    Guid ClientRequestId);

public sealed record ChatConversationCreateOutcome(
    MutationResult Result,
    Guid ClientRequestId,
    ChatConversation? ConfirmedConversation);

/// <summary>
/// 受限图片缩略图。只用于前台预览，不包含服务器文件路径或本机保存位置。
/// </summary>
public sealed record ChatAttachmentThumbnail(
    byte[] Bytes,
    string MediaType)
{
    public const int MaximumBytes = 10 * 1_024 * 1_024;
}

public enum ChatAttachmentContentReadStatus
{
    Completed,
    CancelledBeforeRead,
    CancelledDuringRead,
    Failed,
    Unsupported,
}

/// <summary>
/// Chat 附件另存为的前台读取结果。DestinationWasCleared 表示失败路径已把目标流重置为空。
/// </summary>
public sealed record ChatAttachmentContentReadResult(
    ChatAttachmentContentReadStatus Status,
    long BytesWritten,
    bool DestinationWasCleared,
    MutationErrorCategory? ErrorCategory = null,
    string? DiagnosticTag = null);

// ── 提醒 ──

public sealed record ChatReminder(
    string MessageId,
    string ConversationId,
    DateTimeOffset RemindAt);

public sealed record ChatReminderSetOutcome(
    MutationResult Result,
    string MessageId,
    string ConversationId,
    Guid ClientRequestId,
    ChatReminder? ConfirmedReminder);

// ── 定时消息 ──

public sealed record ChatScheduledMessage(
    string Id,
    string ConversationId,
    string Text,
    DateTimeOffset SendAt);

public sealed record ChatScheduledMessageCreateOutcome(
    MutationResult Result,
    Guid ClientRequestId,
    ChatScheduledMessage? ConfirmedMessage);

public sealed record ChatScheduledMessageDraft(
    string ConversationId,
    string Text,
    DateTimeOffset SendAt,
    Guid ClientRequestId)
{
    public bool IsValid => !string.IsNullOrWhiteSpace(ConversationId) &&
                           !string.IsNullOrWhiteSpace(Text) &&
                           SendAt > DateTimeOffset.UtcNow;
}

// ── 投票 ──

public sealed record ChatPollOption(
    string Id,
    string Text,
    int VoteCount,
    bool? IsSelectedByCurrentUser);

public sealed record ChatPoll(
    string Id,
    string Question,
    bool AllowsMultipleSelection,
    bool IsAnonymous,
    DateTimeOffset? ClosesAt,
    bool IsClosed,
    IReadOnlyList<ChatPollOption> Options);

public sealed record ChatPollDraft(
    string ConversationId,
    string Question,
    IReadOnlyList<string> Options,
    bool AllowsMultipleSelection,
    bool IsAnonymous,
    Guid ClientRequestId)
{
    public bool IsValid => !string.IsNullOrWhiteSpace(ConversationId) &&
                           !string.IsNullOrWhiteSpace(Question) &&
                           Question.Length <= 256 &&
                           Options.Count >= 2 &&
                           Options.Count <= 10 &&
                           Options.All(opt => !string.IsNullOrWhiteSpace(opt) && opt.Length <= 128) &&
                           Options.Distinct(StringComparer.OrdinalIgnoreCase).Count() == Options.Count;
}

public sealed record ChatPollCreateOutcome(
    MutationResult Result,
    Guid ClientRequestId,
    ChatMessage? ConfirmedMessage);

// ── 消息转发 ──

public sealed record ChatForwardRequest(
    string MessageId,
    string SourceConversationId,
    IReadOnlyList<string> TargetConversationIds,
    Guid ClientRequestId);

// ── 消息删除 ──

public sealed record ChatDeleteMessageRequest(
    string MessageId,
    string ConversationId,
    Guid ClientRequestId);

// ── 会话关闭 ──

public sealed record ChatCloseConversationRequest(
    string ConversationId,
    Guid ClientRequestId);
