using LanStash.App.Features.Downloads;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class DownloadStationBtSearchDialogContent : UserControl, IDisposable
{
    private readonly DownloadStationViewModel _viewModel;
    private bool _updating;
    private bool _disposed;

    internal DownloadStationBtSearchDialogContent(DownloadStationViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(viewModel);
        InitializeComponent();
        _viewModel = viewModel;
        DataContext = viewModel;
        viewModel.PropertyChanged += ViewModel_PropertyChanged;
        UpdateState();
    }

    internal void FocusKeyword() => KeywordBox.Focus(FocusState.Programmatic);

    private void ViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdateState);

    private void KeywordBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_updating)
        {
            _viewModel.SetBtSearchKeyword(KeywordBox.Text);
        }
    }

    private void TitleFilterBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_updating)
        {
            _viewModel.SetBtSearchTitleFilter(TitleFilterBox.Text);
        }
    }

    private void ModuleScopePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_updating &&
            ModuleScopePicker.SelectedItem is DownloadBtSearchModuleScopeOption option)
        {
            _viewModel.SetBtSearchModuleScope(option.Value);
        }
    }

    private void ModuleList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_updating)
        {
            _viewModel.SetBtSearchSelectedModules(
                ModuleList.SelectedItems
                    .OfType<DownloadBtSearchModuleOption>()
                    .Select(item => item.Id));
        }
    }

    private void CategoryPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_updating && CategoryPicker.SelectedItem is DownloadBtSearchCategoryOption option)
        {
            _viewModel.SetBtSearchCategory(option.Id);
        }
    }

    private void SortPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_updating && SortPicker.SelectedItem is DownloadBtSearchSortOption option)
        {
            _viewModel.SetBtSearchSort(option.Value);
        }
    }

    private void DirectionPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_updating && DirectionPicker.SelectedItem is DownloadBtSearchDirectionOption option)
        {
            _viewModel.SetBtSearchDirection(option.Value);
        }
    }

    private void ResultList_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        _viewModel.SelectBtSearchResult(ResultList.SelectedItem as DownloadBtSearchResultItem);

    private void Retry_Click(object sender, RoutedEventArgs e) =>
        ObserveBtSearchTask(_viewModel.RetryBtSearchAsync());

    private void CancelSearch_Click(object sender, RoutedEventArgs e) =>
        _viewModel.CancelCurrentBtSearch();

    private void UpdateState()
    {
        if (_disposed)
        {
            return;
        }

        _updating = true;
        if (!string.Equals(KeywordBox.Text, _viewModel.BtSearchKeyword, StringComparison.Ordinal))
        {
            KeywordBox.Text = _viewModel.BtSearchKeyword;
        }
        if (!string.Equals(
                TitleFilterBox.Text,
                _viewModel.BtSearchTitleFilter,
                StringComparison.Ordinal))
        {
            TitleFilterBox.Text = _viewModel.BtSearchTitleFilter;
        }
        ModuleScopePicker.SelectedItem = _viewModel.BtSearchModuleScopeOptions.FirstOrDefault(
            item => item.Value == _viewModel.BtSearchModuleScope);
        CategoryPicker.SelectedItem = _viewModel.BtSearchCategories.FirstOrDefault(
            item => string.Equals(item.Id, _viewModel.BtSearchCategoryId, StringComparison.Ordinal));
        SortPicker.SelectedItem = _viewModel.BtSearchSortOptions.FirstOrDefault(
            item => item.Value == _viewModel.BtSearchSort);
        DirectionPicker.SelectedItem = _viewModel.BtSearchDirectionOptions.FirstOrDefault(
            item => item.Value == _viewModel.BtSearchDirection);

        var selectedModuleIds = ModuleList.SelectedItems
            .OfType<DownloadBtSearchModuleOption>()
            .Select(item => item.Id)
            .ToHashSet(StringComparer.Ordinal);
        if (!selectedModuleIds.SetEquals(_viewModel.BtSearchSelectedModuleIds))
        {
            ModuleList.SelectedItems.Clear();
            foreach (var module in _viewModel.BtSearchModules.Where(
                         item => _viewModel.BtSearchSelectedModuleIds.Contains(item.Id)))
            {
                ModuleList.SelectedItems.Add(module);
            }
        }
        ResultList.SelectedItem = _viewModel.SelectedBtSearchResult;
        _updating = false;

        FiltersPanel.Visibility = Visible(
            _viewModel.HasBtSearchCatalog &&
            !_viewModel.HasNoBtSearchProviders);
        SelectedModulesPanel.Visibility = Visible(
            _viewModel.HasBtSearchCatalog &&
            !_viewModel.HasNoBtSearchProviders &&
            _viewModel.BtSearchModuleScope == DownloadBtSearchModuleScope.Selected);
        ModuleSelectionRequired.Visibility = Visible(
            _viewModel.BtSearchModuleScope == DownloadBtSearchModuleScope.Selected &&
            _viewModel.BtSearchSelectedModuleIds.Count == 0);
        BtSearchLoadingState.Visibility = Visible(_viewModel.IsBtSearchLoading);
        BtSearchReadyState.Visibility = Visible(_viewModel.IsBtSearchReady);
        BtSearchNoProvidersState.Visibility = Visible(_viewModel.HasNoBtSearchProviders);
        BtSearchEmptyState.Visibility = Visible(_viewModel.IsBtSearchEmpty);
        BtSearchFilteredEmptyState.Visibility = Visible(_viewModel.IsBtSearchFilteredEmpty);
        BtSearchErrorState.Visibility = Visible(_viewModel.HasBtSearchError);
        BtSearchContentState.Visibility = Visible(_viewModel.HasBtSearchResults);
    }

    private static Visibility Visible(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    private static void ObserveBtSearchTask(Task task)
    {
        _ = task.ContinueWith(
            static completed =>
            {
                _ = completed.Exception;
            },
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted |
                TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
    }
}
