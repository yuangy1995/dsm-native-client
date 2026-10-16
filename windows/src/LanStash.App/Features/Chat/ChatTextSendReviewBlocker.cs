using LanStash.Domain;

namespace LanStash.App.Features.Chat;

public sealed record ChatTextSendReviewBlock(
    Guid ProfileId,
    string ConversationId,
    string NormalizedText,
    string? ThreadId = null,
    Guid? RequestId = null,
    string? AccountIdentity = null);

public sealed class ChatTextSendReviewBlocker
{
    private readonly object _sync = new();
    private readonly Dictionary<(Guid ProfileId, string ConversationId, string NormalizedText, string? ThreadId, string? AccountIdentity),
        ChatTextSendReviewBlock> _blocked = [];

    public static ChatTextSendReviewBlocker Current { get; } = new();

    public ChatTextSendReviewBlock? Find(
        Guid profileId,
        string conversationId,
        string normalizedText,
        string? threadId = null,
        string? accountIdentity = null)
    {
        lock (_sync)
        {
            return _blocked.GetValueOrDefault((profileId, conversationId, normalizedText, threadId, accountIdentity));
        }
    }

    public void Block(ChatTextSendReviewBlock review)
    {
        lock (_sync)
        {
            _blocked[(review.ProfileId, review.ConversationId, review.NormalizedText, review.ThreadId, review.AccountIdentity)] = review;
        }
    }

    public void Clear(ChatTextSendReviewBlock review)
    {
        lock (_sync)
        {
            _blocked.Remove((review.ProfileId, review.ConversationId, review.NormalizedText, review.ThreadId, review.AccountIdentity));
        }
    }

    public void Purge(Guid profileId)
    {
        lock (_sync)
        {
            foreach (var key in _blocked.Keys.Where(key => key.ProfileId == profileId).ToArray())
            {
                _blocked.Remove(key);
            }
        }
    }
}
