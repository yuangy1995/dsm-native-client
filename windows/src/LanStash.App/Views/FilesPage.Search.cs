using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private FileSearchRequest? _activeSearchRequest;
    private ContentDialog? _advancedSearchDialog;

    private async void AdvancedSearch_Click(object sender, RoutedEventArgs e) => await ShowAdvancedSearchAsync();

    internal async Task ShowAdvancedSearchAsync()
    {
        if (_disposed || _advancedSearchDialog is not null || _searchRepository?.IsSearchAvailable != true) return;
        var path = _viewModel.CurrentPath;
        var content = new FileSearchDialogContent(_activeSearchRequest ??
            new(path, FilterBox.Text, true) { Kind = _viewModel.TypeFilter });
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = LocalizationService.Current.Get("FileSearchAdvancedTitle"),
            PrimaryButtonText = LocalizationService.Current.Get("FileSearchRun"),
            SecondaryButtonText = LocalizationService.Current.Get("FileSearchClearText"),
            CloseButtonText = LocalizationService.Current.Get("FileSearchClose"),
            DefaultButton = ContentDialogButton.Primary,
            Content = content,
        };
        FileSearchRequest? request = null;
        dialog.PrimaryButtonClick += (_, args) =>
        {
            if (!content.TryBuildRequest(out request)) args.Cancel = true;
        };
        _advancedSearchDialog = dialog;
        try
        {
            var result = await dialog.ShowAsync();
            if (_disposed || _viewModel.CurrentPath != path) return;
            if (result == ContentDialogResult.Primary && request is not null)
            {
                ExitDownloadSelectionMode();
                FilterBox.Text = request.Query;
                // 先统一已有类型筛选，再开始搜索；旧筛选不能遮蔽新的条件结果。
                await _viewModel.SetTypeFilterAsync(request.Kind);
                await PerformAsyncSearchAsync(request);
            }
            else if (result == ContentDialogResult.Secondary) ClearFilter_Click(this, new RoutedEventArgs());
        }
        finally
        {
            _advancedSearchDialog = null;
        }
    }

    private async Task ChangeSearchTypeAsync(FileListTypeFilter kind)
    {
        var request = _activeSearchRequest;
        await RunAsync(() => _viewModel.SetTypeFilterAsync(kind));
        if (request is not null) await PerformAsyncSearchAsync(request with { Kind = kind });
    }

    private void CancelSearch_Click(object sender, RoutedEventArgs e)
    {
        CancelAsyncSearch();
        _activeSearchRequest = null;
        _viewModel.SetFilter(string.Empty);
        FilterBox.Text = string.Empty;
        UpdateState();
    }
}
