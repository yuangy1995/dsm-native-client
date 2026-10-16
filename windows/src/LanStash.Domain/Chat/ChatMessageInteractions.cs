namespace LanStash.Domain;

public sealed record ChatSearchPage(IReadOnlyList<ChatMessage> Messages, string? NextCursor, int Total);

public sealed record ChatEditingPolicy(bool AllowsEditing, TimeSpan? MaximumAge)
{
    public bool Permits(ChatMessage message, DateTimeOffset now) => AllowsEditing &&
        message.IsFromCurrentUser == true && message.EncryptionState == ChatEncryptionState.NotEncrypted &&
        message.Kind == ChatMessageKind.Normal && message.Poll is null &&
        message.SentAt > DateTimeOffset.UnixEpoch &&
        (MaximumAge is null || now - message.SentAt <= MaximumAge);
}

public sealed record ChatEditMessageRequest(ChatMessage Original, string Text, Guid ClientRequestId);
public sealed record ChatVoteRequest(ChatMessage Original, IReadOnlyList<string> ChoiceIds, Guid ClientRequestId);
public sealed record ChatMessageUpdateOutcome(MutationResult Result, ChatMessage? Message);
