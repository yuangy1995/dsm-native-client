using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private ContentDialog? _announcementsDialog;

    private async void Announcements_Click(object sender, RoutedEventArgs e) =>
        await ShowAnnouncementsAsync();

    private async void AnnouncementsAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_viewModel.CanViewAnnouncements)
        {
            return;
        }
        args.Handled = true;
        await ShowAnnouncementsAsync();
    }

    private async Task ShowAnnouncementsAsync()
    {
        if (!_viewModel.CanViewAnnouncements || _announcementsDialog is not null || XamlRoot is null)
        {
            return;
        }

        var localization = LocalizationService.Current;
        using var content = new ChatAnnouncementsDialogContent(_viewModel);
        var dialog = _announcementsDialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = localization.Get("ChatAnnouncementsDialogTitle"),
            CloseButtonText = localization.Get("ChatAnnouncementsClose"),
            DefaultButton = ContentDialogButton.Close,
            Content = content,
        };
        var load = _viewModel.LoadConversationAnnouncementsAsync();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            if (!_disposed)
            {
                _viewModel.CancelConversationAnnouncementsLoad();
            }
            await load;
            if (ReferenceEquals(_announcementsDialog, dialog))
            {
                _announcementsDialog = null;
            }
        }
    }

    private void DisposeAnnouncementsDialog()
    {
        _announcementsDialog?.Hide();
        _announcementsDialog = null;
        if (!_disposed)
        {
            _viewModel.CancelConversationAnnouncementsLoad();
        }
    }
}
