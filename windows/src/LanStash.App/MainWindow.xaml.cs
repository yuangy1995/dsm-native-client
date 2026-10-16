using LanStash.App.Localization;
using LanStash.App.Features.Chat;
using LanStash.App.Platform.Notifications;
using LanStash.App.ViewModels;
using LanStash.App.Views;
using LanStash.Domain;
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
    private readonly Dictionary<IDsmRepository, WindowsTransferNotificationService> _transferNotifications = new(ReferenceEqualityComparer.Instance);
    private IDsmRepository? _pendingTransferRepository;
    private Guid? _pendingTransferActivityId;
    private readonly WindowsTransferNotificationService.WindowsNotificationBackend _notificationBackend = new();
    private int _notificationGeneration;
    private bool _isExplicitExit;
    private bool _photoViewerOwnsFullScreen;
    private bool _restorePhotoViewerMaximized;
    private bool _officeExitDialogOpen;
    private bool _windowActive;
    private ChatNotificationTarget? _pendingChatTarget;
    private readonly Dictionary<string, ChatNotificationTarget> _chatNotificationTargets = new(StringComparer.Ordinal);
    internal Task ValidateOfficeCopyDestinationAsync(Guid profileId, string remotePath, string localPath, CancellationToken token) =>
        _viewModel.ValidateOfficeLocationAsync(profileId, remotePath, localPath, token);

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
        _appWindow.Destroying += (_, _) => { _isExplicitExit = true; DisposeTransferNotifications(); _notificationBackend.Dispose(); _trayIcon.Dispose(); };

        _viewModel.ConnectionChanged += OnConnectionChanged;
        _viewModel.ChatNotificationRequested += ShowChatNotification;
        _notificationBackend.Invoked += ChatNotificationInvoked;
        Activated += async (_, args) =>
        {
            _windowActive = args.WindowActivationState != WindowActivationState.Deactivated;
            if (RootFrame.Content is ShellPage shell) await shell.SetWindowActiveAsync(_windowActive);
        };
        _appWindow.Changed += async (_, _) =>
        {
            if (RootFrame.Content is ShellPage shell)
                await shell.SetWindowVisibleAsync(_appWindow.IsVisible &&
                    !(_appWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized }));
        };
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
            if (RootFrame.Content is ShellPage previous) previous.DetachChatPage();
            RootFrame.Content = _viewModel.Repository is null
                ? new LoginPage(_viewModel)
                : new ShellPage(_viewModel, GetTransferNotifications());
            if (RootFrame.Content is ShellPage current) _ = current.SetWindowActiveAsync(_windowActive);
        });
    }

    private void OnConnectionChanged(object? sender, bool connected)
    {
        var generation = Interlocked.Increment(ref _notificationGeneration);
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (generation != Volatile.Read(ref _notificationGeneration) || _isExplicitExit) return;
            ExitPhotoViewerFullScreen();
            foreach (var repository in _transferNotifications.Keys.Where(item => !_viewModel.IsConnectedWorkspace(item)).ToArray())
            {
                _transferNotifications[repository].Dispose();
                _transferNotifications.Remove(repository);
            }
            if (RootFrame.Content is ShellPage previous) previous.DetachChatPage();
            RootFrame.Content = connected
                ? new ShellPage(_viewModel, GetTransferNotifications())
                : new LoginPage(_viewModel);
            if (RootFrame.Content is ShellPage current)
            {
                await current.SetWindowActiveAsync(_windowActive);
                await current.SetWindowVisibleAsync(_appWindow.IsVisible &&
                    !(_appWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized }));
                if (generation != Volatile.Read(ref _notificationGeneration) || !ReferenceEquals(RootFrame.Content, current)) return;
                var transferRepository = _pendingTransferRepository;
                var transferActivityId = _pendingTransferActivityId;
                var chatTarget = _pendingChatTarget;
                _pendingTransferRepository = null; _pendingTransferActivityId = null; _pendingChatTarget = null;
                if (transferRepository is not null && ReferenceEquals(transferRepository, _viewModel.Repository))
                {
                    await current.ShowTransfersAsync(transferActivityId);
                }
                if (chatTarget is { } target && target.ProfileId == _viewModel.ActiveProfile?.Id && _viewModel.IsChatNotificationCurrent(target))
                {
                    try { await current.ShowChatNotificationAsync(target); }
                    catch { /* 已移除或无权读取的消息不按旧正文猜测定位。 */ }
                }
            }
        });
    }

    private WindowsTransferNotificationService? GetTransferNotifications()
    {
#if LANSTASH_UI_SMOKE
        return null;
#else
        if (_viewModel.Repository is not { } repository) return null;
        if (_transferNotifications.TryGetValue(repository, out var service)) return service;
        WindowsTransferNotificationService? created = null;
        created = new WindowsTransferNotificationService(id => ShowTransfersFromNotification(repository, created!, id), DispatchNotification, _notificationBackend);
        service = created;
        _transferNotifications.Add(repository, service);
        return service;
#endif
    }

    private void DisposeTransferNotifications()
    {
        foreach (var service in _transferNotifications.Values) service.Dispose();
        _transferNotifications.Clear();
    }

    private bool DispatchNotification(Action action)
    {
        if (DispatcherQueue.HasThreadAccess) { action(); return true; }
        return DispatcherQueue.TryEnqueue(() => action());
    }

    private void ShowChatNotification(ChatNotificationTarget target)
    {
        if (_isExplicitExit || !_viewModel.IsChatNotificationCurrent(target)) return;
        var token = Guid.NewGuid().ToString("N");
        if (_chatNotificationTargets.Count >= 512) _chatNotificationTargets.Remove(_chatNotificationTargets.Keys.First());
        _chatNotificationTargets[token] = target;
        try
        {
            _notificationBackend.ShowChat(LocalizationService.Current.Get("ChatNotificationTitle"),
                LocalizationService.Current.Get("ChatNotificationMessage"), token);
        }
        catch { _chatNotificationTargets.Remove(token); }
    }

    private void ChatNotificationInvoked(IReadOnlyDictionary<string, string> arguments)
    {
        if (arguments.Count != 2 || !arguments.TryGetValue("route", out var route) || route != "chat" ||
            !arguments.TryGetValue("context", out var token)) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_isExplicitExit || !_chatNotificationTargets.Remove(token, out var target) ||
                !_viewModel.IsChatNotificationCurrent(target)) return;
            _pendingChatTarget = target;
            _pendingTransferRepository = null;
            _pendingTransferActivityId = null;
            _appWindow.Show(); Activate();
            if (!_viewModel.ActivateChatNotificationWorkspace(target)) _pendingChatTarget = null;
        });
    }

    private void ShowTransfersFromNotification(IDsmRepository repository, WindowsTransferNotificationService source, Guid? activityId)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_isExplicitExit || !_viewModel.IsConnectedWorkspace(repository) ||
                !_transferNotifications.TryGetValue(repository, out var service) || !ReferenceEquals(service, source) || !source.IsEnabled) return;
            _pendingTransferRepository = repository;
            _pendingTransferActivityId = activityId;
            _pendingChatTarget = null;
            _appWindow.Show();
            Activate();
            if (!_viewModel.ActivateTransferWorkspace(repository)) { _pendingTransferRepository = null; _pendingTransferActivityId = null; }
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
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_officeExitDialogOpen || _isExplicitExit) return;
            _officeExitDialogOpen = true;
            try
            {
                if (RootFrame.Content is ShellPage shell && !await shell.PrepareExitAsync()) return;
                var office = _viewModel.OfficeEdits.HasActiveSessions;
                var busy = _viewModel.OfficeEdits.HasBusySessions || _viewModel.HasSendingChat;
                var desktop = _viewModel.HasRunningTransfers || _viewModel.HasChatDrafts || _viewModel.HasVoiceDrafts;
                if (office || desktop || busy)
                {
                    var l = LocalizationService.Current;
                    var messages = new List<string>();
                    if (_viewModel.HasSendingChat) messages.Add(l.Get("DesktopQuitSendingDetail"));
                    if (office) messages.Add(l.Get(_viewModel.OfficeEdits.HasBusySessions ? "OfficeQuitBusyDetail" : "OfficeQuitDetail"));
                    if (_viewModel.HasRunningTransfers) messages.Add(l.Get("DesktopQuitTransfersDetail"));
                    if (_viewModel.HasChatDrafts) messages.Add(l.Get("DesktopQuitDraftsDetail"));
                    if (_viewModel.HasVoiceDrafts) messages.Add(l.Get("DesktopQuitVoiceDetail"));
                    var dialog = new Microsoft.UI.Xaml.Controls.ContentDialog
                    {
                        XamlRoot = WindowRoot.XamlRoot, RequestedTheme = WindowRoot.ActualTheme,
                        Title = l.Get(desktop || _viewModel.HasSendingChat ? "DesktopQuitTitle" : busy ? "OfficeQuitBusyTitle" : "OfficeQuitTitle"),
                        Content = string.Join("\n\n", messages),
                        PrimaryButtonText = busy ? string.Empty : l.Get(desktop ? "DesktopQuitAction" : "OfficeQuitKeepCopies"),
                        CloseButtonText = l.Get("OfficeKeepRunning"), DefaultButton = Microsoft.UI.Xaml.Controls.ContentDialogButton.Close,
                    };
                    if (await dialog.ShowAsync() != Microsoft.UI.Xaml.Controls.ContentDialogResult.Primary) return;
                }
                // 等待确认期间状态可能变化，仍必须复查在途消息和文档保存。
                if (_viewModel.HasSendingChat || !_viewModel.OfficeEdits.TryPrepareExit()) return;
                _isExplicitExit = true;
                ExitPhotoViewerFullScreen();
                await _viewModel.ShutdownAsync();
                DisposeTransferNotifications();
                _notificationBackend.Dispose();
                _trayIcon.Dispose();
                Close();
            }
            catch (InvalidOperationException) { ShowMainWindow(); }
            finally { _officeExitDialogOpen = false; }
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
