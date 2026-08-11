using System.ComponentModel;
using LanStash.App.Features.Chat;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class ChatAnnouncementsDialogContent : UserControl, IDisposable
{
    public ChatBrowserViewModel ViewModel { get; }

    internal ChatAnnouncementsDialogContent(ChatBrowserViewModel viewModel)
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
        await ViewModel.RefreshConversationAnnouncementsAsync();

    private async void Retry_Click(object sender, RoutedEventArgs e) =>
        await ViewModel.RefreshConversationAnnouncementsAsync();

    private void ConfigureAccessibility()
    {
        var localization = LocalizationService.Current;
        var refresh = localization.Get("ChatAnnouncementsRefresh");
        AnnouncementsRefreshText.Text = refresh;
        AnnouncementsLoadingText.Text = localization.Get("ChatAnnouncementsLoading");
        AnnouncementsEmptyTitle.Text = localization.Get("ChatAnnouncementsEmptyTitle");
        AnnouncementsEmptyMessage.Text = localization.Get("ChatAnnouncementsEmptyMessage");
        AnnouncementsErrorTitle.Text = localization.Get("ChatAnnouncementsErrorTitle");
        AnnouncementsErrorMessage.Text = localization.Get("ChatAnnouncementsErrorMessage");
        AnnouncementsRetryButton.Content = localization.Get("ChatAnnouncementsRetry");
        AutomationProperties.SetName(AnnouncementsRefreshButton, refresh);
        AutomationProperties.SetName(
            AnnouncementsRetryButton,
            localization.Get("ChatAnnouncementsRetry"));
        ToolTipService.SetToolTip(AnnouncementsRefreshButton, refresh);
    }

    private void UpdateState()
    {
        AnnouncementsRefreshButton.IsEnabled =
            ViewModel.CanViewAnnouncements && !ViewModel.IsLoadingAnnouncements;
        AnnouncementsCountText.Text = LocalizationService.Current.Format(
            "ChatAnnouncementsCount",
            ViewModel.ConversationAnnouncements.Count);
        AnnouncementsLoadingState.Visibility = Visible(
            ViewModel.IsAnnouncementsIdle || ViewModel.IsLoadingAnnouncements);
        AnnouncementsEmptyState.Visibility = Visible(ViewModel.IsAnnouncementsEmpty);
        AnnouncementsErrorState.Visibility = Visible(ViewModel.HasAnnouncementsError);
        AnnouncementsContentState.Visibility = Visible(ViewModel.HasAnnouncementsContent);
    }

    private static Visibility Visible(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public void Dispose() => ViewModel.PropertyChanged -= ViewModel_PropertyChanged;
}
