using LanStash.App.Features.Chat;
using LanStash.App.Features.Settings;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private DispatcherQueueTimer? _readTimer;
    private bool _isWindowActive;
    private void InitializeReadVisibility()
    {
        _readTimer = DispatcherQueue.CreateTimer();
        _readTimer.Interval = TimeSpan.FromMilliseconds(350);
        _readTimer.Tick += async (_, _) =>
        {
            if (_disposed || !_isLoaded) { _readTimer.Stop(); return; }
            var visible = UpdateVisibleMessages();
            if (visible.OrderByDescending(item => item.SentAt).FirstOrDefault() is { } latest)
                await _workspaceSession.MarkVisibleReadAsync(latest);
            if (_isWindowActive && _isWindowVisible) await (_interactionDialog?.MarkVisibleThreadReadAsync() ?? Task.CompletedTask);
        };
        Loaded += (_, _) => { if (!_disposed) _readTimer.Start(); };
        Unloaded += (_, _) => _readTimer.Stop();
    }

    internal async Task SetWindowActiveAsync(bool active)
    {
        _isWindowActive = active;
        UpdateVisibleMessages();
        await UpdateVoiceActivityAsync();
    }

    private IReadOnlyList<ChatMessage> UpdateVisibleMessages()
    {
        if (_workspaceSession is null) return [];
        var active = !_disposed && _isLoaded && _isWindowVisible && _isWindowActive &&
            MessagePane.Visibility == Visibility.Visible &&
            !(XamlRoot is not null && Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(XamlRoot).Any(popup => popup.IsOpen));
        var visible = active ? ReadVisibleRows(MessageList, _messageScroller).Select(item => item.Message).ToArray() : [];
        _workspaceSession.SetView(active, _viewModel.SelectedConversation?.Id, visible);
        return visible;
    }

    internal static IReadOnlyList<ChatMessageItem> ReadVisibleRows(ListView list, ScrollViewer? scroller)
    {
        if (scroller is null || scroller.ActualHeight <= 0 || scroller.ActualWidth <= 0) return [];
        var result = new List<ChatMessageItem>();
        foreach (var item in list.Items.OfType<ChatMessageItem>())
        {
            if (list.ContainerFromItem(item) is not FrameworkElement { ActualHeight: > 0 } row) continue;
            var rect = row.TransformToVisual(scroller).TransformBounds(new Rect(0, 0, row.ActualWidth, row.ActualHeight));
            var height = Math.Max(0, Math.Min(scroller.ActualHeight, rect.Bottom) - Math.Max(0, rect.Top));
            var width = Math.Max(0, Math.Min(scroller.ActualWidth, rect.Right) - Math.Max(0, rect.Left));
            if (height >= Math.Min(row.ActualHeight, scroller.ActualHeight) * .8 && width >= row.ActualWidth * .8) result.Add(item);
        }
        return result;
    }

    internal async Task<bool> RevealNotificationAsync(ChatNotificationTarget target)
    {
        if (_disposed || target.SessionId != _workspaceSession.Id) return false;
        var message = await _repository.LocateMessageAsync(target.ConversationId, target.MessageId);
        if (_disposed || message is null) return false;
        var id = await _viewModel.RevealMessageAsync(message);
        if (id is null) return false;
        _compactShowsConversationList = false; UpdateState();
        if (_viewModel.Messages.FirstOrDefault(item => item.Id == id) is { } row) MessageList.ScrollIntoView(row);
        return true;
    }

    private void UpdateNotificationPreference()
    {
        if (ChatNotificationsButton is null) return;
        var enabled = AppSettingsService.Current.Preferences.ChatNotificationsEnabled;
        ChatNotificationsButton.IsChecked = enabled;
        _workspaceSession.NotificationsEnabled = enabled;
        ToolTipService.SetToolTip(ChatNotificationsButton, LocalizationService.Current.Get(enabled ? "ChatNotificationsOn" : "ChatNotificationsOff"));
    }

    private void ChatNotifications_Click(object sender, RoutedEventArgs args)
    {
        var saved = AppSettingsService.Current.SetChatNotificationsEnabled(ChatNotificationsButton.IsChecked == true);
        UpdateNotificationPreference();
        ReadOnlyNotice.Message = saved ? string.Empty : LocalizationService.Current.Get("ChatNotificationSaveError");
        ReadOnlyNotice.IsOpen = !saved;
    }
}
