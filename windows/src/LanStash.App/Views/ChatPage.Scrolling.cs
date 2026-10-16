using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.Views;

public sealed partial class ChatPage
{
    private ScrollViewer? _messageScroller;
    private string? _scrollConversationId;
    private double? _refreshScrollOffset;

    private void CaptureMessageScroll()
    {
        _refreshScrollOffset = _messageScroller is { ScrollableHeight: > 4 } scroll &&
            scroll.ScrollableHeight - scroll.VerticalOffset > 4 ? scroll.VerticalOffset : null;
    }

    private void RestoreMessageScroll()
    {
        if (_refreshScrollOffset is not { } offset || _messageScroller is not { } scroll) return;
        _refreshScrollOffset = null;
        // 同一会话的原位内容替换不改变用户正在阅读的位置。
        if (MessageList.ItemsPanelRoot is ItemsStackPanel panel) panel.ItemsUpdatingScrollMode = ItemsUpdatingScrollMode.KeepItemsInView;
        MessageList.UpdateLayout(); scroll.ChangeView(null, offset, null, disableAnimation: true);
    }

    private void MessageList_Loaded(object sender, RoutedEventArgs e)
    {
        DetachMessageScrolling();
        _messageScroller = FindMessageScroller(MessageList);
        if (_messageScroller is not null) _messageScroller.ViewChanged += MessageScroll_Changed;
        FollowLatestMessages();
    }

    private void MessageList_Unloaded(object sender, RoutedEventArgs e) => DetachMessageScrolling();

    private void MessageScroll_Changed(object? sender, ScrollViewerViewChangedEventArgs e)
    {
        if (_disposed || _messageScroller is null || MessageList.ItemsPanelRoot is not ItemsStackPanel panel) return;
        // 已在底部时跟随新消息；正在阅读更早内容时保留当前可见行。
        panel.ItemsUpdatingScrollMode = _messageScroller.ScrollableHeight - _messageScroller.VerticalOffset <= 4
            ? ItemsUpdatingScrollMode.KeepLastItemInView : ItemsUpdatingScrollMode.KeepItemsInView;
    }

    private void FollowLatestMessages()
    {
        var conversationId = _viewModel.SelectedConversation?.Id;
        if (conversationId == _scrollConversationId) return;
        _scrollConversationId = conversationId;
        if (MessageList.ItemsPanelRoot is ItemsStackPanel panel) panel.ItemsUpdatingScrollMode = ItemsUpdatingScrollMode.KeepLastItemInView;
    }

    private void DetachMessageScrolling()
    {
        if (_messageScroller is not null) _messageScroller.ViewChanged -= MessageScroll_Changed;
        _messageScroller = null;
    }

    private static ScrollViewer? FindMessageScroller(DependencyObject root)
    {
        if (root is ScrollViewer scroll) return scroll;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            if (FindMessageScroller(VisualTreeHelper.GetChild(root, index)) is { } child) return child;
        return null;
    }
}
