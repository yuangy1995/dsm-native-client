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
        InitializeComponent();
        _repository = repository;
        _viewModel = viewModel;
        DataContext = viewModel;
        viewModel.PropertyChanged += ViewModel_PropertyChanged;
        Loaded += ContainerManagerPage_Loaded;
        UpdateState();
    }

    private LanStash.App.Features.Settings.WorkspaceDestination _destination;
    internal Action<LanStash.App.Features.Settings.WorkspaceDestination>? NavigateRequested { get; set; }

    internal void NavigateToWorkspaceDestination(LanStash.App.Features.Settings.WorkspaceDestination destination)
    {
        if (_disposed) return;
        _destination = destination;
        UpdateWorkspaceSection();
    }

    private void OverviewSection_Click(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: string tag } &&
            Enum.TryParse<LanStash.App.Features.Settings.WorkspaceDestination>(tag, out var destination))
        {
            if (NavigateRequested is { } navigate) navigate(destination);
            else NavigateToWorkspaceDestination(destination);
        }
    }

    private void UpdateWorkspaceSection()
    {
        if (_disposed) return;
        var index = _destination switch
        {
            LanStash.App.Features.Settings.WorkspaceDestination.ContainerList => 0,
            LanStash.App.Features.Settings.WorkspaceDestination.ContainerImages => 1,
            LanStash.App.Features.Settings.WorkspaceDestination.ContainerNetworks => 2,
            LanStash.App.Features.Settings.WorkspaceDestination.ContainerProjects => 3,
            LanStash.App.Features.Settings.WorkspaceDestination.ContainerEvents => 4,
            _ => -1,
        };
        FrameworkElement[] sections = [ContainersSection, ImagesSection, NetworksSection, ProjectsSection, EventsSection];
        for (var i = 0; i < sections.Length; i++) sections[i].Visibility = Visible(index == i);
        OverviewSection.Visibility = Visible(index < 0);
        ContainerSections.Visibility = Visible(index >= 0);
        var l = LanStash.App.Localization.LocalizationService.Current;
        TextBlock[] headings = [ContainerListHeading, ContainerImagesHeading, ContainerNetworksHeading, ContainerProjectsHeading, ContainerEventsHeading];
        TextBlock[] values = [ContainerListCount, ContainerImagesCount, ContainerNetworksCount, ContainerProjectsCount, ContainerEventsCount];
        string[] keys = ["NativeNavContainerList", "NativeNavContainerImages", "NativeNavContainerNetworks", "NativeNavContainerProjects", "NativeNavContainerEvents"];
        int[] counts = [_viewModel.Containers.Count, _viewModel.Images.Count, _viewModel.Networks.Count, _viewModel.Projects.Count, _viewModel.Events.Count];
        ContainerManagerContentState[] states = [_viewModel.ContainersState, _viewModel.ImagesState, _viewModel.NetworksState, _viewModel.ProjectsState, _viewModel.EventsState];
        for (var i = 0; i < headings.Length; i++)
        {
            headings[i].Text = l.Get(keys[i]);
            // 未加载或接口不可用不是“零个资源”。
            values[i].Text = states[i] is ContainerManagerContentState.Content or ContainerManagerContentState.Empty
                ? counts[i].ToString("N0") : l.Get("NativeValueUnavailable");
        }
    }

    private async void ContainerManagerPage_Loaded(object sender, RoutedEventArgs e)
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

    private void FilterPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingFilter ||
            FilterPicker.SelectedItem is not ComboBoxItem { Tag: string tag } ||
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
        LoadingState.Visibility = Visible(
            _viewModel.ContentState == ContainerManagerContentState.Loading);
        EmptyState.Visibility = Visible(_viewModel.IsEmpty);
        FilteredEmptyState.Visibility = Visible(_viewModel.IsFilteredEmpty);
        ErrorState.Visibility = Visible(_viewModel.HasError);
        ContentState.Visibility = Visible(_viewModel.HasContent);
        UnavailableState.Visibility = Visible(_viewModel.IsUnavailable);
        ApplySectionState(_viewModel.ImagesState, ImagesList, ImagesLoadingState, ImagesEmptyState, ImagesErrorState, ImagesUnavailableState);
        ApplySectionState(_viewModel.NetworksState, NetworksList, NetworksLoadingState, NetworksEmptyState, NetworksErrorState, NetworksUnavailableState);
        ApplySectionState(_viewModel.ProjectsState, ProjectsList, ProjectsLoadingState, ProjectsEmptyState, ProjectsErrorState, ProjectsUnavailableState);
        ApplySectionState(_viewModel.EventsState, EventsList, EventsLoadingState, EventsEmptyState, EventsErrorState, EventsUnavailableState);
        RefreshButton.IsEnabled = _viewModel.CanRefresh;
        RefreshErrorNotice.IsOpen = _viewModel.HasRefreshError &&
            !_viewModel.HasError && !_viewModel.RequiresReconnect;
        SessionExpiredNotice.IsOpen = _viewModel.RequiresReconnect;
        ContainerList.SelectedItem = _viewModel.SelectedContainer;
        NoSelectionState.Visibility = Visible(!_viewModel.HasSelection);
        DetailState.Visibility = Visible(_viewModel.HasSelection);
        SyncFilterPicker();
        UpdateAdaptiveLayout();
        UpdateWorkspaceSection();
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
            ListColumn.Width = new GridLength(300);
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
        NavigateRequested = null;
        Loaded -= ContainerManagerPage_Loaded;
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        _viewModel.Dispose();
    }
}
