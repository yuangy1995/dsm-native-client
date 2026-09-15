using LanStash.App.Features.Settings;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace LanStash.App.Views;

public sealed class WorkspaceNavigationItem(WorkspaceRoute route, bool expanded)
{
    public WorkspaceRoute Route { get; } = route;
    public string Title => LocalizationService.Current.Get(Route.TitleKey);
    public string Glyph => Route.Glyph;
    public Thickness Indent => new(Route.IsChild ? 16 : 0, 0, 0, 0);
    public Visibility ExpandVisibility => !Route.IsChild && WorkspaceRoutes.HasChildren(Route.Module)
        ? Visibility.Visible : Visibility.Collapsed;
    public string ExpandGlyph => expanded ? "\uE70D" : "\uE76C";
    public string ExpandTitle => LocalizationService.Current.Format(
        expanded ? "NativeCollapseModule" : "NativeExpandModule", Title);
}

public sealed partial class ShellPage
{
    private WorkspaceNavigation _navigation = null!;
    private readonly SemaphoreSlim _navigationSerial = new(1, 1);
    private long _navigationGeneration;
    private bool _isUnloaded;
    private bool _sidebarRequested = true;
    private bool _compactSidebarOpen;
    private double _sidebarWidth = WorkspaceLayout.SidebarDefault;
    private DesktopDriveSettingsPage? _desktopDriveSettings;

    private void InitializeNavigation()
    {
        _navigation = new WorkspaceNavigation(_app.ActiveProfile?.Id ?? Guid.Empty,
            _app.AvailableModules.Where(_settings.IsModuleVisible));
        ConnectionRouteText.Text = LocalizationService.Current.Get("NativeConnected");
        Loaded += Shell_Loaded;
        RebuildModuleNavigation(false);
    }

    private async void Shell_Loaded(object sender, RoutedEventArgs args)
    {
        if (_isUnloaded) return;
        UpdateSidebarLayout();
        await NavigateAsync(_navigation.Current, recordHistory: false);
    }

    private async void Navigation_ItemClick(object sender, ItemClickEventArgs args)
    {
        if (args.ClickedItem is WorkspaceNavigationItem item)
            await NavigateAsync(item.Route.Destination);
    }

    private async Task NavigateAsync(WorkspaceDestination destination, bool recordHistory = true)
    {
        if (_isUnloaded || !_navigation.IsAvailable(destination)) return;
        var generation = ++_navigationGeneration;
        await _navigationSerial.WaitAsync();
        try
        {
            if (_isUnloaded || generation != _navigationGeneration) return;
            NavigationError.IsOpen = false;
            await ApplyPageVisibilityAsync(false);
            if (_isUnloaded || generation != _navigationGeneration) return;
            if (recordHistory) _navigation.Navigate(destination);
            var route = WorkspaceRoutes.Get(destination);
            if (destination == WorkspaceDestination.DesktopDrive)
            {
                _desktopDriveSettings ??= new DesktopDriveSettingsPage(_app);
                ContentFrame.Content = _desktopDriveSettings;
            }
            else
            {
                await OpenModuleAsync(route.Module);
                if (_isUnloaded || generation != _navigationGeneration) return;
                await ApplyDestinationAsync(destination);
            }
            _compactSidebarOpen = false;
            UpdateSidebarLayout();
            RebuildModuleNavigation(false);
            // 页面切换只是停止非可见内容，不改变窗口实际可见状态。
            await ApplyPageVisibilityAsync(_windowIsActuallyVisible);
        }
        catch (OperationCanceledException) { }
        catch (ObjectDisposedException) when (_isUnloaded) { }
        catch (Exception)
        {
            if (!_isUnloaded && generation == _navigationGeneration)
            {
                NavigationError.Message = LocalizationService.Current.Get("NativeNavigationFailed");
                NavigationError.IsOpen = true;
            }
        }
        finally { _navigationSerial.Release(); }
    }

    private async Task ApplyDestinationAsync(WorkspaceDestination destination)
    {
        switch (ContentFrame.Content)
        {
            case FilesPage files:
                files.NavigateToWorkspaceDestination(destination);
                break;
            case Photos.SynologyPhotosPage photos:
                await photos.NavigateToWorkspaceDestinationAsync(destination);
                break;
            case ContainerManagerPage containers:
                containers.NavigateRequested = value => _ = NavigateAsync(value);
                containers.NavigateToWorkspaceDestination(destination);
                break;
            case VirtualMachineManagerPage machines:
                machines.NavigateRequested = value => _ = NavigateAsync(value);
                machines.NavigateToWorkspaceDestination(destination);
                break;
        }
    }

    private void ExpandModule_Click(object sender, RoutedEventArgs args)
    {
        if (sender is FrameworkElement { Tag: AppModule module })
        {
            _navigation.ToggleExpanded(module);
            RebuildModuleNavigation(false);
        }
    }

    private async void WorkspaceBack_Click(object sender, RoutedEventArgs args)
    {
        if (_navigation.GoBack()) await NavigateAsync(_navigation.Current, recordHistory: false);
    }

    private void RebuildModuleNavigation(bool routeHiddenSelectionToSettings)
    {
        var previous = _navigation.Current;
        _navigation.SetAvailableModules(_app.AvailableModules.Where(_settings.IsModuleVisible));
        var entries = _navigation.VisibleRoutes()
            .Select(route => new WorkspaceNavigationItem(route, _navigation.IsExpanded(route.Module))).ToArray();
        NavigationList.ItemsSource = entries.Where(item => item.Route.Module is not AppModule.Transfers and not AppModule.Settings).ToArray();
        FooterNavigationList.ItemsSource = entries.Where(item => item.Route.Module is AppModule.Transfers or AppModule.Settings).ToArray();
        NavigationList.SelectedItem = NavigationList.Items.OfType<WorkspaceNavigationItem>()
            .FirstOrDefault(item => item.Route.Destination == _navigation.Current);
        FooterNavigationList.SelectedItem = FooterNavigationList.Items.OfType<WorkspaceNavigationItem>()
            .FirstOrDefault(item => item.Route.Destination == _navigation.Current);
        DestinationTitle.Text = LocalizationService.Current.Get(WorkspaceRoutes.Get(_navigation.Current).TitleKey);
        WorkspaceBackButton.IsEnabled = _navigation.CanGoBack;
        if (routeHiddenSelectionToSettings && previous != _navigation.Current)
        {
            DisposeHiddenModulePage(WorkspaceRoutes.Get(previous).Module);
            _ = NavigateAsync(_navigation.Current, recordHistory: false);
        }
    }

    private void Settings_Changed(object? sender, AppSettingsChangedEventArgs args)
    {
        if (args.ModuleVisibilityChanged)
            DispatcherQueue.TryEnqueue(() =>
            {
                if (!_isUnloaded) RebuildModuleNavigation(routeHiddenSelectionToSettings: true);
            });
    }

    private void Shell_SizeChanged(object sender, SizeChangedEventArgs args) => UpdateSidebarLayout();
    private void ToggleSidebar_Click(object sender, RoutedEventArgs args)
    {
        if (ActualWidth < WorkspaceLayout.SidebarBreakpoint) _compactSidebarOpen = !_compactSidebarOpen;
        else _sidebarRequested = !_sidebarRequested;
        UpdateSidebarLayout();
    }
    private void SidebarResize_DragDelta(object sender, DragDeltaEventArgs args)
    {
        _sidebarWidth = WorkspaceLayout.ClampSidebar(_sidebarWidth + args.HorizontalChange);
        UpdateSidebarLayout();
    }
    private void CompactSidebarDismiss_Click(object sender, RoutedEventArgs args)
    {
        _compactSidebarOpen = false;
        UpdateSidebarLayout();
    }

    private void UpdateSidebarLayout()
    {
        if (SidebarColumn is null) return;
        var compact = ActualWidth > 0 && ActualWidth < WorkspaceLayout.SidebarBreakpoint;
        var visible = compact ? _compactSidebarOpen : _sidebarRequested;
        SidebarColumn.Width = new GridLength(!compact && visible ? _sidebarWidth : 0);
        SidebarHandleColumn.Width = new GridLength(!compact && visible ? 4 : 0);
        Grid.SetColumnSpan(Sidebar, compact ? 3 : 1);
        Sidebar.Width = _sidebarWidth;
        Sidebar.HorizontalAlignment = HorizontalAlignment.Left;
        Sidebar.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        SidebarResizeHandle.Visibility = !compact && visible ? Visibility.Visible : Visibility.Collapsed;
        CompactSidebarDismiss.Visibility = compact && visible ? Visibility.Visible : Visibility.Collapsed;
    }

    private bool _windowIsActuallyVisible = true;
    private async Task ApplyPageVisibilityAsync(bool visible)
    {
        _isWindowVisible = visible;
        _photos?.SetWindowVisible(visible && ReferenceEquals(ContentFrame.Content, _photos));
        if (_chat is not null)
            await _chat.SetWindowVisibleAsync(visible && ReferenceEquals(ContentFrame.Content, _chat));
        if (_activity is not null)
            await _activity.SetWindowVisibleAsync(visible && ReferenceEquals(ContentFrame.Content, _activity));
    }

    internal Task ShowTransfersAsync() => NavigateAsync(WorkspaceDestination.Transfers);

    private async void Logout_Click(object sender, RoutedEventArgs args)
    {
        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = localization.Get("DialogSignOutTitle"),
            Content = localization.Get("DialogSignOutMessage"),
            PrimaryButtonText = localization.Get("DialogSignOutAction"),
            CloseButtonText = localization.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await CloseFilesPageAsync();
            CloseNasDetailsPage();
            await _app.LogoutAsync();
        }
    }

    private static FrameworkElement CreateUnavailableWorkspace() => new TextBlock
    {
        Text = LocalizationService.Current.Get("NativeWorkspaceUnavailable"),
        TextWrapping = TextWrapping.Wrap,
        MaxWidth = 440, Margin = new Thickness(24),
        HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
    };
}
