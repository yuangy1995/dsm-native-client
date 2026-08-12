using LanStash.App.Features.Files.Locations;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;

namespace LanStash.App.Views;

public sealed class FileLocationsBooleanToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language) =>
        value is true ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}

public sealed partial class FileLocationsView : UserControl, IDisposable
{
    private FileLocationsViewModel? _viewModel;
    private Func<string, FileLocationSource, CancellationToken, Task<bool>>? _openLocation;
    private Func<CancellationToken, Task>? _refresh;
    private CancellationTokenSource? _openCancellation;
    private CancellationTokenSource? _refreshCancellation;
    private bool _disposed;

    public event EventHandler? LocationOpened;
    public event EventHandler? RemoteMountNeedsRefresh;

    public FileLocationsView()
    {
        InitializeComponent();
    }

    internal void Attach(
        FileLocationsViewModel viewModel,
        Func<string, FileLocationSource, CancellationToken, Task<bool>> openLocation,
        Func<CancellationToken, Task> refresh)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        Detach();
        _viewModel = viewModel;
        DataContext = viewModel;
        _openLocation = openLocation;
        _refresh = refresh;
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        Render();
    }

    internal async Task LoadAsync()
    {
        if (_viewModel is null || !_viewModel.IsActive)
        {
            return;
        }
        await RefreshAsync();
    }

    internal void CancelOpening()
    {
        _openCancellation?.Cancel();
        _openCancellation?.Dispose();
        _openCancellation = null;
        OpenErrorBar.IsOpen = false;
        SetLocationButtonsEnabled(true);
    }

    internal void FocusFirstLocation() => SharesButton.Focus(FocusState.Programmatic);

    private void ViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(Render);

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await RefreshAsync();

    private async Task RefreshAsync()
    {
        if (_refresh is null || _refreshCancellation is not null)
        {
            return;
        }
        OpenErrorBar.IsOpen = false;
        var cancellation = new CancellationTokenSource();
        _refreshCancellation = cancellation;
        Render();
        try
        {
            await _refresh(cancellation.Token);
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException) when (
            _disposed || cancellation.IsCancellationRequested || _viewModel?.IsActive != true)
        {
        }
        catch (InvalidOperationException) when (
            _disposed || cancellation.IsCancellationRequested || _viewModel?.IsActive != true)
        {
        }
        finally
        {
            if (ReferenceEquals(_refreshCancellation, cancellation))
            {
                _refreshCancellation = null;
            }
            cancellation.Dispose();
            if (!_disposed)
            {
                Render();
            }
        }
    }

    private async void Shares_Click(object sender, RoutedEventArgs e) =>
        await OpenAsync(string.Empty, FileLocationSource.Shares);

    private async void Favorite_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is FileFavoriteLocation location)
        {
            await OpenAsync(location.Path, FileLocationSource.Favorite);
        }
    }

    private async void Recent_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is RecentFileLocation location)
        {
            await OpenAsync(location.Path, FileLocationSource.Recent);
        }
    }

    private async void Recycle_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is FileRecycleLocation location)
        {
            await OpenAsync(location.RecyclePath, FileLocationSource.Recycle);
        }
    }

    private async void Remote_Click(object sender, RoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is FileRemoteLocation location)
        {
            await OpenAsync(location.Path, FileLocationSource.Remote);
        }
    }

    private async void RemoteCreate_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel is not { } model || !model.AllowsRemoteMountManagement) return;
        var dialog = new ContentDialog
        {
            Title = LocalizationService.Current.Get("FileLocationsRemoteCreateTitle"),
            PrimaryButtonText = LocalizationService.Current.Get("FileLocationsRemoteCreateAction"),
            CloseButtonText = LocalizationService.Current.Get("ActionCancel"),
            XamlRoot = XamlRoot,
            DefaultButton = ContentDialogButton.Primary,
        };

        var panel = BuildRemoteMountForm(dialog, out var serverBox, out var remotePathBox,
            out var mountPointBox, out var usernameBox, out var passwordBox,
            out var domainBox, out var readOnlyToggle, out var protocolCombo);
        dialog.Content = panel;

        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary) return;

        var draft = new RemoteMountDraft(
            serverBox.Text, remotePathBox.Text, mountPointBox.Text,
            string.IsNullOrWhiteSpace(usernameBox.Text) ? null : usernameBox.Text,
            string.IsNullOrWhiteSpace(passwordBox.Password) ? null : passwordBox.Password,
            string.IsNullOrWhiteSpace(domainBox.Text) ? null : domainBox.Text,
            readOnlyToggle.IsOn,
            (FileRemoteProtocol)(protocolCombo.SelectedIndex >= 0 ? protocolCombo.SelectedIndex : 0));

        if (!draft.IsValidForSubmission)
        {
            await ShowRemoteMountErrorAsync("FileLocationsRemoteInvalidDraft");
            return;
        }

        try
        {
            var mutation = await model.CreateRemoteMountAsync(draft);
            if (mutation.Status != MutationResultStatus.ConfirmedSuccess)
            {
                await ShowRemoteMountErrorAsync("FileLocationsRemoteOperationFailed");
            }
            else
            {
                RemoteMountNeedsRefresh?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (OperationCanceledException) { }
    }

    private async void RemoteEdit_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel is not { } model || !model.AllowsRemoteMountManagement) return;
        if ((sender as FrameworkElement)?.DataContext is not FileRemoteLocation location) return;

        var dialog = new ContentDialog
        {
            Title = LocalizationService.Current.Get("FileLocationsRemoteEditTitle"),
            PrimaryButtonText = LocalizationService.Current.Get("FileLocationsRemoteEditAction"),
            CloseButtonText = LocalizationService.Current.Get("ActionCancel"),
            XamlRoot = XamlRoot,
            DefaultButton = ContentDialogButton.Primary,
        };

        var panel = BuildRemoteMountForm(dialog, out var serverBox, out var remotePathBox,
            out var mountPointBox, out var usernameBox, out var passwordBox,
            out var domainBox, out var readOnlyToggle, out var protocolCombo);

        // 使用当前位置数据预填表单。
        mountPointBox.Text = location.Path;
        mountPointBox.IsEnabled = false; // mount point is immutable for edits
        readOnlyToggle.IsOn = location.IsReadOnly;
        protocolCombo.SelectedIndex = (int)location.Protocol;

        dialog.Content = panel;

        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary) return;

        var draft = new RemoteMountDraft(
            serverBox.Text, remotePathBox.Text, location.Path,
            string.IsNullOrWhiteSpace(usernameBox.Text) ? null : usernameBox.Text,
            string.IsNullOrWhiteSpace(passwordBox.Password) ? null : passwordBox.Password,
            string.IsNullOrWhiteSpace(domainBox.Text) ? null : domainBox.Text,
            readOnlyToggle.IsOn,
            (FileRemoteProtocol)(protocolCombo.SelectedIndex >= 0 ? protocolCombo.SelectedIndex : 0),
            existingMountPoint: location.Path);

        if (!draft.IsValidForSubmission)
        {
            await ShowRemoteMountErrorAsync("FileLocationsRemoteInvalidDraft");
            return;
        }

        try
        {
            var mutation = await model.UpdateRemoteMountAsync(draft);
            if (mutation.Status != MutationResultStatus.ConfirmedSuccess)
            {
                await ShowRemoteMountErrorAsync("FileLocationsRemoteOperationFailed");
            }
            else
            {
                RemoteMountNeedsRefresh?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (OperationCanceledException) { }
    }

    private async void RemoteDelete_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel is not { } model || !model.AllowsRemoteMountManagement) return;
        if ((sender as FrameworkElement)?.DataContext is not FileRemoteLocation location) return;

        var dialog = new ContentDialog
        {
            Title = LocalizationService.Current.Get("FileLocationsRemoteDeleteTitle"),
            Content = string.Format(
                LocalizationService.Current.Get("FileLocationsRemoteDeleteMessage"),
                location.Path),
            PrimaryButtonText = LocalizationService.Current.Get("ActionDeleteText"),
            CloseButtonText = LocalizationService.Current.Get("ActionCancel"),
            XamlRoot = XamlRoot,
            DefaultButton = ContentDialogButton.Close,
        };

        var result = await dialog.ShowAsync();
        if (result != ContentDialogResult.Primary) return;

        try
        {
            var mutation = await model.DeleteRemoteMountAsync(location.Path);
            if (mutation.Status != MutationResultStatus.ConfirmedSuccess)
            {
                await ShowRemoteMountErrorAsync("FileLocationsRemoteOperationFailed");
            }
            else
            {
                RemoteMountNeedsRefresh?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (OperationCanceledException) { }
    }

    private static StackPanel BuildRemoteMountForm(
        ContentDialog dialog,
        out TextBox serverBox,
        out TextBox remotePathBox,
        out TextBox mountPointBox,
        out TextBox usernameBox,
        out PasswordBox passwordBox,
        out TextBox domainBox,
        out ToggleSwitch readOnlyToggle,
        out ComboBox protocolCombo)
    {
        var panel = new StackPanel { Spacing = 12 };

        serverBox = new TextBox
        {
            Header = LocalizationService.Current.Get("FileLocationsRemoteFieldServer"),
            PlaceholderText = "server.local",
        };
        panel.Children.Add(serverBox);

        remotePathBox = new TextBox
        {
            Header = LocalizationService.Current.Get("FileLocationsRemoteFieldRemotePath"),
            PlaceholderText = "/volume1/share",
        };
        panel.Children.Add(remotePathBox);

        mountPointBox = new TextBox
        {
            Header = LocalizationService.Current.Get("FileLocationsRemoteFieldMountPoint"),
            PlaceholderText = "/remote-mount",
        };
        panel.Children.Add(mountPointBox);

        usernameBox = new TextBox
        {
            Header = LocalizationService.Current.Get("FileLocationsRemoteFieldUsername"),
            PlaceholderText = LocalizationService.Current.Get("FileLocationsRemoteFieldUsernameOptional"),
        };
        panel.Children.Add(usernameBox);

        passwordBox = new PasswordBox
        {
            Header = LocalizationService.Current.Get("FileLocationsRemoteFieldPassword"),
            PlaceholderText = LocalizationService.Current.Get("FileLocationsRemoteFieldPasswordOptional"),
        };
        panel.Children.Add(passwordBox);

        domainBox = new TextBox
        {
            Header = LocalizationService.Current.Get("FileLocationsRemoteFieldDomain"),
            PlaceholderText = LocalizationService.Current.Get("FileLocationsRemoteFieldDomainOptional"),
        };
        panel.Children.Add(domainBox);

        readOnlyToggle = new ToggleSwitch
        {
            Header = LocalizationService.Current.Get("FileLocationsRemoteFieldReadOnly"),
            IsOn = false,
        };
        panel.Children.Add(readOnlyToggle);

        protocolCombo = new ComboBox
        {
            Header = LocalizationService.Current.Get("FileLocationsRemoteFieldProtocol"),
            Items =
            {
                LocalizationService.Current.Get("FileLocationsRemoteProtocolCifs"),
                LocalizationService.Current.Get("FileLocationsRemoteProtocolNfs"),
                LocalizationService.Current.Get("FileLocationsRemoteProtocolIso"),
            },
            SelectedIndex = 0,
        };
        panel.Children.Add(protocolCombo);

        return panel;
    }

    private async Task ShowRemoteMountErrorAsync(string key)
    {
        var dialog = new ContentDialog
        {
            Title = LocalizationService.Current.Get("FileLocationsRemoteOperationFailedTitle"),
            Content = LocalizationService.Current.Get(key),
            CloseButtonText = LocalizationService.Current.Get("ActionAcknowledge"),
            XamlRoot = XamlRoot,
        };
        await dialog.ShowAsync();
    }

    private async Task OpenAsync(string path, FileLocationSource source)
    {
        if (_openLocation is null || _openCancellation is not null)
        {
            return;
        }
        OpenErrorBar.IsOpen = false;
        var cancellation = new CancellationTokenSource();
        _openCancellation = cancellation;
        SetLocationButtonsEnabled(false);
        try
        {
            var opened = await _openLocation(path, source, cancellation.Token);
            if (!opened)
            {
                OpenErrorBar.IsOpen = true;
                return;
            }
            LocationOpened?.Invoke(this, EventArgs.Empty);
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException) when (
            _disposed || cancellation.IsCancellationRequested || _viewModel?.IsActive != true)
        {
        }
        catch (InvalidOperationException) when (
            _disposed || cancellation.IsCancellationRequested || _viewModel?.IsActive != true)
        {
        }
        finally
        {
            if (ReferenceEquals(_openCancellation, cancellation))
            {
                _openCancellation = null;
                SetLocationButtonsEnabled(true);
            }
            cancellation.Dispose();
        }
    }

    private void Render()
    {
        if (_viewModel is not { } model)
        {
            FavoritesSection.Visibility = Visibility.Collapsed;
            RecycleSection.Visibility = Visibility.Collapsed;
            RemoteSection.Visibility = Visibility.Collapsed;
            return;
        }

        RefreshButton.IsEnabled = model.IsActive && _refreshCancellation is null;
        SharesButton.IsEnabled = model.IsActive && _openCancellation is null;
        FavoritesSection.Visibility = !model.IsActive || model.Availability?.Favorites == false
            ? Visibility.Collapsed : Visibility.Visible;
        RecycleSection.Visibility = !model.IsActive || model.Availability?.RecycleBins == false
            ? Visibility.Collapsed : Visibility.Visible;
        RemoteSection.Visibility = !model.IsActive || model.Availability?.RemoteLocations == false
            ? Visibility.Collapsed : Visibility.Visible;
        RecentSection.Visibility = model.IsActive ? Visibility.Visible : Visibility.Collapsed;

        RenderSection(
            model.Favorites,
            FavoritesItems,
            FavoritesLoading,
            FavoritesEmpty,
            FavoritesError,
            FavoritesProgress,
            null,
            FavoritesTruncated);
        RenderSection(
            model.Recycle,
            RecycleItems,
            RecycleLoading,
            RecycleEmpty,
            RecycleError,
            RecycleProgress,
            RecyclePartial,
            RecycleTruncated);
        RenderSection(
            model.Remote,
            RemoteItems,
            RemoteLoading,
            RemoteEmpty,
            RemoteError,
            RemoteProgress,
            RemotePartial,
            RemoteTruncated);

        RemoteCreateButton.Visibility = model.AllowsRemoteMountManagement
            ? Visibility.Visible : Visibility.Collapsed;

        RecentItems.ItemsSource = model.RecentLocations;
        RecentEmpty.Visibility = model.RecentLocations.Count == 0
            ? Visibility.Visible : Visibility.Collapsed;
        RecentItems.Visibility = model.RecentLocations.Count > 0
            ? Visibility.Visible : Visibility.Collapsed;
    }

    private static void RenderSection<T>(
        FileLocationSectionState<T> state,
        ItemsControl items,
        TextBlock loading,
        TextBlock empty,
        InfoBar error,
        ProgressRing progress,
        InfoBar? partial,
        InfoBar truncated)
    {
        items.ItemsSource = state.Items;
        items.Visibility = state.Items.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        loading.Visibility = state.State == FileLocationViewState.Loading && state.Items.Count == 0
            ? Visibility.Visible : Visibility.Collapsed;
        empty.Visibility = state.State == FileLocationViewState.Empty
            ? Visibility.Visible : Visibility.Collapsed;
        error.IsOpen = state.State == FileLocationViewState.Error && !state.IsRefreshing;
        progress.IsActive = state.IsRefreshing;
        progress.Visibility = state.IsRefreshing ? Visibility.Visible : Visibility.Collapsed;
        if (partial is not null)
        {
            partial.IsOpen = state.IsPartial;
        }
        truncated.IsOpen = state.IsTruncated;
    }

    private void SetLocationButtonsEnabled(bool enabled)
    {
        SharesButton.IsEnabled = enabled && _viewModel?.IsActive == true;
        FavoritesItems.IsEnabled = enabled;
        RecentItems.IsEnabled = enabled;
        RecycleItems.IsEnabled = enabled;
        RemoteItems.IsEnabled = enabled;
    }

    private void Detach()
    {
        CancelOpening();
        _refreshCancellation?.Cancel();
        _refreshCancellation?.Dispose();
        _refreshCancellation = null;
        if (_viewModel is not null)
        {
            _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        }
        DataContext = null;
        _viewModel = null;
        _openLocation = null;
        _refresh = null;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        Detach();
    }
}
