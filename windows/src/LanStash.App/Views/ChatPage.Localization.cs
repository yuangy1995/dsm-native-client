using LanStash.App.Localization;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private string _displayLanguage = LocalizationService.Current.ResolvedLanguage;

    internal void RefreshLocalization()
    {
        var l = LocalizationService.Current;
        if (_disposed || _displayLanguage == l.ResolvedLanguage) return;
        _displayLanguage = l.ResolvedLanguage;
        // 工作区保留草稿与录音，只更新已有控件和列表容器的语言。
        LocalizedChatBrowserTitle.Text = l.Get("ChatBrowserTitle.Text");
        LocalizedChatBrowserDescription.Text = l.Get("ChatBrowserDescription.Text");
        AdvancedToolsButton.Content = l.Get("ChatAdvancedTools.Content");
        AutomationProperties.SetName(AdvancedToolsButton, l.Get("ChatAdvancedTools.AutomationProperties.Name"));
        MessageSearchButton.Content = l.Get("ChatSearchMessagesButton.Content");
        AutomationProperties.SetName(MessageSearchButton, l.Get("ChatSearchMessagesButton.AutomationProperties.Name"));
        AutomationProperties.SetName(ChatNotificationsButton, l.Get("ChatNotificationsButton.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        AutomationProperties.SetName(RefreshButton, l.Get("ChatBrowserRefresh.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        LocalizedChatBrowserRefreshLabel.Text = l.Get("ChatBrowserRefreshLabel.Text");
        ReadOnlyNotice.Title = l.Get("ChatBrowserReadOnly.Title");
        ReadOnlyNotice.Message = l.Get("ChatBrowserReadOnly.Message");
        LocalizedWorkspaceConversations.Text = l.Get("WorkspaceConversations.Text");
        SearchBox.PlaceholderText = l.Get("ChatBrowserSearch.PlaceholderText");
        AutomationProperties.SetName(SearchBox, l.Get("ChatBrowserSearch.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        ConversationRefreshError.Title = l.Get("ChatBrowserConversationRefreshError.Title");
        ConversationRefreshError.Message = l.Get("ChatBrowserConversationRefreshError.Message");
        AutomationProperties.SetName(ConversationList, l.Get("ChatBrowserConversationList.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        PinStorageError.Title = l.Get("ChatBrowserPinStorageError.Title");
        PinStorageError.Message = l.Get("ChatBrowserPinStorageError.Message");
        AutomationProperties.SetName(BackButton, l.Get("ChatBrowserBack.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        LocalizedChatBrowserConversationReadOnly.Text = l.Get("ChatBrowserConversationReadOnly.Text");
        AutomationProperties.SetName(MembersButton, l.Get("ChatBrowserMembersButton.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        ToolTipService.SetToolTip(MembersButton, l.Get("ChatBrowserMembersButton.[using:Microsoft.UI.Xaml.Controls]ToolTipService.ToolTip"));
        AutomationProperties.SetName(AnnouncementsButton, l.Get("ChatBrowserAnnouncementsButton.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        ToolTipService.SetToolTip(AnnouncementsButton, l.Get("ChatBrowserAnnouncementsButton.[using:Microsoft.UI.Xaml.Controls]ToolTipService.ToolTip"));
        AutomationProperties.SetName(RefreshMessagesButton, l.Get("ChatBrowserRefreshMessages.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        MessageError.Title = l.Get("ChatBrowserMessageError.Title");
        MessageError.Message = l.Get("ChatBrowserMessageError.Message");
        MessageDeleteReview.Title = l.Get("ChatMessageDeleteReview.Title");
        MessageDeleteReview.Message = l.Get("ChatMessageDeleteReview.Message");
        MessageDeleteError.Title = l.Get("ChatMessageDeleteError.Title");
        MessageDeleteError.Message = l.Get("ChatMessageDeleteError.Message");
        LocalizedChatBrowserChooseConversationTitle.Text = l.Get("ChatBrowserChooseConversationTitle.Text");
        LocalizedChatBrowserChooseConversationMessage.Text = l.Get("ChatBrowserChooseConversationMessage.Text");
        LocalizedChatBrowserEncryptedTitle.Text = l.Get("ChatBrowserEncryptedTitle.Text");
        LocalizedChatBrowserEncryptedMessage.Text = l.Get("ChatBrowserEncryptedMessage.Text");
        LocalizedChatBrowserMessagesLoading.Text = l.Get("ChatBrowserMessagesLoading.Text");
        LocalizedChatBrowserMessagesEmptyTitle.Text = l.Get("ChatBrowserMessagesEmptyTitle.Text");
        LocalizedChatBrowserMessagesEmptyMessage.Text = l.Get("ChatBrowserMessagesEmptyMessage.Text");
        LoadEarlierError.Title = l.Get("ChatBrowserLoadEarlierError.Title");
        LoadEarlierError.Message = l.Get("ChatBrowserLoadEarlierError.Message");
        LoadEarlierButton.Content = l.Get("ChatBrowserLoadEarlier.Content");
        AutomationProperties.SetName(LoadEarlierButton, l.Get("ChatBrowserLoadEarlier.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        AutomationProperties.SetName(LoadEarlierProgress, l.Get("ChatBrowserLoadEarlierProgress.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        AutomationProperties.SetName(MessageList, l.Get("ChatBrowserMessageList.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        LocalizedChatBrowserComposerLabel.Text = l.Get("ChatBrowserComposerLabel.Text");
        AutomationProperties.SetName(EmojiButton, l.Get("ChatEmojiAction.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        AutomationProperties.SetName(ChooseAttachmentButton, l.Get("WorkspaceChatAttachment.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        AutomationProperties.SetName(VoiceMessageButton, l.Get("ChatVoiceAction.AutomationProperties.Name"));
        ToolTipService.SetToolTip(VoiceMessageButton, l.Get("ChatVoiceAction.ToolTipService.ToolTip"));
        SendMessageButton.Content = l.Get("ChatBrowserSend.Content");
        AutomationProperties.SetName(SendMessageButton, l.Get("ChatBrowserSend.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        RefreshSendButton.Content = l.Get("ChatRefreshSendButton.Content");
        AutomationProperties.SetName(RefreshSendButton, l.Get("ChatRefreshSendButton.AutomationProperties.Name"));
        RemoveAttachmentButton.Content = l.Get("ChatAttachmentRemove.Content");
        AutomationProperties.SetName(RemoveAttachmentButton, l.Get("ChatAttachmentRemove.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        CancelAttachmentButton.Content = l.Get("ChatAttachmentCancel.Content");
        AutomationProperties.SetName(CancelAttachmentButton, l.Get("ChatAttachmentCancel.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        ComposerInput.PlaceholderText = l.Get("ChatBrowserComposer.PlaceholderText");
        AutomationProperties.SetName(ComposerInput, l.Get("ChatBrowserComposer.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        AutomationProperties.SetName(SendMessageProgress, l.Get("ChatBrowserSendProgress.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        AutomationProperties.SetName(AttachmentProgress, l.Get("ChatAttachmentProgress.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        AutomationProperties.SetName(ComposerStatus, l.Get("ChatBrowserSendStatus.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        LocalizedChatBrowserLoading.Text = l.Get("ChatBrowserLoading.Text");
        LocalizedChatBrowserEmptyTitle.Text = l.Get("ChatBrowserEmptyTitle.Text");
        LocalizedChatBrowserEmptyMessage.Text = l.Get("ChatBrowserEmptyMessage.Text");
        LocalizedChatBrowserEmptyRefresh.Content = l.Get("ChatBrowserEmptyRefresh.Content");
        LocalizedChatBrowserFilteredEmptyTitle.Text = l.Get("ChatBrowserFilteredEmptyTitle.Text");
        LocalizedChatBrowserFilteredEmptyMessage.Text = l.Get("ChatBrowserFilteredEmptyMessage.Text");
        LocalizedChatBrowserClearSearch.Content = l.Get("ChatBrowserClearSearch.Content");
        LocalizedChatBrowserErrorTitle.Text = l.Get("ChatBrowserErrorTitle.Text");
        LocalizedChatBrowserErrorMessage.Text = l.Get("ChatBrowserErrorMessage.Text");
        LocalizedChatBrowserRetry.Content = l.Get("ChatBrowserRetry.Content");
        LocalizedChatBrowserUnavailableTitle.Text = l.Get("ChatBrowserUnavailableTitle.Text");
        LocalizedChatBrowserUnavailableMessage.Text = l.Get("ChatBrowserUnavailableMessage.Text");
        LocalizedChatBrowserValidationTitle.Text = l.Get("ChatBrowserValidationTitle.Text");
        LocalizedChatBrowserValidationMessage.Text = l.Get("ChatBrowserValidationMessage.Text");
        ConfigureCreateConversationAction(); ConfigureEmojiAction(); UpdateNotificationPreference();
        _emojiFlyout?.Hide(); _emojiFlyout = null;
        CaptureMessageScroll();
        ConversationList.ItemsSource = null; MessageList.ItemsSource = null;
        ConversationList.ItemsSource = _viewModel.Conversations; MessageList.ItemsSource = _viewModel.Messages;
        UpdateState(); RestoreMessageScroll();
    }
}
