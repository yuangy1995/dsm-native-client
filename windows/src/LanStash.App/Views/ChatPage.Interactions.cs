using LanStash.App.Features.Chat;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private ChatMessageInteractionModel? _interactions;
    private ChatMessageInteractionDialog? _interactionDialog;

    private async void SearchMessages_Click(object sender, RoutedEventArgs args) => await ShowMessageInteractionAsync(null);
    private async void MessageDetails_Click(object sender, RoutedEventArgs args)
    {
        if (sender is Button { Tag: ChatMessageItem item }) await ShowMessageInteractionAsync(item.Message);
    }

    private async Task ShowMessageInteractionAsync(ChatMessage? message)
    {
        if (_disposed || _interactionDialog is not null || XamlRoot is null ||
            !_repository.Availability.SupportedFeatures.Contains(ChatReadFeature.ThreadedReplies)) return;
        var model = _interactions ??= new(_repository);
        if (message is null) model.ShowSearch(_viewModel.SelectedConversation?.Id);
        using var dialog = _interactionDialog = new(model, _viewModel.SelectedConversation?.Id) { XamlRoot = XamlRoot, RequestedTheme = ActualTheme };
        var load = message is null ? Task.CompletedTask : model.OpenAsync(message);
        try { await dialog.ShowAsync(); }
        finally
        {
            model.Close(); await load; _interactionDialog = null;
            if (!_disposed)
            {
                if (model.Root is { } root) _viewModel.ApplyInteractionMessage(root);
                if (dialog.NavigateMessage is { } target && await _viewModel.RevealMessageAsync(target) is { } id)
                {
                    _compactShowsConversationList = false; UpdateState();
                    if (_viewModel.Messages.FirstOrDefault(item => item.Id == id) is { } row) MessageList.ScrollIntoView(row);
                }
            }
        }
        if (!_disposed && dialog.AttachmentRequest is { } attachment)
        {
            if (dialog.SaveAttachmentRequest) await SaveAttachmentAsync(attachment);
            else if (attachment.IsPlayable) await ShowChatMediaAsync(attachment);
            else await ShowAttachmentPreviewAsync(attachment);
        }
    }

    private void DisposeMessageInteractions()
    {
        _interactionDialog?.Dispose(); _interactionDialog?.Hide(); _interactionDialog = null;
        _interactions?.Dispose(); _interactions = null;
    }
}
