using System.Globalization;
using LanStash.Domain;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;

namespace LanStash.App.Features.Chat;

public enum ChatBrowserContentState
{
    Loading,
    Empty,
    FilteredEmpty,
    Error,
    Content,
    Unavailable,
    RequiresValidation,
}

public enum ChatMembersContentState
{
    Idle,
    Loading,
    Empty,
    Error,
    Content,
}

public enum ChatAnnouncementsContentState
{
    Idle,
    Loading,
    Empty,
    Error,
    Content,
}

public sealed record ChatConversationItem(ChatConversation Conversation, bool IsPinned = false)
{
    private const string PinGlyphValue = "\uE718";

    public string Id => Conversation.Id;
    public string Title => HasUserFacingTitle
        ? Conversation.Title
        : LocalizationService.Current.Get("ChatBrowserUnnamedConversation");
    public string Summary => Conversation.LastMessageSummary ?? string.Empty;
    public DateTimeOffset? LastActivityAt => Conversation.LastActivityAt;
    public int UnreadCount => Conversation.UnreadCount;
    public string UnreadText => UnreadCount > 0
        ? UnreadCount.ToString("N0", CultureInfo.CurrentCulture)
        : string.Empty;
    public string AutomationName
    {
        get
        {
            var name = UnreadCount > 0
                ? LocalizationService.Current.Format(
                    "ChatBrowserConversationWithUnreadAutomationName",
                    Title,
                    UnreadCount)
                : LocalizationService.Current.Format("ChatBrowserConversationAutomationName", Title);
            return IsPinned
                ? LocalizationService.Current.Format("ChatBrowserPinnedConversationAutomationName", name)
                : name;
        }
    }
    public bool IsEncrypted => Conversation.IsEncrypted;
    public bool IsGroup => Conversation.Kind == ChatConversationKind.Group;
    public string Initial => string.IsNullOrWhiteSpace(Title)
        ? "?"
        : StringInfo.GetNextTextElement(Title.Trim()).ToUpper(CultureInfo.CurrentCulture);
    public Visibility PinnedVisibility => IsPinned ? Visibility.Visible : Visibility.Collapsed;
    public string PinnedStatusText => LocalizationService.Current.Get("ChatBrowserPinnedStatus");
    public string PinActionGlyph => PinGlyphValue;
    public string PinActionText => LocalizationService.Current.Get(IsPinned
        ? "ChatBrowserUnpinConversation"
        : "ChatBrowserPinConversation");
    public string PinActionAutomationName => LocalizationService.Current.Format(
        IsPinned
            ? "ChatBrowserUnpinConversationAutomationName"
            : "ChatBrowserPinConversationAutomationName",
        Title);

    private bool HasUserFacingTitle
    {
        get
        {
            var title = Conversation.Title.Trim();
            if (string.IsNullOrEmpty(title) ||
                string.Equals(title, Conversation.Id, StringComparison.Ordinal))
            {
                return false;
            }

            var parts = title
                .Split(new[] { '、', ',' }, StringSplitOptions.None)
                .Select(value => value.Trim())
                .ToArray();
            var isOnlyMemberIds = parts.Length > 0 && parts.All(part =>
                part.Length > 0 &&
                Conversation.MemberIds.Contains(part, StringComparer.Ordinal));
            return !isOnlyMemberIds;
        }
    }
}

public sealed record ChatMemberItem(ChatUser User)
{
    public string DisplayName => User.DisplayName;
    public bool IsCurrentUser => User.IsCurrentUser == true;
    public bool IsDisabled => User.IsDisabled;
    public string CurrentUserText => LocalizationService.Current.Get("ChatMembersCurrentUser");
    public string DisabledText => LocalizationService.Current.Get("ChatMembersDisabled");
    public Visibility CurrentUserVisibility => IsCurrentUser ? Visibility.Visible : Visibility.Collapsed;
    public Visibility DisabledVisibility => IsDisabled ? Visibility.Visible : Visibility.Collapsed;
    public string AutomationName
    {
        get
        {
            var statuses = new[]
            {
                IsCurrentUser ? CurrentUserText : null,
                IsDisabled ? DisabledText : null,
            }.OfType<string>().ToArray();
            return statuses.Length switch
            {
                0 => DisplayName,
                1 => LocalizationService.Current.Format(
                    "ChatMemberAutomationName",
                    DisplayName,
                    statuses[0]),
                _ => LocalizationService.Current.Format(
                    "ChatMemberAutomationNameWithTwoStatuses",
                    DisplayName,
                    statuses[0],
                    statuses[1]),
            };
        }
    }
}

public sealed record ChatAnnouncementItem(ChatPinnedMessage Message)
{
    public string Sender => string.IsNullOrWhiteSpace(Message.SenderDisplayName)
        ? LocalizationService.Current.Get("ChatAnnouncementsUnknownSender")
        : Message.SenderDisplayName;
    public string Text => string.IsNullOrWhiteSpace(Message.Text)
        ? LocalizationService.Current.Get("ChatAnnouncementsNoText")
        : Message.Text;
    public string SentAtText => Message.SentAt <= DateTimeOffset.UnixEpoch
        ? LocalizationService.Current.Get("ChatAnnouncementsSentAtUnavailable")
        : LocalizationService.Current.Format("ChatAnnouncementsSentAt", Message.SentAt);
    public string PinnedAtText => LocalizationService.Current.Format(
        "ChatAnnouncementsPinnedAt",
        Message.PinnedAt);
    public string AutomationName => LocalizationService.Current.Format(
        "ChatAnnouncementAutomationName",
        Sender,
        PinnedAtText,
        Text);
}

public sealed record ChatMessageItem(ChatMessage Message)
{
    public string Id => Message.Id;
    public string Sender => string.IsNullOrWhiteSpace(Message.SenderDisplayName)
        ? LocalizationService.Current.Get("ChatBrowserUnknownSender")
        : Message.SenderDisplayName;
    public string Text => Message.Text ?? string.Empty;
    public DateTimeOffset SentAt => Message.SentAt;
    public string SentAtText => SentAt.ToString("g", CultureInfo.CurrentCulture);
    public bool IsFromCurrentUser => Message.IsFromCurrentUser == true;
    public bool HasAttachments => Message.Attachments.Count > 0;
    public IReadOnlyList<ChatMessageAttachmentItem> Attachments =>
        Message.Attachments
            .Select(attachment => new ChatMessageAttachmentItem(Message.ConversationId, Id, attachment))
            .ToArray();
}

public sealed record ChatMessageAttachmentItem(
    string ConversationId,
    string MessageId,
    ChatAttachment Attachment)
{
    public string FileName => Attachment.FileName;
    public bool IsImage => Attachment.Kind == ChatAttachmentKind.Image;
    public bool CanSave => Attachment.SizeBytes is not null;
    public Visibility PreviewVisibility => IsImage ? Visibility.Visible : Visibility.Collapsed;
}
