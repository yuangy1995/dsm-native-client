using LanStash.App.Features.VirtualMachines;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
using Windows.System;
using WinRT.Interop;

namespace LanStash.App.Views;

internal sealed class VirtualMachineConsoleWindow : Window
{
    private readonly IVirtualMachineManagerRepository _repository;
    private readonly VirtualMachineSummary _baseline;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Grid _root = (Grid)Microsoft.UI.Xaml.Markup.XamlReader.Load(
        "<Grid xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Background=\"{ThemeResource ApplicationPageBackgroundThemeBrush}\"/>");
    private readonly Grid _browserHost = new();
    private readonly TextBlock _heading = new();
    private readonly ProgressRing _loading = new() { Width = 28, Height = 28, IsActive = true };
    private readonly InfoBar _error = new() { IsClosable = false, Severity = InfoBarSeverity.Error };
    private readonly Button _fullscreen = new() { MinHeight = 44 };
    private readonly List<(VirtualMachineConsoleDocument Document, MemoryStream Stream, Windows.Storage.Streams.IRandomAccessStream Native)> _documents = [];
    private readonly AppWindow _appWindow;
    private WebView2? _browser;
    private CoreWebView2? _core;
    private CoreWebView2Environment? _environment;
    private VirtualMachineConsoleProfile? _profile;
    private VirtualMachineConsoleSession? _session;
    private VirtualMachineConsoleBridge? _bridge;
    private readonly SemaphoreSlim _resourceReads = new(4, 4);
    private long _retainedBytes;
    private bool _initialized, _closed, _failed, _isolated, _navigating, _fullScreen, _restoreMaximized, _environmentCreating;
    internal string MachineId => _baseline.Id;
    private static LocalizationService L => LocalizationService.Current;

    internal VirtualMachineConsoleWindow(IVirtualMachineManagerRepository repository, VirtualMachineSummary baseline, ElementTheme theme)
    {
        _repository = repository; _baseline = baseline;
        Title = L.Format("VmConsoleTitle", baseline.Name);
        _root.RequestedTheme = theme;
        _root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new() { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
        _heading.Text = Title; _heading.Margin = new(16, 0, 140, 0); _heading.VerticalAlignment = VerticalAlignment.Center;
        var titleBar = new Grid { Height = 36 }; titleBar.Children.Add(_heading); _root.Children.Add(titleBar);
        ExtendsContentIntoTitleBar = true; SetTitleBar(titleBar);
        var tools = new Grid { Margin = new(12, 8, 12, 8), ColumnSpacing = 12 };
        tools.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); tools.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); tools.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var hint = new TextBlock { Text = L.Get("VmConsoleInputHint"), TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        _fullscreen.Content = L.Get("VmConsoleEnterFullscreen"); _fullscreen.Click += (_, _) => ToggleFullScreen();
        var close = new Button { Content = L.Get("ActionClose"), MinHeight = 44 }; close.Click += (_, _) => Close();
        tools.Children.Add(hint); Grid.SetColumn(_fullscreen, 1); tools.Children.Add(_fullscreen); Grid.SetColumn(close, 2); tools.Children.Add(close);
        Grid.SetRow(tools, 1); _root.Children.Add(tools);
        var status = new StackPanel { Margin = new(12, 0, 12, 8), Spacing = 8 }; status.Children.Add(_loading); status.Children.Add(_error);
        Grid.SetRow(status, 2); _root.Children.Add(status); Grid.SetRow(_browserHost, 3); _root.Children.Add(_browserHost);
        AutomationProperties.SetLiveSetting(_error, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        var accelerator = new Microsoft.UI.Xaml.Input.KeyboardAccelerator { Key = VirtualKey.F11 };
        accelerator.Invoked += (_, e) => { e.Handled = true; ToggleFullScreen(); }; _root.KeyboardAccelerators.Add(accelerator);
        Content = _root;
        _appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(WindowNative.GetWindowHandle(this)));
        _appWindow.Resize(new Windows.Graphics.SizeInt32(1100, 760));
        _appWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        _root.ActualThemeChanged += (_, _) => UpdateCaption(); _root.Loaded += (_, _) => UpdateCaption();
        Closed += (_, _) => { if (_closed) return; _closed = true; ReleaseBrowser(); _lifetime.Dispose(); };
    }

    internal async Task InitializeAsync()
    {
        if (_initialized || _closed) return; _initialized = true;
        try
        {
            var session = await _repository.OpenConsoleAsync(_baseline, _lifetime.Token);
            if (!IsActive) { session.Dispose(); return; }
            if (session.ProfileId != _repository.ProfileId || session.MachineId != _baseline.Id || session.MachineName != _baseline.Name)
            { session.Dispose(); throw new InvalidOperationException("vm.console.session_identity"); }
            _session = session;
            try { _ = CoreWebView2Environment.GetAvailableBrowserVersionString(); }
            catch { Fail(L.Get("VmConsoleBrowserUnavailable")); return; }
            _profile = VirtualMachineConsoleProfile.Create();
            _environmentCreating = true;
            try
            {
                _environment = await CoreWebView2Environment.CreateWithOptionsAsync(null, _profile.DirectoryPath, new CoreWebView2EnvironmentOptions
                    { AllowSingleSignOnUsingOSPrimaryAccount = false });
            }
            finally { _environmentCreating = false; if (!IsActive && _environment is null) _profile.TryDelete(); }
            var ownedProfile = _profile;
            _environment.BrowserProcessExited += (_, _) => ownedProfile.TryDelete();
            if (!IsActive) return;
            if (!_profile.Matches(_environment.UserDataFolder)) throw new InvalidOperationException("vm.console.profile_override");
            var options = _environment.CreateCoreWebView2ControllerOptions(); options.ProfileName = "Console"; options.IsInPrivateModeEnabled = true;
            _browser = new WebView2(); AutomationProperties.SetName(_browser, L.Format("VmConsoleAccessibleName", _baseline.Name));
            _browserHost.Children.Add(_browser);
            await _browser.EnsureCoreWebView2Async(_environment, options);
            if (!IsActive) { _browser.Close(); return; }
            _core = _browser.CoreWebView2;
            if (!_core.Profile.IsInPrivateModeEnabled) throw new InvalidOperationException("vm.console.private_profile_required");
            _isolated = true;
            _core.Profile.IsPasswordAutosaveEnabled = false; _core.Profile.IsGeneralAutofillEnabled = false;
            _core.Settings.AreDevToolsEnabled = false; _core.Settings.AreHostObjectsAllowed = false; _core.Settings.IsWebMessageEnabled = false;
            _core.Settings.AreDefaultContextMenusEnabled = false; _core.Settings.AreBrowserAcceleratorKeysEnabled = false;
            _core.Settings.IsStatusBarEnabled = false; _core.Settings.IsBuiltInErrorPageEnabled = false;
            _core.NavigationStarting += NavigationStarting;
            _core.FrameNavigationStarting += (_, e) => e.Cancel = true;
            _core.NavigationCompleted += NavigationCompleted;
            _core.NewWindowRequested += (_, e) => e.Handled = true;
            _core.PermissionRequested += (_, e) => { e.State = CoreWebView2PermissionState.Deny; e.SavesInProfile = false; };
            _core.DownloadStarting += (_, e) => e.Cancel = true;
            _core.BasicAuthenticationRequested += (_, e) => e.Cancel = true;
            _core.ClientCertificateRequested += (_, e) => { e.Cancel = true; e.Handled = true; };
            _core.LaunchingExternalUriScheme += (_, e) => e.Cancel = true;
            _core.ServerCertificateErrorDetected += (_, e) => { e.Action = CoreWebView2ServerCertificateErrorAction.Cancel; DispatcherQueue.TryEnqueue(() => Fail(L.Get("VmConsoleCertificateFailed"))); };
            _core.ProcessFailed += (_, _) => Fail(L.Get("VmConsoleLoadFailed"));
            _core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All, CoreWebView2WebResourceRequestSourceKinds.All);
            _core.WebResourceRequested += ResourceRequested;
            if (session.UsesManagedTransport)
            {
                var core = _core;
                var bridge = new VirtualMachineConsoleBridge(session, message => PostBridgeMessageAsync(core, message),
                    error => DispatcherQueue.TryEnqueue(() => Fail(L.Get(error is CertificateTrustChallengeException ? "VmConsoleCertificateFailed" : "VmConsoleLoadFailed"))));
                _bridge = bridge; core.Settings.IsWebMessageEnabled = true;
                // 用订阅时的控件绑定回调，不以 WinRT 事件重新投影的包装对象判断身份。
                core.WebMessageReceived += (_, e) => BridgeMessageReceived(core, e);
                await core.AddScriptToExecuteOnDocumentCreatedAsync(bridge.Script);
                if (!IsActive) return;
            }
            else session.InstallCookie(session.Policy.NavigationUri, value =>
            {
                var cookie = _core.CookieManager.CreateCookie("id", value, session.Policy.NavigationUri.IdnHost, "/");
                cookie.IsSecure = true; cookie.IsHttpOnly = true; cookie.SameSite = CoreWebView2CookieSameSiteKind.Strict;
                _core.CookieManager.AddOrUpdateCookie(cookie);
            });
            _navigating = true; _core.Navigate(session.Policy.NavigationUri.AbsoluteUri);
        }
        catch (OperationCanceledException) when (!IsActive || _lifetime.IsCancellationRequested) { }
        catch (DsmException error) { Fail(L.Format("VmConsoleFailureMessage", L.ResolveUserText(error.Message), L.ResolveUserText(error.Recovery))); }
        catch (CertificateTrustChallengeException) { Fail(L.Get("VmConsoleCertificateFailed")); }
        catch { Fail(L.Get("VmConsoleLoadFailed")); }
    }

    private bool IsActive => !_closed && !_failed;
    private async Task PostBridgeMessageAsync(CoreWebView2 core, string message)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var registration = _lifetime.Token.Register(() => completion.TrySetCanceled());
        if (!DispatcherQueue.TryEnqueue(() =>
        {
            try
            {
                if (IsActive && ReferenceEquals(_core, core)) core.PostWebMessageAsJson(message);
                completion.TrySetResult();
            }
            catch (Exception error) { completion.TrySetException(error); Fail(L.Get("VmConsoleLoadFailed")); }
        })) completion.TrySetCanceled();
        await completion.Task.ConfigureAwait(false);
    }
    private async void BridgeMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (!IsActive || !ReferenceEquals(sender, _core) || _bridge is not { } bridge || !Uri.TryCreate(e.Source, UriKind.Absolute, out var source)) return;
        try { await bridge.AcceptAsync(source, e.WebMessageAsJson); }
        catch { if (IsActive) Fail(L.Get("VmConsoleLoadFailed")); }
    }
    private void NavigationStarting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs e)
    {
        if (!_navigating && e.Uri == "about:blank") return;
        if (!IsActive || _session is null || !Uri.TryCreate(e.Uri, UriKind.Absolute, out var uri) || !_session.Policy.AllowsNavigation(uri))
        { e.Cancel = true; if (IsActive) DispatcherQueue.TryEnqueue(() => Fail(L.Get("VmConsoleNavigationBlocked"))); }
        else { _loading.IsActive = true; _loading.Visibility = Visibility.Visible; }
    }
    private void NavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        if (!IsActive || !_navigating) return;
        _loading.IsActive = false; _loading.Visibility = Visibility.Collapsed;
        if (!e.IsSuccess) Fail(L.Get("VmConsoleLoadFailed"));
    }
    private async void ResourceRequested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        var session = _session; var environment = _environment;
        if (environment is null) return;
        if (!IsActive || session is null || !Uri.TryCreate(e.Request.Uri, UriKind.Absolute, out var uri) || !session.Policy.AllowsResource(uri))
        { e.Response = environment.CreateWebResourceResponse(null, 403, "Blocked", "Cache-Control: no-store\r\n"); return; }
        var isDocument = e.ResourceContext == CoreWebView2WebResourceContext.Document;
        if (!isDocument && !session.UsesManagedTransport) return;
        if (e.Request.Method != "GET" || (isDocument ? !session.Policy.AllowsNavigation(uri) : session.Policy.ManagedAssetMediaType(uri) is null))
        { e.Response = environment.CreateWebResourceResponse(null, 403, "Blocked", "Cache-Control: no-store\r\n"); return; }
        using var deferral = e.GetDeferral();
        string? failure = null;
        try
        {
            await _resourceReads.WaitAsync(_lifetime.Token);
            VirtualMachineConsoleDocument document;
            try { document = isDocument ? await session.LoadDocumentAsync(_lifetime.Token) : await session.LoadAssetAsync(uri, _lifetime.Token); }
            finally { _resourceReads.Release(); }
            if (!IsActive) { document.Dispose(); return; }
            if (_documents.Count >= 256 || _retainedBytes + document.Content.LongLength > 64L * 1024 * 1024)
            { document.Dispose(); throw new InvalidOperationException("vm.console.resource_limit"); }
            var headers = document.ResponseHeaders(session.Policy, session.UsesManagedTransport);
            var stream = new MemoryStream(document.Content, writable: false); var native = stream.AsRandomAccessStream();
            _documents.Add((document, stream, native)); _retainedBytes += document.Content.LongLength;
            e.Response = environment.CreateWebResourceResponse(native, 200, "OK", headers);
        }
        catch
        {
            if (IsActive)
            { e.Response = environment.CreateWebResourceResponse(null, 502, "Unavailable", "Cache-Control: no-store\r\n"); failure = L.Get("VmConsoleLoadFailed"); }
        }
        finally { try { deferral.Complete(); } catch (Exception) when (!IsActive) { } }
        if (failure is not null) Fail(failure);
    }
    private void Fail(string message)
    {
        if (!IsActive) return; _failed = true; ReleaseBrowser();
        _loading.IsActive = false; _loading.Visibility = Visibility.Collapsed; _error.Message = message; _error.IsOpen = true;
    }
    private void ReleaseBrowser()
    {
        _bridge?.Dispose(); _bridge = null; _lifetime.Cancel(); _session?.Dispose(); _session = null;
        try { _core?.Stop(); if (_isolated) _core?.CookieManager.DeleteAllCookies(); } catch (Exception) { /* 失败/退出时浏览进程可能已结束。 */ }
        try { _browser?.Close(); } catch (Exception) { /* 关闭与浏览进程退出可以同时发生。 */ }
        _browserHost.Children.Clear(); _core = null;
        foreach (var (document, stream, native) in _documents) { native.Dispose(); stream.Dispose(); document.Dispose(); } _documents.Clear(); _retainedBytes = 0;
        if (_environment is null && !_environmentCreating) _profile?.TryDelete(); // 已创建的浏览进程退出后才清理其目录。
    }
    private void ToggleFullScreen()
    {
        if (_closed) return;
        if (!_fullScreen) _restoreMaximized = _appWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
        _fullScreen = !_fullScreen;
        _appWindow.SetPresenter(_fullScreen ? AppWindowPresenterKind.FullScreen : AppWindowPresenterKind.Overlapped);
        if (!_fullScreen && _restoreMaximized && _appWindow.Presenter is OverlappedPresenter presenter) presenter.Maximize();
        _fullscreen.Content = L.Get(_fullScreen ? "VmConsoleExitFullscreen" : "VmConsoleEnterFullscreen");
    }
    private void UpdateCaption()
    {
        var color = _root.ActualTheme == ElementTheme.Dark ? Colors.White : Colors.Black;
        _appWindow.TitleBar.ButtonBackgroundColor = Colors.Transparent; _appWindow.TitleBar.ButtonInactiveBackgroundColor = Colors.Transparent;
        _appWindow.TitleBar.ButtonForegroundColor = color; _appWindow.TitleBar.ButtonInactiveForegroundColor = color;
    }
#if LANSTASH_UI_SMOKE
    internal FrameworkElement SmokeRoot => _root;
    internal CoreWebView2? SmokeCore => _core;
    internal bool SmokeHasError => _error.IsOpen;
    internal bool SmokeLoading => _loading.IsActive;
    internal bool SmokeIsFullscreen => _appWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;
    internal string? SmokeProfilePath => _profile?.DirectoryPath;
    internal void SmokeToggleFullscreen() => ToggleFullScreen();
#endif
}
