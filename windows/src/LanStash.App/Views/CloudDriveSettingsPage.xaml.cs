using LanStash.App.CloudDrive;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace LanStash.App.Views;

public sealed partial class CloudDriveSettingsPage : Page
{
    private readonly AppViewModel _app;
    private readonly Func<DesktopDriveMapping, CancellationToken, Task<CloudDriveRefreshSummary>> _refreshFiles;
    private bool _active;
    private bool _busy;
    private CancellationTokenSource? _refreshCancellation;
    private readonly Guid? _profileId;
    private ContentDialog? _confirmation;
    public event EventHandler? BackRequested;
    private DesktopDriveCacheLocation _cacheLocation =
        DesktopDriveCacheLocation.SystemDefault;
    private sealed record CacheLimitChoice(long Bytes, string DisplayName);

    public CloudDriveSettingsPage(AppViewModel app) : this(app, app.RefreshDesktopDriveFilesAsync) { }

    internal CloudDriveSettingsPage(AppViewModel app, Func<DesktopDriveMapping, CancellationToken, Task<CloudDriveRefreshSummary>> refreshFiles)
    {
        _app = app;
        _refreshFiles = refreshFiles;
        _profileId = app.ActiveProfile?.Id;
        InitializeComponent();
        var localization = LocalizationService.Current;
        TitleText.Text = localization.Get("CloudDriveTitle");
        BackButton.Content = localization.Get("CloudDriveBackToSettings");
        EnableTestButton.Content = localization.Get("CloudDriveEnableSessionTest");
        CancelRefreshButton.Content = localization.Get("CloudDriveCancelRefresh");
        CloudDriveDescription.Text = localization.Get("CloudDriveDescription");
        MappingNameTextBox.Header = localization.Get("CloudDriveMappingName");
        MappingNameTextBox.PlaceholderText =
            localization.Get("CloudDriveMappingNamePlaceholder");
        FolderPathTextBox.Header = localization.Get("CloudDriveFolderPath");
        FolderPathTextBox.PlaceholderText = localization.Get("CloudDriveFolderPlaceholder");
        AutomationProperties.SetName(
            FolderPathTextBox,
            localization.Get("CloudDriveFolderPath"));
        AddNasButton.Content = localization.Get("CloudDriveAddNas");
        AddFolderButton.Content = localization.Get("CloudDriveAddFolder");
        CacheLimitSelector.Header = localization.Get("CloudDriveCacheLimit");
        CacheLimitSelector.ItemsSource = CacheLimitChoices();
        CacheLimitSelector.SelectedIndex = 1;
        LaunchAtLoginChoice.Content = localization.Get("CloudDriveLaunchAtLogin");
        CacheDiskText.Text = localization.Get("CloudDriveCacheDiskDefault");
        ChooseCacheDiskButton.Content = localization.Get("CloudDriveChooseCacheDisk");
        UseDefaultCacheDiskButton.Content =
            localization.Get("CloudDriveUseDefaultCacheDisk");
        Loaded += (_, _) =>
        {
            _active = true;
            _app.DesktopDriveProgressChanged -= DesktopDriveProgressChanged;
            _app.DesktopDriveProgressChanged += DesktopDriveProgressChanged;
            UpdateValidationState();
            RenderMappings();
        };
        Unloaded += (_, _) =>
        {
            _active = false;
            _refreshCancellation?.Cancel();
            _app.DesktopDriveProgressChanged -= DesktopDriveProgressChanged;
            _confirmation?.Hide();
        };
        RenderMappings();
        UpdateValidationState();
    }

    private bool IsCurrent => _active && _profileId is not null && _app.ActiveProfile?.Id == _profileId && _app.Repository is not null;
    private bool CanManage => IsCurrent && !_busy && DesktopCloudDriveCapabilityGate.IsRegistrationEnabled;

    private void BackButton_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, EventArgs.Empty);

    private void UpdateValidationState()
    {
        var enabled = DesktopCloudDriveCapabilityGate.IsRegistrationEnabled;
        ValidationNotice.Message = LocalizationService.Current.Get(!IsCurrent ? "CloudDriveSignInRequired" : enabled ? "CloudDriveSessionTestEnabled" : "CloudDriveSessionTestNotice");
        EnableTestButton.Visibility = enabled ? Visibility.Collapsed : Visibility.Visible;
        EnableTestButton.IsEnabled = IsCurrent && !_busy;
        SetBusy(_busy);
    }

    private async void EnableTestButton_Click(object sender, RoutedEventArgs e)
    {
        if (!IsCurrent || _busy || _confirmation is not null) return;
        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot, RequestedTheme = ActualTheme,
            Title = localization.Get("CloudDriveEnableSessionTest"),
            Content = localization.Get("CloudDriveSessionTestConfirm"),
            PrimaryButtonText = localization.Get("CloudDriveEnableSessionTest"),
            CloseButtonText = localization.Get("ActionCancel"), DefaultButton = ContentDialogButton.Close,
        };
        _confirmation = dialog;
        try
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || !IsCurrent) return;
            DesktopCloudDriveCapabilityGate.EnableForCurrentProcess();
            UpdateValidationState();
        }
        finally { _confirmation = null; }
    }

    private async void AddNasButton_Click(object sender, RoutedEventArgs e) =>
        await AddMappingAsync(null);

    private async void AddFolderButton_Click(object sender, RoutedEventArgs e) =>
        await AddMappingAsync(FolderPathTextBox.Text);

    private async Task AddMappingAsync(string? folderPath)
    {
        if (!IsCurrent || _busy || !DesktopCloudDriveCapabilityGate.IsRegistrationEnabled) return;
        SetBusy(true);
        try
        {
            var limit = (CacheLimitSelector.SelectedItem as CacheLimitChoice)?.Bytes
                ?? DesktopDriveCachePolicy.DefaultTemporaryLimitBytes;
            await _app.AddDesktopDriveAsync(
                MappingNameTextBox.Text,
                folderPath,
                new DesktopDriveCachePolicy(_cacheLocation, limit),
                launchAtLogin: LaunchAtLoginChoice.IsChecked == true);
            FolderPathTextBox.Text = string.Empty;
            MappingNameTextBox.Text = string.Empty;
            ShowMessage("CloudDriveAdded", InfoBarSeverity.Success);
            RenderMappings();
        }
        catch (InvalidOperationException error)
        {
            ShowMessage(error.Message, InfoBarSeverity.Warning);
        }
        catch
        {
            ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private void RenderMappings()
    {
        var localization = LocalizationService.Current;
        CloudDriveList.Children.Clear();
        var mappings = _app.DesktopDriveMappings
            .Where(item => item.ProfileId == _profileId)
            .ToArray();
        if (mappings.Length == 0)
        {
            CloudDriveList.Children.Add(new TextBlock
            {
                Text = localization.Get("CloudDriveEmpty"),
                TextWrapping = TextWrapping.Wrap,
            });
            return;
        }
        foreach (var mapping in mappings)
        {
            var scope = mapping.Scope.Kind == DesktopDriveScopeKind.AllShares
                ? localization.Get("CloudDriveEntireNas")
                : mapping.Scope.FolderPath ?? "/";
            var title = new TextBlock
            {
                Text = mapping.DisplayName,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            };
            var detail = new TextBlock
            {
                Text = $"{scope} · {localization.Get("CloudDriveOnDemand")}\n" +
                    CacheText(mapping) +
                    "\n" + CacheDiskDescription(mapping) +
                    "\n" + localization.Get(
                        $"CloudDriveState{_app.DesktopDriveRuntime(mapping).State}") +
                    ProgressText(mapping),
                TextWrapping = TextWrapping.Wrap,
            };
            var open = MappingButton(
                localization.Get("CloudDriveOpen"),
                mapping,
                OpenMapping_Click);
            var clear = MappingButton(
                localization.Get("CloudDriveClearCache"),
                mapping,
                ClearCache_Click);
            var limit = new ComboBox
            {
                Header = localization.Get("CloudDriveCacheLimit"),
                ItemsSource = CacheLimitChoices(),
                DisplayMemberPath = nameof(CacheLimitChoice.DisplayName),
                Tag = mapping,
                MinWidth = 150,
            };
            limit.SelectedItem = ((IEnumerable<CacheLimitChoice>)limit.ItemsSource)
                .FirstOrDefault(item =>
                    item.Bytes == mapping.CachePolicy.TemporaryLimitBytes);
            limit.SelectionChanged += CacheLimit_SelectionChanged;
            var launchAtLogin = new ToggleSwitch
            {
                Header = localization.Get("CloudDriveLaunchAtLogin"),
                IsOn = mapping.LaunchAtLogin,
                Tag = mapping,
            };
            launchAtLogin.Toggled += LaunchAtLogin_Toggled;
            var progress = _app.DesktopDriveProgress(mapping);
            var keep = MappingButton(
                progress?.Phase == DesktopDriveOfflinePhase.Completed
                    ? localization.Get("CloudDriveReleaseOffline")
                    : progress?.Phase is DesktopDriveOfflinePhase.Planning
                        or DesktopDriveOfflinePhase.CheckingSpace
                        or DesktopDriveOfflinePhase.Preparing
                        or DesktopDriveOfflinePhase.Downloading
                        ? localization.Get("CloudDriveCancel")
                        : localization.Get("CloudDriveKeepOffline"),
                mapping,
                progress?.Phase == DesktopDriveOfflinePhase.Completed
                    ? ReleaseOffline_Click
                    : progress?.Phase is DesktopDriveOfflinePhase.Planning
                        or DesktopDriveOfflinePhase.CheckingSpace
                        or DesktopDriveOfflinePhase.Preparing
                        or DesktopDriveOfflinePhase.Downloading
                        ? CancelOffline_Click
                        : KeepOffline_Click);
            var needsResume = _app.IsDesktopDrivePaused(mapping) || _app.DesktopDriveRuntime(mapping).State is
                DesktopDriveMappingState.Offline or DesktopDriveMappingState.AuthenticationRequired or
                DesktopDriveMappingState.CacheVolumeUnavailable or DesktopDriveMappingState.Failed;
            var pause = MappingButton(
                localization.Get(
                    needsResume
                        ? "CloudDriveResume"
                        : "CloudDrivePause"),
                mapping,
                needsResume
                    ? ResumeMapping_Click
                    : PauseMapping_Click);
            var remove = MappingButton(
                localization.Get("CloudDriveRemove"),
                mapping,
                RemoveMapping_Click);
            var primaryActions = new StackPanel
            {
                Orientation = Orientation.Vertical,
                Spacing = 8,
            };
            primaryActions.Children.Add(open);
            primaryActions.Children.Add(keep);
            primaryActions.Children.Add(pause);
            var refresh = MappingButton(localization.Get("CloudDriveRefresh"), mapping, RefreshMapping_Click);
            refresh.IsEnabled = !needsResume;
            primaryActions.Children.Add(refresh);
            primaryActions.Children.Add(MappingButton(localization.Get("CloudDriveWritebackTitle"), mapping, WritebackSettings_Click));
            primaryActions.Children.Add(clear);
            primaryActions.Children.Add(remove);
            var cacheOptions = new StackPanel
            {
                Orientation = Orientation.Vertical,
                Spacing = 12,
            };
            cacheOptions.Children.Add(limit);
            cacheOptions.Children.Add(launchAtLogin);
            var actions = new StackPanel { Spacing = 8 };
            actions.Children.Add(primaryActions);
            actions.Children.Add(cacheOptions);
            var content = new StackPanel { Spacing = 6 };
            content.Children.Add(title);
            content.Children.Add(detail);
            content.Children.Add(actions);
            CloudDriveList.Children.Add(new Border
            {
                Padding = new Thickness(12),
                Style = (Style)Resources["CloudDriveMappingCard"],
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8),
                Child = content,
            });
        }
    }

    private async void CacheLimit_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (!CanManage) return;
        if (sender is not ComboBox
            {
                Tag: DesktopDriveMapping mapping,
                SelectedItem: CacheLimitChoice choice,
            } || choice.Bytes == mapping.CachePolicy.TemporaryLimitBytes)
        {
            return;
        }
        try
        {
            await _app.SetDesktopDriveCacheLimitAsync(mapping, choice.Bytes);
            ShowMessage("CloudDriveCacheLimitUpdated", InfoBarSeverity.Success);
            RenderMappings();
        }
        catch
        {
            ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error);
        }
    }

    private async void LaunchAtLogin_Toggled(
        object sender,
        RoutedEventArgs e)
    {
        if (!CanManage) return;
        if (sender is not ToggleSwitch
            {
                Tag: DesktopDriveMapping mapping,
            } toggle || toggle.IsOn == mapping.LaunchAtLogin)
        {
            return;
        }
        toggle.IsEnabled = false;
        try
        {
            await _app.SetDesktopDriveLaunchAtLoginAsync(
                mapping,
                toggle.IsOn);
            ShowMessage(
                toggle.IsOn
                    ? "CloudDriveLaunchAtLoginEnabled"
                    : "CloudDriveLaunchAtLoginDisabled",
                InfoBarSeverity.Success);
            RenderMappings();
        }
        catch
        {
            toggle.IsOn = mapping.LaunchAtLogin;
            toggle.IsEnabled = true;
            ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error);
        }
    }

    private async void ChooseCacheDiskButton_Click(
        object sender,
        RoutedEventArgs e)
    {
        if (!IsCurrent || _busy) return;
        var picker = new FolderPicker
        {
            SuggestedStartLocation = PickerLocationId.ComputerFolder,
        };
        picker.FileTypeFilter.Add("*");
        if ((Application.Current as App)?.MainWindow is not { } window)
        {
            return;
        }
        InitializeWithWindow.Initialize(
            picker,
            WindowNative.GetWindowHandle(window));
        var folder = await picker.PickSingleFolderAsync();
        if (folder is null || !IsCurrent)
        {
            return;
        }
        try
        {
            _cacheLocation = _app.DesktopDriveCacheLocationForPath(folder.Path);
            var root = Path.GetPathRoot(folder.Path) ?? folder.Path;
            CacheDiskText.Text = LocalizationService.Current.Format(
                "CloudDriveCacheDiskSelected",
                root);
            UseDefaultCacheDiskButton.Visibility = Visibility.Visible;
        }
        catch (InvalidOperationException error)
        {
            ShowMessage(error.Message, InfoBarSeverity.Warning);
        }
    }

    private void UseDefaultCacheDiskButton_Click(
        object sender,
        RoutedEventArgs e)
    {
        _cacheLocation = DesktopDriveCacheLocation.SystemDefault;
        CacheDiskText.Text =
            LocalizationService.Current.Get("CloudDriveCacheDiskDefault");
        UseDefaultCacheDiskButton.Visibility = Visibility.Collapsed;
    }

    private static IReadOnlyList<CacheLimitChoice> CacheLimitChoices()
    {
        var localization = LocalizationService.Current;
        return new long[] { 5, 10, 20, 50 }
            .Select(value => new CacheLimitChoice(
                value * 1024 * 1024 * 1024,
                localization.Format("CloudDriveCacheLimitGiB", value)))
            .ToArray();
    }

    private static Button MappingButton(
        string text,
        DesktopDriveMapping mapping,
        RoutedEventHandler handler)
    {
        var button = new Button { Content = text, Tag = mapping, MinHeight = 44 };
        button.Click += handler;
        return button;
    }

    private void OpenMapping_Click(object sender, RoutedEventArgs e)
    {
        if (!CanManage) return;
        if ((sender as Button)?.Tag is DesktopDriveMapping mapping)
        {
            try
            {
                _app.RevealDesktopDrive(mapping);
            }
            catch
            {
                ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error);
            }
        }
    }

    private async void ClearCache_Click(object sender, RoutedEventArgs e)
    {
        if (!CanManage) return;
        if ((sender as Button)?.Tag is DesktopDriveMapping mapping)
        {
            try
            {
                await _app.ClearDesktopDriveCacheAsync(mapping);
                ShowMessage("CloudDriveCacheCleared", InfoBarSeverity.Success);
                RenderMappings();
            }
            catch
            {
                ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error);
            }
        }
    }

    private async void KeepOffline_Click(object sender, RoutedEventArgs e)
    {
        if (!CanManage) return;
        if ((sender as Button)?.Tag is not DesktopDriveMapping mapping)
        {
            return;
        }
        try
        {
            await _app.KeepDesktopDriveOfflineAsync(mapping);
            ShowMessage("CloudDriveOfflineReady", InfoBarSeverity.Success);
        }
        catch (DesktopCloudDriveService.InsufficientLocalSpaceException error)
        {
            var localization = LocalizationService.Current;
            CloudDriveMessage.Message = localization.Format(
                "CloudDriveInsufficientSpace",
                FormatBytes(error.RequiredBytes),
                error.VolumeName ?? localization.Get("CloudDriveTitle"),
                FormatBytes(error.AvailableBytes),
                FormatBytes(error.ShortageBytes));
            CloudDriveMessage.Severity = InfoBarSeverity.Warning;
            CloudDriveMessage.IsOpen = true;
        }
        catch (OperationCanceledException)
        {
            ShowMessage("CloudDriveOfflineCancelled", InfoBarSeverity.Informational);
        }
        catch (InvalidOperationException error)
        {
            ShowMessage(error.Message, InfoBarSeverity.Warning);
        }
        catch
        {
            ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error);
        }
        finally
        {
            RenderMappings();
        }
    }

    private void CancelOffline_Click(object sender, RoutedEventArgs e)
    {
        if (!IsCurrent) return;
        if ((sender as Button)?.Tag is DesktopDriveMapping mapping)
        {
            _app.CancelDesktopDriveTask(mapping);
        }
    }

    private async void ReleaseOffline_Click(object sender, RoutedEventArgs e)
    {
        if (!CanManage) return;
        if ((sender as Button)?.Tag is not DesktopDriveMapping mapping)
        {
            return;
        }
        try
        {
            await _app.ReleaseDesktopDriveOfflineAsync(mapping);
            ShowMessage("CloudDriveOfflineReleased", InfoBarSeverity.Success);
            RenderMappings();
        }
        catch
        {
            ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error);
        }
    }

    private async void PauseMapping_Click(object sender, RoutedEventArgs e)
    {
        if (!CanManage) return;
        if ((sender as Button)?.Tag is not DesktopDriveMapping mapping)
        {
            return;
        }
        try
        {
            await _app.PauseDesktopDriveAsync(mapping);
            ShowMessage("CloudDrivePaused", InfoBarSeverity.Informational);
            RenderMappings();
        }
        catch
        {
            ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error);
        }
    }

    private async void ResumeMapping_Click(object sender, RoutedEventArgs e)
    {
        if (!CanManage) return;
        if ((sender as Button)?.Tag is not DesktopDriveMapping mapping)
        {
            return;
        }
        try
        {
            await _app.ResumeDesktopDriveAsync(mapping);
            ShowMessage("CloudDriveResumed", InfoBarSeverity.Success);
            RenderMappings();
        }
        catch
        {
            ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error);
        }
    }

    private async void RefreshMapping_Click(object sender, RoutedEventArgs e)
    {
        if (!CanManage || _refreshCancellation is not null || (sender as Button)?.Tag is not DesktopDriveMapping mapping) return;
        using var cancellation = new CancellationTokenSource();
        _refreshCancellation = cancellation;
        SetBusy(true); CancelRefreshButton.Visibility = Visibility.Visible;
        ShowMessage("CloudDriveRefreshing", InfoBarSeverity.Informational);
        CloudDriveMessage.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
        try
        {
            var result = await _refreshFiles(mapping, cancellation.Token);
            if (!IsCurrent) return;
            var localization = LocalizationService.Current;
            CloudDriveMessage.Message = result.Removed + result.Retained > 0 ?
                localization.Format("CloudDriveRefreshReconciled", result.Refreshed, result.Removed, result.Retained, result.Failed) :
                result.Refreshed + result.Failed == 0 ? localization.Get("CloudDriveRefreshEmpty") :
                result.Failed == 0 ? localization.Format("CloudDriveRefreshDone", result.Refreshed) :
                localization.Format("CloudDriveRefreshPartial", result.Refreshed, result.Failed);
            CloudDriveMessage.Severity = result.Failed + result.Retained == 0 ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
            CloudDriveMessage.IsOpen = true;
        }
        catch (OperationCanceledException) { if (IsCurrent) ShowMessage("CloudDriveRefreshCancelled", InfoBarSeverity.Informational); }
        catch { if (IsCurrent) ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error); }
        finally
        {
            _refreshCancellation = null; CancelRefreshButton.Visibility = Visibility.Collapsed;
            SetBusy(false); if (IsCurrent) RenderMappings();
        }
    }

    private void CancelRefresh_Click(object sender, RoutedEventArgs e) => _refreshCancellation?.Cancel();

    private async void WritebackSettings_Click(object sender, RoutedEventArgs e)
    {
        if (!CanManage || _confirmation is not null || (sender as Button)?.Tag is not DesktopDriveMapping mapping) return;
        var dialog = new CloudDriveWritebackDialog(
            token => _app.ReadDesktopDriveWritebackAsync(mapping, token),
            (enabled, confirmed, token) => _app.ConfigureDesktopDriveWritebackAsync(mapping, enabled, confirmed, token),
            (change, action, confirmed, token) => _app.RecoverDesktopDriveWritebackAsync(mapping, change, action, confirmed, token),
            async (change, token) =>
            {
                var picker = new Features.Transfers.WindowsTransferSavePicker(() => (Application.Current as App)?.MainWindow);
                var destination = await picker.PickSavePathAsync(Path.GetFileName(change.RemotePath));
                if (destination is null || !IsCurrent) return false;
                token.ThrowIfCancellationRequested();
                await _app.ExportDesktopDriveWritebackAsync(mapping, change.Id, destination, token);
                return true;
            }, () => IsCurrent, CloudDriveWriteScope.CanEnable(mapping),
            (operation, action, confirmed, token) => _app.RecoverDesktopDriveRelocationAsync(mapping, operation, action, confirmed, token),
            (enabled, confirmed, token) => _app.ConfigureDesktopDriveDeletionAsync(mapping, enabled, confirmed, token),
            (operation, action, confirmed, token) => _app.RecoverDesktopDriveDeletionAsync(mapping, operation, action, confirmed, token))
            { XamlRoot = XamlRoot, RequestedTheme = ActualTheme };
        _confirmation = dialog;
        try { await dialog.ShowAsync(); }
        finally { _confirmation = null; if (IsCurrent) RenderMappings(); }
    }

    private async void RemoveMapping_Click(object sender, RoutedEventArgs e)
    {
        if (!CanManage || _confirmation is not null) return;
        if ((sender as Button)?.Tag is not DesktopDriveMapping mapping)
        {
            return;
        }
        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = localization.Get("CloudDriveRemoveTitle"),
            Content = localization.Get("CloudDriveRemoveMessage"),
            PrimaryButtonText = localization.Get("CloudDriveRemove"),
            CloseButtonText = localization.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        _confirmation = dialog;
        try
        {
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || !CanManage) return;
        }
        finally { _confirmation = null; }
        SetBusy(true);
        try
        {
            await _app.RemoveDesktopDriveAsync(mapping);
            ShowMessage("CloudDriveRemoved", InfoBarSeverity.Success);
            RenderMappings();
        }
        catch (InvalidOperationException error) when (error.Message == "CloudDriveWritebackRemoveBlocked")
        {
            ShowMessage("CloudDriveWritebackRemoveBlocked", InfoBarSeverity.Warning);
        }
        catch
        {
            ShowMessage("CloudDriveGenericError", InfoBarSeverity.Error);
        }
        finally
        {
            SetBusy(false);
        }
    }

    private void ShowMessage(string key, InfoBarSeverity severity)
    {
        if (!IsCurrent) return;
        CloudDriveMessage.Message = LocalizationService.Current.Get(key);
        CloudDriveMessage.Severity = severity;
        CloudDriveMessage.IsOpen = true;
    }

    private void DesktopDriveProgressChanged(object? sender, EventArgs e)
    {
        DispatcherQueue.TryEnqueue(() => { if (IsCurrent) RenderMappings(); });
    }

    private string ProgressText(DesktopDriveMapping mapping)
    {
        var localization = LocalizationService.Current;
        var progress = _app.DesktopDriveProgress(mapping);
        var planning = _app.DesktopDrivePlanning(mapping);
        return progress?.Phase switch
        {
            DesktopDriveOfflinePhase.Planning when planning is not null =>
                "\n" + localization.Format(
                    "CloudDrivePlanning",
                    planning.FileCount,
                    FormatBytes(planning.DiscoveredBytes)),
            DesktopDriveOfflinePhase.CheckingSpace =>
                "\n" + localization.Get("CloudDriveCheckingSpace"),
            DesktopDriveOfflinePhase.Preparing =>
                "\n" + localization.Get("CloudDrivePreparing"),
            DesktopDriveOfflinePhase.Downloading =>
                "\n" + localization.Format(
                    "CloudDriveDownloading",
                    progress.CompletedFiles,
                    progress.TotalFiles,
                    FormatBytes(progress.CompletedBytes)),
            DesktopDriveOfflinePhase.Completed =>
                "\n" + localization.Get("CloudDriveOfflineReady"),
            DesktopDriveOfflinePhase.Cancelled =>
                "\n" + localization.Get("CloudDriveOfflineCancelled"),
            DesktopDriveOfflinePhase.Failed =>
                "\n" + localization.Get("CloudDriveGenericError"),
            _ => string.Empty,
        };
    }

    private string CacheText(DesktopDriveMapping mapping)
    {
        var localization = LocalizationService.Current;
        var summary = _app.DesktopDriveCacheSummary(mapping);
        return localization.Format(
            "CloudDriveCacheBreakdown",
            FormatBytes(summary.TemporaryBytes),
            FormatBytes(summary.KeptOfflineBytes),
            FormatBytes(mapping.CachePolicy.TemporaryLimitBytes));
    }

    private string CacheDiskDescription(DesktopDriveMapping mapping)
    {
        try
        {
            return LocalizationService.Current.Format(
                "CloudDriveCacheDiskValue",
                _app.DesktopDriveCacheVolumeName(mapping));
        }
        catch
        {
            return LocalizationService.Current.Get(
                "CloudDriveCacheDiskUnavailable");
        }
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        AddNasButton.IsEnabled = !busy && IsCurrent && DesktopCloudDriveCapabilityGate.IsRegistrationEnabled;
        AddFolderButton.IsEnabled = AddNasButton.IsEnabled;
        MappingsHost.IsEnabled = AddNasButton.IsEnabled;
        MappingNameTextBox.IsEnabled = !busy;
        FolderPathTextBox.IsEnabled = !busy;
        CacheLimitSelector.IsEnabled = !busy;
        LaunchAtLoginChoice.IsEnabled = !busy;
        ChooseCacheDiskButton.IsEnabled = !busy;
        CloudDriveProgress.IsActive = busy;
        CloudDriveProgress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
    }

    private static string FormatBytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        var value = Math.Max(bytes, 0);
        var unit = 0;
        var display = (double)value;
        while (display >= 1024 && unit < units.Length - 1)
        {
            display /= 1024;
            unit++;
        }
        return $"{display:0.#} {units[unit]}";
    }
}
