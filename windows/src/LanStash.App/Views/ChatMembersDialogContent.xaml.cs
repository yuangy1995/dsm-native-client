using System.ComponentModel;
using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ChatMembersDialogContent : UserControl, IDisposable
{
    public ChatBrowserViewModel ViewModel { get; }

    internal ChatMembersDialogContent(ChatBrowserViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(viewModel);
        ViewModel = viewModel;
        InitializeComponent();
        ViewModel.PropertyChanged += ViewModel_PropertyChanged;
        ConfigureAccessibility();
        UpdateState();
    }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdateState);

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await ViewModel.RefreshConversationMembersAsync();

    private async void Retry_Click(object sender, RoutedEventArgs e) =>
        await ViewModel.RefreshConversationMembersAsync();

    private void ConfigureAccessibility()
    {
        var localization = LocalizationService.Current;
        var refresh = localization.Get("ChatMembersRefresh");
        MembersRefreshText.Text = refresh;
        MembersLoadingText.Text = localization.Get("ChatMembersLoading");
        MembersEmptyTitle.Text = localization.Get("ChatMembersEmptyTitle");
        MembersEmptyMessage.Text = localization.Get("ChatMembersEmptyMessage");
        MembersErrorTitle.Text = localization.Get("ChatMembersErrorTitle");
        MembersErrorMessage.Text = localization.Get("ChatMembersErrorMessage");
        MembersRetryButton.Content = localization.Get("ChatMembersRetry");
        AutomationProperties.SetName(MembersRefreshButton, refresh);
        AutomationProperties.SetName(
            MembersRetryButton,
            localization.Get("ChatMembersRetry"));
        ToolTipService.SetToolTip(MembersRefreshButton, refresh);
    }

    private void UpdateState()
    {
        MembersRefreshButton.IsEnabled = ViewModel.CanViewMembers && !ViewModel.IsLoadingMembers;
        MembersCountText.Text = LocalizationService.Current.Format(
            "ChatMembersCount",
            ViewModel.ConversationMembers.Count);
        MembersLoadingState.Visibility = Visible(ViewModel.IsMembersIdle || ViewModel.IsLoadingMembers);
        MembersEmptyState.Visibility = Visible(ViewModel.IsMembersEmpty);
        MembersErrorState.Visibility = Visible(ViewModel.HasMembersError);
        MembersContentState.Visibility = Visible(ViewModel.HasMembersContent);
    }

    private static Visibility Visible(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public void Dispose() => ViewModel.PropertyChanged -= ViewModel_PropertyChanged;
}
