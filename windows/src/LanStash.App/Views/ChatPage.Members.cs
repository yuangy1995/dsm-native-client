using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private ContentDialog? _membersDialog;

    private async void Members_Click(object sender, RoutedEventArgs e) =>
        await ShowMembersAsync();

    private async void MembersAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_viewModel.CanViewMembers)
        {
            return;
        }
        args.Handled = true;
        await ShowMembersAsync();
    }

    private async Task ShowMembersAsync()
    {
        if (!_viewModel.CanViewMembers || _membersDialog is not null || XamlRoot is null)
        {
            return;
        }

        var localization = LocalizationService.Current;
        using var content = new ChatMembersDialogContent(_viewModel);
        var dialog = _membersDialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = localization.Get("ChatMembersDialogTitle"),
            CloseButtonText = localization.Get("ChatMembersClose"),
            DefaultButton = ContentDialogButton.Close,
            Content = content,
        };
        var load = _viewModel.LoadConversationMembersAsync();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            if (!_disposed)
            {
                _viewModel.CancelConversationMembersLoad();
            }
            await load;
            if (ReferenceEquals(_membersDialog, dialog))
            {
                _membersDialog = null;
            }
        }
    }

    private void DisposeMembersDialog()
    {
        _membersDialog?.Hide();
        _membersDialog = null;
        if (!_disposed)
        {
            _viewModel.CancelConversationMembersLoad();
        }
    }
}
