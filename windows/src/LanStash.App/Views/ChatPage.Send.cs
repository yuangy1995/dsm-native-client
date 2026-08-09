using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private void UpdateSendState()
    {
        if (_disposed)
        {
            return;
        }
        _composer.Configure(_repository, _viewModel.SelectedConversation);
        ComposerPanel.Visibility = Visible(_composer.IsAvailable);
        if (!string.Equals(ComposerInput.Text, _composer.DraftText, StringComparison.Ordinal))
        {
            ComposerInput.Text = _composer.DraftText;
        }
        ComposerInput.IsEnabled = _composer.CanEdit;
        SendMessageButton.IsEnabled = _composer.CanSend;
        SendMessageProgress.IsActive = _composer.IsSending;
        SendMessageProgress.Visibility = Visible(_composer.IsSending);

        var status = ComposerStatusText();
        ComposerStatus.Text = status;
        ComposerStatus.Visibility = Visible(!string.IsNullOrEmpty(status));
        AutomationProperties.SetName(ComposerStatus, status);
    }

    private void ComposerInput_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (sender is TextBox input)
        {
            _composer.DraftText = input.Text;
            UpdateSendState();
        }
    }

    private async void SendMessage_Click(object sender, RoutedEventArgs e)
    {
        await RunAsync(async () =>
        {
            var confirmed = await _composer.SendAsync();
            if (confirmed)
            {
                await _viewModel.RefreshMessagesAsync();
            }
        });
        if (_composer.CanEdit)
        {
            ComposerInput.Focus(FocusState.Keyboard);
        }
    }

    private string ComposerStatusText()
    {
        var localization = LocalizationService.Current;
        return _composer.State switch
        {
            ChatTextComposerState.Sending => localization.Get("ChatBrowserComposerSending"),
            ChatTextComposerState.Sent => localization.Get("ChatBrowserComposerSent"),
            ChatTextComposerState.NeedsReview => localization.Get("ChatBrowserComposerReview"),
            ChatTextComposerState.CancelledBeforeSubmission =>
                localization.Get("ChatBrowserComposerCancelled"),
            ChatTextComposerState.PermissionDenied => localization.Get("ChatBrowserComposerPermission"),
            ChatTextComposerState.Failure => localization.Get("ChatBrowserComposerFailed"),
            _ => string.Empty,
        };
    }
}
