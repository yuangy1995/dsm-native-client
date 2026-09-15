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

public sealed partial class DesktopDriveSettingsPage : Page, IDisposable
{
    private readonly AppViewModel _app;
    private bool _disposed;
    private bool _subscribed;
    private bool _busy;
    private bool _refreshPending;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _refreshTimer;
    private DesktopDriveCacheLocation _cacheLocation =
        DesktopDriveCacheLocation.SystemDefault;
    private sealed record CacheLimitChoice(long Bytes, string DisplayName);

    public DesktopDriveSettingsPage(AppViewModel app)
    {
        _app = app;
        InitializeComponent();
        var localization = LocalizationService.Current;
        TitleText.Text = localization.Get("CloudDriveTitle");
        CloudDriveTitle.Text = localization.Get("CloudDriveTitle");
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
        CacheDiskText.Text = localization.Get("CloudDriveCacheDiskDefault");
        ChooseCacheDiskButton.Content = localization.Get("CloudDriveChooseCacheDisk");
        UseDefaultCacheDiskButton.Content =
            localization.Get("CloudDriveUseDefaultCacheDisk");
        // 下载进度只在页面可见时以 250ms 合并更新，不逐回调重建整个列表。
        _refreshTimer = DispatcherQueue.CreateTimer();
        _refreshTimer.Interval = TimeSpan.FromMilliseconds(250);
        _refreshTimer.IsRepeating = false;
        _refreshTimer.Tick += RefreshTimer_Tick;
        Loaded += PageLoaded;
        Unloaded += PageUnloaded;
        RenderMappings();
    }

    private void PageLoaded(object sender, RoutedEventArgs args)
    {
        if (_disposed || _subscribed) return;
        _subscribed = true;
        _app.DesktopDriveProgressChanged += DesktopDriveProgressChanged;
        RenderMappings();
    }

    private void PageUnloaded(object sender, RoutedEventArgs args)
    {
        _app.DesktopDriveProgressChanged -= DesktopDriveProgressChanged;
        _subscribed = false;
        _refreshTimer.Stop();
        _refreshPending = false;
    }

    private void RefreshTimer_Tick(Microsoft.UI.Dispatching.DispatcherQueueTimer sender, object args)
    {
        _refreshPending = false;
        if (!_disposed && IsLoaded) RenderMappings();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        PageUnloaded(this, new RoutedEventArgs());
        _refreshTimer.Tick -= RefreshTimer_Tick;
        Loaded -= PageLoaded;
        Unloaded -= PageUnloaded;
        CloudDriveList.Children.Clear();
    }

    private async void AddNasButton_Click(object sender, RoutedEventArgs e) =>
        await AddMappingAsync(null);

    private async void AddFolderButton_Click(object sender, RoutedEventArgs e) =>
        await AddMappingAsync(FolderPathTextBox.Text);

    private async Task AddMappingAsync(string? folderPath)
    {
        if (_disposed || _busy) return;
        SetBusy(true);
        try
        {
            var limit = (CacheLimitSelector.SelectedItem as CacheLimitChoice)?.Bytes
                ?? DesktopDriveCachePolicy.DefaultTemporaryLimitBytes;
            await _app.AddDesktopDriveAsync(
                MappingNameTextBox.Text,
                folderPath,
                new DesktopDriveCachePolicy(_cacheLocation, limit));
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
        if (_disposed) return;
        var localization = LocalizationService.Current;
        CloudDriveList.Children.Clear();
        var mappings = _app.DesktopDriveMappings
            .Where(item => item.ProfileId == _app.ActiveProfile?.Id)
            .ToArray();
        if (mappings.Length == 0)
        {
            CloudDriveList.Children.Add(new TextBlock
            {
                Text = localization.Get("CloudDriveEmpty"),
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[
                    "TextFillColorSecondaryBrush"],
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
                Text = $"{scope} · {localization.Get("CloudDriveReadOnlyOnline")}\n" +
                    CacheText(mapping) +
                    "\n" + CacheDiskDescription(mapping) +
                    "\n" + localization.Get(
                        $"CloudDriveState{_app.DesktopDriveRuntime(mapping).State}") +
                    ProgressText(mapping),
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[
                    "TextFillColorSecondaryBrush"],
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
            var pause = MappingButton(
                localization.Get(
                    _app.IsDesktopDrivePaused(mapping)
                        ? "CloudDriveResume"
                        : "CloudDrivePause"),
                mapping,
                _app.IsDesktopDrivePaused(mapping)
                    ? ResumeMapping_Click
                    : PauseMapping_Click);
            var remove = MappingButton(
                localization.Get("CloudDriveRemove"),
                mapping,
                RemoveMapping_Click);
            var primaryActions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
            };
            primaryActions.Children.Add(open);
            primaryActions.Children.Add(keep);
            primaryActions.Children.Add(pause);
            primaryActions.Children.Add(clear);
            primaryActions.Children.Add(remove);
            var cacheOptions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
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
                BorderBrush = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[
                    "CardStrokeColorDefaultBrush"],
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
        if (folder is null)
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
        var button = new Button { Content = text, Tag = mapping };
        button.Click += handler;
        return button;
    }

    private void OpenMapping_Click(object sender, RoutedEventArgs e)
    {
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
        if ((sender as Button)?.Tag is DesktopDriveMapping mapping)
        {
            _app.CancelDesktopDriveTask(mapping);
        }
    }

    private async void ReleaseOffline_Click(object sender, RoutedEventArgs e)
    {
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

    private async void RemoveMapping_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not DesktopDriveMapping mapping)
        {
            return;
        }
        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = localization.Get("CloudDriveRemoveTitle"),
            Content = localization.Get("CloudDriveRemoveMessage"),
            PrimaryButtonText = localization.Get("CloudDriveRemove"),
            CloseButtonText = localization.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }
        SetBusy(true);
        try
        {
            await _app.RemoveDesktopDriveAsync(mapping);
            ShowMessage("CloudDriveRemoved", InfoBarSeverity.Success);
            RenderMappings();
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
        if (_disposed) return;
        CloudDriveMessage.Message = LocalizationService.Current.Get(key);
        CloudDriveMessage.Severity = severity;
        CloudDriveMessage.IsOpen = true;
    }

    private void DesktopDriveProgressChanged(object? sender, EventArgs e)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed || !IsLoaded || _refreshPending) return;
            _refreshPending = true;
            _refreshTimer.Start();
        });
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
        if (_disposed) return;
        AddNasButton.IsEnabled = !busy;
        AddFolderButton.IsEnabled = !busy;
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
