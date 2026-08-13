using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class VirtualMachineManagerPage : Page, IDisposable
{
    private const double CompactWidth = 760;
    private readonly IVirtualMachineManagerRepository _repository;
    private readonly VirtualMachineManagerViewModel _viewModel;
    private bool _initialized;
    private bool _compactShowsDetail;
    private bool _disposed;

    internal VirtualMachineManagerPage(IVirtualMachineManagerRepository repository)
        : this(repository, new VirtualMachineManagerViewModel())
    {
    }

    internal VirtualMachineManagerPage(
        IVirtualMachineManagerRepository repository,
        VirtualMachineManagerViewModel viewModel)
    {
        ArgumentNullException.ThrowIfNull(repository);
        ArgumentNullException.ThrowIfNull(viewModel);
        InitializeComponent();
        _repository = repository;
        _viewModel = viewModel;
        DataContext = viewModel;
        viewModel.PropertyChanged += ViewModel_PropertyChanged;
        Loaded += VirtualMachineManagerPage_Loaded;
        UpdateState();
    }

    private async void VirtualMachineManagerPage_Loaded(object sender, RoutedEventArgs e)
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

    private void MachineList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is VirtualMachineItem machine)
        {
            _viewModel.SelectMachine(machine);
            _compactShowsDetail = true;
            UpdateState();
        }
    }

    private void Resources_Click(object sender, RoutedEventArgs e)
    {
        _compactShowsDetail = true;
        UpdateAdaptiveLayout();
        ResourcePivot.Focus(FocusState.Keyboard);
    }

    private void Back_Click(object sender, RoutedEventArgs e) => ShowMachineList();

    private void BackAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (ActualWidth >= CompactWidth || !_compactShowsDetail)
        {
            return;
        }
        args.Handled = true;
        ShowMachineList();
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

    private void Page_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateAdaptiveLayout();

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
        RefreshButton.IsEnabled = _viewModel.CanRefresh;
        RefreshErrorNotice.IsOpen = _viewModel.HasRefreshError && !_viewModel.RequiresReconnect;
        SessionExpiredNotice.IsOpen = _viewModel.RequiresReconnect;
        MachineList.SelectedItem = _viewModel.SelectedMachine;
        MachineDetailState.Visibility = Visible(_viewModel.HasSelection);
        NoSelectionState.Visibility = Visible(!_viewModel.HasSelection);
        ApplySectionState(
            _viewModel.MachinesState,
            MachineList,
            MachinesLoadingState,
            MachinesEmptyState,
            MachinesErrorState,
            MachinesUnavailableState);
        ApplySectionState(_viewModel.HostsState, HostsList, HostsLoadingState, HostsEmptyState, HostsErrorState, HostsUnavailableState);
        ApplySectionState(_viewModel.StoragesState, StoragesList, StoragesLoadingState, StoragesEmptyState, StoragesErrorState, StoragesUnavailableState);
        ApplySectionState(_viewModel.NetworksState, NetworksList, NetworksLoadingState, NetworksEmptyState, NetworksErrorState, NetworksUnavailableState);
        ApplySectionState(_viewModel.ImagesState, ImagesList, ImagesLoadingState, ImagesEmptyState, ImagesErrorState, ImagesUnavailableState);
        ApplySectionState(_viewModel.ProtectionState, ProtectionList, ProtectionLoadingState, ProtectionEmptyState, ProtectionErrorState, ProtectionUnavailableState);
        ApplySectionState(_viewModel.EventsState, EventsList, EventsLoadingState, EventsEmptyState, EventsErrorState, EventsUnavailableState);
        UpdateAdaptiveLayout();
    }

    private static void ApplySectionState(
        VirtualMachineManagerContentState state,
        FrameworkElement content,
        FrameworkElement loading,
        FrameworkElement empty,
        FrameworkElement error,
        FrameworkElement unavailable)
    {
        content.Visibility = Visible(state == VirtualMachineManagerContentState.Content);
        loading.Visibility = Visible(state == VirtualMachineManagerContentState.Loading);
        empty.Visibility = Visible(state == VirtualMachineManagerContentState.Empty);
        error.Visibility = Visible(state == VirtualMachineManagerContentState.Error);
        unavailable.Visibility = Visible(state == VirtualMachineManagerContentState.Unavailable);
    }

    private void UpdateAdaptiveLayout()
    {
        if (ActualWidth >= CompactWidth)
        {
            MachineColumn.Width = new GridLength(360);
            DetailColumn.Width = new GridLength(1, GridUnitType.Star);
            MachinePane.Visibility = Visibility.Visible;
            DetailPane.Visibility = Visibility.Visible;
            BackButton.Visibility = Visibility.Collapsed;
            return;
        }

        MachineColumn.Width = new GridLength(1, GridUnitType.Star);
        DetailColumn.Width = new GridLength(1, GridUnitType.Star);
        MachinePane.Visibility = Visible(!_compactShowsDetail);
        DetailPane.Visibility = Visible(_compactShowsDetail);
        BackButton.Visibility = Visible(_compactShowsDetail);
    }

    private void ShowMachineList()
    {
        _compactShowsDetail = false;
        UpdateAdaptiveLayout();
        MachineList.Focus(FocusState.Keyboard);
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
