using LanStash.App.Features.Downloads;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class DownloadStationPage
{
    private ContentDialog? _detailsDialog, _rssDialog, _recoveryDialog;
    private DownloadRecoveryModel? _recoveryModel;
    private DownloadTaskDetailsModel? _detailsModel;
    private DownloadRssModel? _rssModel;
    private void Sort_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (SortPicker is null || DescendingToggle is null || _disposed || _viewModel is null) return;
        _viewModel.SetSort((DownloadTaskSort)Math.Max(0, SortPicker.SelectedIndex), DescendingToggle.IsChecked == true);
    }
    private void SortDirection_Click(object sender, RoutedEventArgs e) =>
        _viewModel.SetSort((DownloadTaskSort)Math.Max(0, SortPicker.SelectedIndex), DescendingToggle.IsChecked == true);
    private async void Details_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || _detailsDialog is not null || XamlRoot is null || _viewModel.SelectedTask is not { } task) return;
        using var model = _detailsModel = new DownloadTaskDetailsModel(_repository, task.Task);
        using var content = new DownloadTaskDetailsContent(model);
        var dialog = _detailsDialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = task.Title, Content = content,
            CloseButtonText = LocalizationService.Current.Get("ActionClose"), DefaultButton = ContentDialogButton.Close,
        };
        var load = model.LoadAsync();
        try { await dialog.ShowAsync(); }
        finally { model.Dispose(); await load; _detailsDialog = null; _detailsModel = null; }
    }
    private async void Recovery_Click(object sender, RoutedEventArgs e)
    {
        if (_disposed || _recoveryDialog is not null || XamlRoot is null) return;
        using var model = _recoveryModel = new DownloadRecoveryModel(_repository);
        using var content = new DownloadRecoveryContent(model);
        var dialog = _recoveryDialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme,
            Title = LocalizationService.Current.Get("DownloadActionHistory"), Content = content,
            CloseButtonText = LocalizationService.Current.Get("ActionClose"), DefaultButton = ContentDialogButton.Close };
        void Closing(ContentDialog sender, ContentDialogClosingEventArgs args) { if (model.IsBusy && !_disposed) args.Cancel = true; }
        dialog.Closing += Closing;
        var load = model.LoadAsync();
        try { await dialog.ShowAsync(); }
        finally { dialog.Closing -= Closing; model.Dispose(); await load; _recoveryDialog = null; _recoveryModel = null; }
        if (!_disposed) await RunAsync(_viewModel.RefreshAsync);
    }
    private async void Rss_Click(object sender, RoutedEventArgs e) => await ShowRssDialogAsync();
    private async Task ShowRssDialogAsync()
    {
        if (_disposed || _rssDialog is not null || XamlRoot is null) return;
        using var model = _rssModel = new DownloadRssModel(_repository);
        using var content = new DownloadRssContent(model);
        var dialog = _rssDialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = LocalizationService.Current.Get("DownloadRssTitle"), Content = content,
            PrimaryButtonText = LocalizationService.Current.Get("DownloadRssCreate"),
            CloseButtonText = LocalizationService.Current.Get("ActionClose"), DefaultButton = ContentDialogButton.Close,
        };
        void Update() => dialog.IsPrimaryButtonEnabled = !model.IsLoading && !model.IsUpdating && !model.HasError && model.SelectedFeed is not null;
        content.StateChanged += Update; Update();
        var load = model.LoadAsync();
        string? uri = null;
        try { if (await dialog.ShowAsync() == ContentDialogResult.Primary && !model.IsLoading && !model.IsUpdating && !model.HasError) uri = model.SelectedFeed?.DownloadUri; }
        finally { content.StateChanged -= Update; model.Dispose(); await load; _rssDialog = null; _rssModel = null; }
        if (!_disposed && uri is not null) await ShowCreateTaskDialogAsync(uri);
    }
}
