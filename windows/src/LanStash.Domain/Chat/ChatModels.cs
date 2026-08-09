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
    Messages,
    AttachmentMetadata,
    EncryptedContentMetadata,
}

public sealed record ChatAvailability(
    ChatAvailabilityStatus Status,
    IReadOnlySet<ChatReadFeature> SupportedFeatures);

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

public sealed record ChatMessagePage(
    IReadOnlyList<ChatMessage> Messages,
    string? PreviousCursor,
    bool HasMoreBefore,
    int SourceOffset,
    int SourceRecordCount,
    int? SourceTotal);
