using LanStash.App.Features.Downloads;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class DownloadStationPage : Page, IDisposable
{
    private const double CompactWidth = 760;

    private readonly IDownloadStationRepository _repository;
    private readonly DownloadStationViewModel _viewModel;
    private bool _initialized;
    private bool _compactShowsTaskList = true;
    private bool _updatingFilter;
    private bool _disposed;

    internal DownloadStationPage(IDownloadStationRepository repository)
        : this(repository, new DownloadStationViewModel())
    {
    }

    internal DownloadStationPage(
        IDownloadStationRepository repository,
        DownloadStationViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(viewModel);
        InitializeComponent();
        _repository = repository;
        _viewModel = viewModel;
        DataContext = viewModel;
        viewModel.PropertyChanged += ViewModel_PropertyChanged;
        Loaded += DownloadStationPage_Loaded;
        UpdateState();
    }

    private async void DownloadStationPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_initialized)
        {
            return;
        }
        _initialized = true;
        await RunAsync(() => _viewModel.ActivateAsync(_repository));
    }

    private void ViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdateState);

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.RefreshAsync);

    private async void LoadMore_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.LoadMoreAsync);

    private void SearchBox_TextChanged(
        AutoSuggestBox sender,
        AutoSuggestBoxTextChangedEventArgs args)
    {
        if (args.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
        {
            _viewModel.SetSearchText(sender.Text);
        }
    }

    private void FilterPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingFilter || FilterPicker.SelectedItem is not ComboBoxItem { Tag: string tag } ||
            !Enum.TryParse<DownloadTaskFilter>(tag, out var filter))
        {
            return;
        }
        _viewModel.SetFilter(filter);
    }

    private void TaskList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is DownloadTaskItem task)
        {
            _compactShowsTaskList = false;
            _viewModel.SelectTask(task);
            UpdateState();
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e) => ShowTaskList();

    private void ShowAll_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.ShowAll();
        SearchBox.Text = string.Empty;
        SyncFilterPicker();
        SearchBox.Focus(FocusState.Keyboard);
    }

    private void Page_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateAdaptiveLayout();

    private void BackAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_viewModel.HasSelection)
        {
            return;
        }
        args.Handled = true;
        ShowTaskList();
    }

    private void SearchAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (TaskPane.Visibility == Visibility.Visible)
        {
            args.Handled = true;
            SearchBox.Focus(FocusState.Keyboard);
        }
    }

    private async void RefreshAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await RunAsync(_viewModel.RefreshAsync);
    }

    private async Task RunAsync(Func<Task> operation)
    {
        try
        {
            await operation();
        }
        finally
        {
            UpdateState();
        }
    }

    private void UpdateState()
    {
        if (_disposed)
        {
            return;
        }
        LoadingState.Visibility = Visible(
            _viewModel.ContentState == DownloadStationContentState.Loading);
        EmptyState.Visibility = Visible(_viewModel.IsEmpty);
        FilteredEmptyState.Visibility = Visible(_viewModel.IsFilteredEmpty);
        ErrorState.Visibility = Visible(_viewModel.HasError);
        UnavailableState.Visibility = Visible(_viewModel.IsUnavailable);
        ContentState.Visibility = Visible(_viewModel.HasContent);

        RefreshButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.IsUnavailable;
        RefreshErrorNotice.IsOpen = _viewModel.HasRefreshError && !_viewModel.HasError;
        ActivitySummary.Visibility = Visible(_viewModel.HasActivity);
        ActivityErrorNotice.IsOpen = _viewModel.HasActivityError;
        LoadMoreErrorNotice.IsOpen = _viewModel.HasLoadMoreError;
        LoadMoreButton.IsEnabled = _viewModel.CanLoadMore;
        LoadMoreButton.Visibility = Visible(
            _viewModel.CanLoadMore || _viewModel.HasLoadMoreError);
        LoadMoreProgress.IsActive = _viewModel.IsLoadingMore;
        LoadMoreProgress.Visibility = Visible(_viewModel.IsLoadingMore);
        NoSelectionState.Visibility = Visible(!_viewModel.HasSelection);
        TaskDetailState.Visibility = Visible(_viewModel.HasSelection);
        TaskList.SelectedItem = _viewModel.SelectedTask;
        if (!string.Equals(SearchBox.Text, _viewModel.SearchText, StringComparison.Ordinal))
        {
            SearchBox.Text = _viewModel.SearchText;
        }
        SyncFilterPicker();
        UpdateAdaptiveLayout();
    }

    private void SyncFilterPicker()
    {
        _updatingFilter = true;
        FilterPicker.SelectedIndex = _viewModel.Filter switch
        {
            DownloadTaskFilter.All => 0,
            DownloadTaskFilter.Active => 1,
            DownloadTaskFilter.Finished => 2,
            DownloadTaskFilter.Paused => 3,
            _ => 0,
        };
        _updatingFilter = false;
    }

    private void UpdateAdaptiveLayout()
    {
        if (ActualWidth >= CompactWidth)
        {
            TaskColumn.Width = new GridLength(360);
            DetailColumn.Width = new GridLength(1, GridUnitType.Star);
            TaskPane.Visibility = Visibility.Visible;
            DetailPane.Visibility = Visibility.Visible;
            BackButton.Visibility = Visibility.Collapsed;
            return;
        }

        TaskColumn.Width = new GridLength(1, GridUnitType.Star);
        DetailColumn.Width = new GridLength(1, GridUnitType.Star);
        var showDetail = _viewModel.HasSelection && !_compactShowsTaskList;
        TaskPane.Visibility = Visible(!showDetail);
        DetailPane.Visibility = Visible(showDetail);
        BackButton.Visibility = Visible(showDetail);
    }

    private void ShowTaskList()
    {
        _compactShowsTaskList = true;
        _viewModel.SelectTask(null);
        TaskList.SelectedItem = null;
        UpdateAdaptiveLayout();
        TaskList.Focus(FocusState.Keyboard);
    }

    private static Visibility Visible(bool value) =>
        value ? Visibility.Visible : Visibility.Collapsed;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        _viewModel.Dispose();
    }
}
