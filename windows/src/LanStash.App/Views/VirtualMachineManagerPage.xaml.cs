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
            await UpdateTaskVisibilityAsync();
            return;
        }
        _initialized = true;
        await RunAsync(() => _viewModel.ActivateAsync(_repository));
        await UpdateTaskVisibilityAsync();
    }

    private void ViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdateState);

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await RefreshCurrentSectionAsync();

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
        ResourcePivot.SelectedIndex = 1;
        UpdateAdaptiveLayout();
        ResourcePivot.Focus(FocusState.Keyboard);
    }

    private void Back_Click(object sender, RoutedEventArgs e) => ShowMachineList();

    private void BackAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_compactShowsDetail)
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
        if (ReferenceEquals(ResourcePivot.SelectedItem, TasksTab))
        {
            args.Handled = true;
            await TasksPane.RefreshAsync();
            return;
        }
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
        BatchPowerButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.RequiresReconnect && _repository.ProfileId == _viewModel.ActiveProfileId;
        DeleteMachinesButton.IsEnabled = BatchPowerButton.IsEnabled;
        DeleteImagesButton.IsEnabled = BatchPowerButton.IsEnabled;
        ImportImageButton.IsEnabled = BatchPowerButton.IsEnabled;
        ManageNetworksButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.RequiresReconnect && _repository.CanReadNetworkManagement;
        CreateMachineButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.RequiresReconnect && _repository.ProfileId == _viewModel.ActiveProfileId;
        RefreshErrorNotice.IsOpen = _viewModel.HasRefreshError && !_viewModel.RequiresReconnect;
        SessionExpiredNotice.IsOpen = _viewModel.RequiresReconnect;
        MachineList.SelectedItem = _viewModel.SelectedMachine;
        UpdatePowerControls();
        EditSettingsButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.RequiresReconnect && _repository.ProfileId == _viewModel.ActiveProfileId && _viewModel.HasSelection;
        ConsoleButton.IsEnabled = EditSettingsButton.IsEnabled && _repository.CanOpenConsole && _viewModel.SelectedMachine?.Machine.State == VirtualMachineOperationalState.Running;
        ConsoleAvailabilityNotice.Visibility = Visible(EditSettingsButton.IsEnabled && !ConsoleButton.IsEnabled);
        ConsoleAvailabilityNotice.Text = Localization.LocalizationService.Current.Get(_repository.CanOpenConsole ? "VmConsoleNeedsRunning" : "VmConsoleUnavailable");
        if (_viewModel.RequiresReconnect || _repository.ProfileId != _viewModel.ActiveProfileId) CloseConsoleWindow();
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
        MachineColumn.Width = _compactShowsDetail ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        DetailColumn.Width = _compactShowsDetail ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
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
        ClosePowerDialog();
        CloseMachineBatchDialog();
        CloseSettingsDialog();
        CloseNetworksDialog();
        CloseCreationDialog();
        CloseImageImportDialog();
        CloseConsoleWindow();
        TasksPane.Dispose();
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        _viewModel.Dispose();
    }
}
