using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private ChatAdvancedViewModel? _advanced;
    private ContentDialog? _advancedDialog;
    private bool HasAdvancedTools => _repository.Availability.SupportedFeatures.Any(feature =>
        feature is ChatReadFeature.Reminders or ChatReadFeature.ScheduledMessages or ChatReadFeature.Polls or ChatReadFeature.Conversations);
    private async void AdvancedTools_Click(object sender, RoutedEventArgs e) => await ShowAdvancedToolsAsync(null);
    private async void Reminder_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ChatMessageItem message } && message.CanSetReminder)
            await ShowAdvancedToolsAsync(message.Id);
    }

    private async Task ShowAdvancedToolsAsync(string? messageId)
    {
        if (_disposed || _advancedDialog is not null || !HasAdvancedTools || XamlRoot is null ||
            _viewModel.SelectedConversation is not { } selected) return;
        _advanced ??= new(_repository);
        var model = _advanced;
        var section = selected.IsEncrypted ? ChatAdvancedSection.CloseConversation : messageId is not null || _repository.Availability.SupportedFeatures.Contains(ChatReadFeature.Reminders)
            ? ChatAdvancedSection.Reminders : _repository.Availability.SupportedFeatures.Contains(ChatReadFeature.ScheduledMessages)
                ? ChatAdvancedSection.ScheduledMessages : _repository.Availability.SupportedFeatures.Contains(ChatReadFeature.Polls)
                    ? ChatAdvancedSection.Polls : selected.IsGroup && _repository.Availability.SupportedFeatures.Contains(ChatReadFeature.PinnedMessages)
                        ? ChatAdvancedSection.Announcements : ChatAdvancedSection.CloseConversation;
        var load = model.ActivateAsync(selected.Conversation, _viewModel.Messages.Select(item => item.Message).ToArray(), section);
        using var content = new ChatAdvancedDialogContent(model, messageId);
        var dialog = _advancedDialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme,
            Title = LocalizationService.Current.Format("ChatAdvancedDialogTitle", model.ConversationTitle),
            Content = content, CloseButtonText = LocalizationService.Current.Get("ChatAdvancedClose"),
            PrimaryButtonText = content.PrimaryText, DefaultButton = ContentDialogButton.Close,
            PrimaryButtonStyle = content.ActionButtonStyle,
            CloseButtonStyle = content.ActionButtonStyle,
        };
        void UpdateButtons() { dialog.PrimaryButtonText = content.PrimaryText; dialog.IsPrimaryButtonEnabled = content.CanSubmit; }
        async void Submit(ContentDialog sender, ContentDialogButtonClickEventArgs args)
        {
            args.Cancel = true; var deferral = args.GetDeferral();
            try { await content.SubmitAsync(); }
            finally { UpdateButtons(); deferral.Complete(); }
        }
        void Closing(ContentDialog sender, ContentDialogClosingEventArgs args) { if (model.IsBusy && !_disposed) args.Cancel = true; }
        content.StateChanged += UpdateButtons; dialog.PrimaryButtonClick += Submit; dialog.Closing += Closing;
        UpdateButtons();
        try { await dialog.ShowAsync(); }
        finally
        {
            content.StateChanged -= UpdateButtons; dialog.PrimaryButtonClick -= Submit; dialog.Closing -= Closing;
            model.CancelLoading(); await load; _advancedDialog = null;
            if (!_disposed)
            {
                await _viewModel.ApplyConfirmedChatActionsAsync(_repository.ProfileId, model.ConversationId!, model.ConfirmedDeletedMessages, model.ConfirmedClosedConversations);
                await _viewModel.RefreshConversationsAsync(); await _viewModel.RefreshMessagesAsync();
            }
        }
    }
    private void DisposeAdvancedTools()
    {
        _advancedDialog?.Hide(); _advancedDialog = null; _advanced?.Dispose(); _advanced = null;
    }
}
