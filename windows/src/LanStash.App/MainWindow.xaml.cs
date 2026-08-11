using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.App.Views;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using System.IO;
using WinRT.Interop;

namespace LanStash.App;

public sealed partial class MainWindow : Window
{
    private readonly AppViewModel _viewModel = new();
    private readonly AppWindow _appWindow;
    private readonly TrayIcon _trayIcon;
    private bool _isExplicitExit;
    private bool _photoViewerOwnsFullScreen;
    private bool _restorePhotoViewerMaximized;

    public MainWindow()
    {
        InitializeComponent();
        Title = LocalizationService.Current.Get("AppName");
        var windowHandle = WindowNative.GetWindowHandle(this);
        var windowId = Win32Interop.GetWindowIdFromWindow(windowHandle);
        _appWindow = AppWindow.GetFromWindowId(windowId);
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
        _appWindow.Destroying += (_, _) => _trayIcon.Dispose();

        _viewModel.ConnectionChanged += OnConnectionChanged;
        LocalizationService.Current.LanguageChanged += OnLanguageChanged;
        RootFrame.Content = new LoginPage(_viewModel);
        _ = _viewModel.InitializeAsync();
    }

    private void OnLanguageChanged(object? sender, EventArgs e)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            ExitPhotoViewerFullScreen();
            Title = LocalizationService.Current.Get("AppName");
            _trayIcon.UpdateText(
                LocalizationService.Current.Get("TrayTooltip"),
                LocalizationService.Current.Get("TrayOpenApp"),
                LocalizationService.Current.Get("TrayPauseCloudDrives"),
                LocalizationService.Current.Get("TrayResumeCloudDrives"),
                LocalizationService.Current.Get("TrayCloudDriveIssues"),
                LocalizationService.Current.Get("TrayExitApp"));
            RootFrame.Content = _viewModel.Repository is null
                ? new LoginPage(_viewModel)
                : new ShellPage(_viewModel);
        });
    }

    private void OnConnectionChanged(object? sender, bool connected)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            ExitPhotoViewerFullScreen();
            RootFrame.Content = connected
                ? new ShellPage(_viewModel)
                : new LoginPage(_viewModel);
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
        sender.Hide();
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
