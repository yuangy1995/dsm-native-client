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
}
