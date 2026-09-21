using LanStash.App.Localization;
using LanStash.App.Platform.Notifications;
using LanStash.App.ViewModels;
using LanStash.App.Views;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using System.IO;
using WinRT.Interop;

namespace LanStash.App;

public sealed partial class MainWindow : Window
{
    private readonly AppViewModel _viewModel = new();
    private readonly AppWindow _appWindow;
    private readonly TrayIcon _trayIcon;
    private WindowsTransferNotificationService? _transferNotifications;
    private readonly WindowsTransferNotificationService.WindowsNotificationBackend _notificationBackend = new();
    private int _notificationGeneration;
    private bool _isExplicitExit;
    private bool _photoViewerOwnsFullScreen;
    private bool _restorePhotoViewerMaximized;

    public MainWindow()
    {
        InitializeComponent();
        Title = LocalizationService.Current.Get("AppName");
        WindowTitle.Text = Title;
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(WindowTitleBar);
        var windowHandle = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(windowHandle);
        _appWindow = AppWindow.GetFromWindowId(windowId);
        WindowRoot.ActualThemeChanged += (_, _) => DispatcherQueue.TryEnqueue(UpdateCaptionColors);
        WindowRoot.Loaded += (_, _) => UpdateCaptionColors();
        UpdateCaptionColors();
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico");
        _appWindow.SetIcon(iconPath);
        _appWindow.Resize(new Windows.Graphics.SizeInt32(1280, 820));
        _appWindow.Closing += OnWindowClosing;
        _trayIcon = new TrayIcon(
            windowHandle,
            iconPath,
            LocalizationService.Current.Get("TrayTooltip"),
            LocalizationService.Current.Get("TrayOpenApp"),
            LocalizationService.Current.Get("TrayPauseCloudDrives"),
            LocalizationService.Current.Get("TrayResumeCloudDrives"),
            LocalizationService.Current.Get("TrayCloudDriveIssues"),
            LocalizationService.Current.Get("TrayExitApp"),
            () => _viewModel.CurrentDesktopDriveCount,
            () => _viewModel.AreCurrentDesktopDrivesPaused,
            () => _viewModel.CurrentDesktopDriveIssueCount,
            ShowMainWindow,
            ToggleCloudDrives,
            ShowCloudDriveIssues,
            RequestExit);
        _appWindow.Destroying += (_, _) => { _isExplicitExit = true; _transferNotifications?.Dispose(); _notificationBackend.Dispose(); _trayIcon.Dispose(); };

        _viewModel.ConnectionChanged += OnConnectionChanged;
        LocalizationService.Current.LanguageChanged += OnLanguageChanged;
#if LANSTASH_UI_SMOKE
        if (int.TryParse(Environment.GetEnvironmentVariable("LANSTASH_SMOKE_WIDTH"), out var smokeWidth))
            _appWindow.Resize(new Windows.Graphics.SizeInt32(smokeWidth,
                int.TryParse(Environment.GetEnvironmentVariable("LANSTASH_SMOKE_HEIGHT"), out var smokeHeight) ? smokeHeight : 820));
        // 合成 UI 宿主不加载本机配置、凭据或任何远程数据。
        _viewModel.InitializeSmokeWorkspace();
        if (Environment.GetEnvironmentVariable("LANSTASH_SMOKE_SCENARIO") == "login") _viewModel.InitializeSmokeLogin();
        RootFrame.Content = Environment.GetEnvironmentVariable("LANSTASH_SMOKE_SCENARIO") == "login"
            ? new LoginPage(_viewModel) : new ShellPage(_viewModel);
        RootFrame.Loaded += async (_, _) => await SmokeSnapshot.SaveAsync(RootFrame);
#else
        _notificationBackend.StartListening();
        RootFrame.Content = new LoginPage(_viewModel);
        _ = _viewModel.InitializeAsync();
#endif
    }

    private void UpdateCaptionColors()
    {
        // 系统标题栏按钮也跟随当前窗口主题，保留原生窗口操作和命中区域。
        var caption = _appWindow.TitleBar;
        caption.ButtonBackgroundColor = Colors.Transparent;
        caption.ButtonInactiveBackgroundColor = Colors.Transparent;
        var foreground = ((SolidColorBrush)WindowTitle.Foreground).Color;
        caption.ButtonForegroundColor = foreground;
        caption.ButtonInactiveForegroundColor = foreground;
        caption.ButtonHoverForegroundColor = foreground;
        caption.ButtonPressedForegroundColor = foreground;
        caption.ButtonHoverBackgroundColor = WindowRoot.ActualTheme == ElementTheme.Dark
            ? ColorHelper.FromArgb(255, 89, 94, 96) : ColorHelper.FromArgb(255, 211, 215, 221);
        caption.ButtonPressedBackgroundColor = ((SolidColorBrush)WindowRoot.Background).Color;
    }

    private void OnLanguageChanged(object? sender, EventArgs e)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            ExitPhotoViewerFullScreen();
            Title = LocalizationService.Current.Get("AppName");
            WindowTitle.Text = Title;
            _trayIcon.UpdateText(
                LocalizationService.Current.Get("TrayTooltip"),
                LocalizationService.Current.Get("TrayOpenApp"),
                LocalizationService.Current.Get("TrayPauseCloudDrives"),
                LocalizationService.Current.Get("TrayResumeCloudDrives"),
                LocalizationService.Current.Get("TrayCloudDriveIssues"),
                LocalizationService.Current.Get("TrayExitApp"));
            if (_viewModel.Repository is not null)
            {
                _transferNotifications ??= CreateTransferNotifications();
            }
            RootFrame.Content = _viewModel.Repository is null
                ? new LoginPage(_viewModel)
                : new ShellPage(_viewModel, _transferNotifications);
        });
    }

    private void OnConnectionChanged(object? sender, bool connected)
    {
        Interlocked.Increment(ref _notificationGeneration);
        DispatcherQueue.TryEnqueue(() =>
        {
            ExitPhotoViewerFullScreen();
            _transferNotifications?.Dispose();
            _transferNotifications = connected
                ? CreateTransferNotifications()
                : null;
            RootFrame.Content = connected
                ? new ShellPage(_viewModel, _transferNotifications)
                : new LoginPage(_viewModel);
        });
    }

    private WindowsTransferNotificationService CreateTransferNotifications()
    {
        WindowsTransferNotificationService? service = null;
        var generation = Volatile.Read(ref _notificationGeneration);
        service = new WindowsTransferNotificationService(() => ShowTransfersFromNotification(service!, generation), DispatchNotification, _notificationBackend);
        return service;
    }

    private bool DispatchNotification(Action action)
    {
        if (DispatcherQueue.HasThreadAccess) { action(); return true; }
        return DispatcherQueue.TryEnqueue(() => action());
    }

    private void ShowTransfersFromNotification(WindowsTransferNotificationService source, int generation)
    {
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_isExplicitExit || !source.IsEnabled || generation != Volatile.Read(ref _notificationGeneration) || !ReferenceEquals(source, _transferNotifications) ||
                _viewModel.Repository is null || RootFrame.Content is not ShellPage) return;
            _appWindow.Show();
            Activate();
            if (RootFrame.Content is ShellPage shell)
            {
                await shell.SetWindowVisibleAsync(true);
                if (_isExplicitExit || !source.IsEnabled || generation != Volatile.Read(ref _notificationGeneration) ||
                    !ReferenceEquals(source, _transferNotifications) || !ReferenceEquals(RootFrame.Content, shell)) return;
                await shell.ShowTransfersAsync();
            }
        });
    }

    private async void OnWindowClosing(
        AppWindow sender,
        AppWindowClosingEventArgs args)
    {
        if (_isExplicitExit)
        {
            return;
        }
        args.Cancel = true;
        if (_trayIcon.EnsureRegistered()) sender.Hide();
        else if (sender.Presenter is OverlappedPresenter presenter) presenter.Minimize();
        if (RootFrame.Content is ShellPage shell)
        {
            await shell.SetWindowVisibleAsync(false);
        }
    }

    private void ShowMainWindow()
    {
        DispatcherQueue.TryEnqueue(async () =>
        {
            _appWindow.Show();
            Activate();
            if (RootFrame.Content is ShellPage shell)
            {
                await shell.SetWindowVisibleAsync(true);
            }
        });
    }

    private void RequestExit()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            _isExplicitExit = true;
            ExitPhotoViewerFullScreen();
            _viewModel.Shutdown();
            _transferNotifications?.Dispose();
            _transferNotifications = null;
            _notificationBackend.Dispose();
            _trayIcon.Dispose();
            Close();
        });
    }

    private async void ToggleCloudDrives()
    {
        try
        {
            await _viewModel.ToggleCurrentDesktopDrivesAsync();
        }
        catch
        {
            ShowMainWindow();
        }
    }

    private void ShowCloudDriveIssues() => ShowMainWindow();

    internal bool EnterPhotoViewerFullScreen()
    {
        if (_photoViewerOwnsFullScreen)
        {
            return true;
        }
        if (_appWindow.Presenter is not OverlappedPresenter presenter)
        {
            return false;
        }

        _restorePhotoViewerMaximized =
            presenter.State == OverlappedPresenterState.Maximized;
        _appWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
        _photoViewerOwnsFullScreen = true;
        return true;
    }

    internal void ExitPhotoViewerFullScreen()
    {
        if (!_photoViewerOwnsFullScreen)
        {
            return;
        }

        var restoreMaximized = _restorePhotoViewerMaximized;
        _photoViewerOwnsFullScreen = false;
        _restorePhotoViewerMaximized = false;
        _appWindow.SetPresenter(AppWindowPresenterKind.Overlapped);
        if (restoreMaximized && _appWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.Maximize();
        }
    }
}
