using LanStash.Domain;

namespace LanStash.App.Features.Chat;

/// <summary>
/// 仅在当前应用进程内保留已提交但未确认的单附件目标，避免页面重建后再次上传。
/// </summary>
public sealed class ChatAttachmentSendReviewBlocker
{
    private readonly object _sync = new();
    private readonly HashSet<ChatAttachmentSendReviewTarget> _targets = [];

    public static ChatAttachmentSendReviewBlocker Current { get; } = new();

    public bool Contains(ChatAttachmentSendReviewTarget target)
    {
        lock (_sync)
        {
            return _targets.Contains(target);
        }
    }

    public void Block(ChatAttachmentSendReviewTarget target)
    {
        lock (_sync)
        {
            _targets.Add(target);
        }
    }

    public void Clear(ChatAttachmentSendReviewTarget target)
    {
        lock (_sync)
        {
            _targets.Remove(target);
        }
    }
}

public sealed record ChatAttachmentSendReviewTarget(
    Guid ProfileId,
    string ConversationId,
    string AttachmentFingerprint);
