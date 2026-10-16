using LanStash.App.Features.Containers;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class ContainerManagerPage : Page, IDisposable
{
    private const double CompactWidth = 760;
    private readonly IContainerManagerRepository _repository;
    private readonly ContainerManagerViewModel _viewModel;
    private bool _initialized;
    private bool _compactShowsList = true;
    private bool _updatingFilter;
    private bool _disposed;

    internal ContainerManagerPage(IContainerManagerRepository repository)
        : this(repository, new ContainerManagerViewModel())
    {
    }

    internal ContainerManagerPage(
        IContainerManagerRepository repository,
        ContainerManagerViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(viewModel);
        _repository = repository;
        _viewModel = viewModel;
        InitializeComponent();
        DataContext = viewModel;
        viewModel.PropertyChanged += ViewModel_PropertyChanged;
        Loaded += ContainerManagerPage_Loaded;
        Unloaded += (_, _) => { _ = _viewModel.SetActivityVisibleAsync(false); ResetActivityFilterControls(); };
        UpdateState();
    }

    private async void ContainerManagerPage_Loaded(object sender, RoutedEventArgs e)
    {
        if (_initialized)
        {
            await _viewModel.SetActivityVisibleAsync(SectionPivot.SelectedIndex == 5);
            return;
        }
        _initialized = true;
        await RunAsync(() => _viewModel.ActivateAsync(_repository));
        _updatingFilter = true; NetworkSearchBox.Text = _viewModel.NetworkSearch; _updatingFilter = false;
        await _viewModel.SetActivityVisibleAsync(SectionPivot.SelectedIndex == 5);
    }
    private async void SectionPivot_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized || _disposed) return;
        if (SectionPivot.SelectedIndex != 5) ResetActivityFilterControls();
        await RunAsync(() => _viewModel.SetActivityVisibleAsync(SectionPivot.SelectedIndex == 5));
    }
    private void ActivitySearch_TextChanged(object sender, TextChangedEventArgs e) => ReadActivityFilter();
    private void NetworkSearch_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_initialized && !_disposed && !_updatingFilter) _viewModel.SetNetworkSearch(NetworkSearchBox.Text);
    }
    private void NetworkClear_Click(object sender, RoutedEventArgs e)
    {
        NetworkSearchBox.Text = ""; _viewModel.SetNetworkSearch(""); UpdateState();
    }
    private void ActivityLevel_SelectionChanged(object sender, SelectionChangedEventArgs e) => ReadActivityFilter();
    private void ReadActivityFilter()
    {
        if (!_initialized || _disposed || _updatingFilter) return;
        var tag = (ActivityLevelPicker.SelectedItem as ComboBoxItem)?.Tag as string;
        _viewModel.SetActivityFilter(ActivitySearchBox.Text, Enum.TryParse<ServiceEventLevel>(tag, out var level) ? level : null);
    }
    private void ActivityClear_Click(object sender, RoutedEventArgs e)
    { ResetActivityFilterControls(); _viewModel.SetActivityFilter("", null); UpdateState(); }
    private void ResetActivityFilterControls()
    {
        _updatingFilter = true; ActivitySearchBox.Text = ""; ActivityLevelPicker.SelectedIndex = 0; _updatingFilter = false;
    }

    private void ViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (DispatcherQueue.HasThreadAccess) UpdateState();
        else DispatcherQueue.TryEnqueue(UpdateState);
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.RefreshAsync);

    private void OverviewCard_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: string tag } && int.TryParse(tag, out var index))
            SectionPivot.SelectedIndex = index;
    }

    private void FilterPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingFilter ||
            sender is not ComboBox { SelectedItem: ComboBoxItem { Tag: string tag } } ||
            !Enum.TryParse<ContainerManagerFilter>(tag, out var filter))
        {
            return;
        }
        _viewModel.SetFilter(filter);
    }

    private void ContainerList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ContainerItem item)
        {
            _compactShowsList = false;
            _viewModel.SelectContainer(item);
            UpdateState();
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e) => ShowList();

    private void ShowAll_Click(object sender, RoutedEventArgs e)
    {
        _viewModel.SetFilter(ContainerManagerFilter.All);
        SyncFilterPicker();
    }

    private void Page_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateAdaptiveLayout();

    private void BackAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (ActualWidth >= CompactWidth || _compactShowsList)
        {
            return;
        }
        args.Handled = true;
        ShowList();
    }

    private async void RefreshAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_viewModel.CanRefresh)
        {
            return;
        }
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
        CreateNetworkButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.RequiresReconnect &&
            _repository.ProfileId == _viewModel.ActiveProfileId && _repository.Availability.Features.Contains(ContainerManagerReadFeature.Networks);
        ManageContainersButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.RequiresReconnect &&
            _repository.ProfileId == _viewModel.ActiveProfileId && _repository.Availability.Features.Contains(ContainerManagerReadFeature.Containers);
        DeleteNetworksButton.IsEnabled = CreateNetworkButton.IsEnabled;
        DeleteImagesButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.RequiresReconnect &&
            _repository.ProfileId == _viewModel.ActiveProfileId && _repository.Availability.Features.Contains(ContainerManagerReadFeature.Images);
        BrowseRegistryButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.RequiresReconnect && _repository.ProfileId == _viewModel.ActiveProfileId;
        LoadingState.Visibility = Visible(
            _viewModel.ContentState == ContainerManagerContentState.Loading);
        EmptyState.Visibility = Visible(_viewModel.IsEmpty);
        FilteredEmptyState.Visibility = Visible(_viewModel.IsFilteredEmpty);
        ErrorState.Visibility = Visible(_viewModel.HasError);
        ContentState.Visibility = Visible(_viewModel.HasContent);
        UnavailableState.Visibility = Visible(_viewModel.IsUnavailable);
        ApplySectionState(_viewModel.ImagesState, ImagesList, ImagesLoadingState, ImagesEmptyState, ImagesErrorState, ImagesUnavailableState);
        ApplySectionState(_viewModel.NetworksState, NetworksList, NetworksLoadingState, NetworksEmptyState, NetworksErrorState, NetworksUnavailableState);
        NetworksFilteredEmptyState.Visibility = Visible(_viewModel.NetworksState == ContainerManagerContentState.FilteredEmpty);
        ApplySectionState(_viewModel.ProjectsState, ProjectsList, ProjectsLoadingState, ProjectsEmptyState, ProjectsErrorState, ProjectsUnavailableState);
        ApplySectionState(_viewModel.EventsState, EventsList, EventsLoadingState, EventsEmptyState, EventsErrorState, EventsUnavailableState);
        EventsFilteredEmptyState.Visibility = Visible(_viewModel.EventsState == ContainerManagerContentState.FilteredEmpty);
        ActivityRefreshNotice.IsOpen = _viewModel.ActivityReadFailed && !_viewModel.RequiresReconnect;
        RefreshButton.IsEnabled = _viewModel.CanRefresh;
        RefreshErrorNotice.IsOpen = _viewModel.HasRefreshError &&
            !_viewModel.HasError && !_viewModel.RequiresReconnect;
        SessionExpiredNotice.IsOpen = _viewModel.RequiresReconnect;
        ContainerList.SelectedItem = _viewModel.SelectedContainer;
        NoSelectionState.Visibility = Visible(!_viewModel.HasSelection);
        DetailState.Visibility = Visible(_viewModel.HasSelection);
        SyncFilterPicker();
        string Count(int? value) => value?.ToString("N0", System.Globalization.CultureInfo.CurrentCulture)
            ?? Localization.LocalizationService.Current.Get("UnknownValue");
        int? AvailableCount(ContainerManagerContentState state, int count) =>
            state is ContainerManagerContentState.Content or ContainerManagerContentState.Empty ? count : null;
        OverviewContainersCount.Text = Count(_viewModel.TotalContainerCount);
        OverviewImagesCount.Text = Count(AvailableCount(_viewModel.ImagesState, _viewModel.Images.Count));
        OverviewNetworksCount.Text = Count(_viewModel.TotalNetworkCount);
        OverviewProjectsCount.Text = Count(AvailableCount(_viewModel.ProjectsState, _viewModel.Projects.Count));
        UpdateAdaptiveLayout();
    }

    private static void ApplySectionState(
        ContainerManagerContentState state,
        FrameworkElement content,
        FrameworkElement loading,
        FrameworkElement empty,
        FrameworkElement error,
        FrameworkElement unavailable)
    {
        content.Visibility = Visible(state == ContainerManagerContentState.Content);
        loading.Visibility = Visible(state == ContainerManagerContentState.Loading);
        empty.Visibility = Visible(state == ContainerManagerContentState.Empty);
        error.Visibility = Visible(state == ContainerManagerContentState.Error);
        unavailable.Visibility = Visible(state == ContainerManagerContentState.Unavailable);
    }

    private void SyncFilterPicker()
    {
        _updatingFilter = true;
        FilterPicker.SelectedIndex = _viewModel.Filter switch
        {
            ContainerManagerFilter.All => 0,
            ContainerManagerFilter.Running => 1,
            ContainerManagerFilter.Stopped => 2,
            ContainerManagerFilter.Attention => 3,
            _ => 0,
        };
        _updatingFilter = false;
    }

    private void UpdateAdaptiveLayout()
    {
        if (ActualWidth >= CompactWidth)
        {
            ListColumn.Width = new GridLength(360);
            DetailColumn.Width = new GridLength(1, GridUnitType.Star);
            ListPane.Visibility = Visibility.Visible;
            DetailPane.Visibility = Visibility.Visible;
            BackButton.Visibility = Visibility.Collapsed;
            return;
        }

        ListColumn.Width = new GridLength(1, GridUnitType.Star);
        DetailColumn.Width = new GridLength(1, GridUnitType.Star);
        var showDetail = _viewModel.HasSelection && !_compactShowsList;
        ListPane.Visibility = Visible(!showDetail);
        DetailPane.Visibility = Visible(showDetail);
        BackButton.Visibility = Visible(showDetail);
    }

    private void ShowList()
    {
        _compactShowsList = true;
        UpdateAdaptiveLayout();
        ContainerList.Focus(FocusState.Keyboard);
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
        CloseNetworkCreation();
        CloseNetworkDeletion();
        CloseImageDeletion();
        CloseContainerMutations();
        CloseRegistry();
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        _viewModel.Dispose();
        ActivitySearchBox.Text = ""; EventsList.ItemsSource = null;
    }
}
