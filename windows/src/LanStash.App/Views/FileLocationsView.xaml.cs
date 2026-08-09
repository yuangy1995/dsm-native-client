using LanStash.App.Features.Files.Locations;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FileLocationsView : UserControl, IDisposable
{
    private FileLocationsViewModel? _viewModel;
    private Func<string, FileLocationSource, CancellationToken, Task<bool>>? _openLocation;
    private Func<CancellationToken, Task>? _refresh;
    private CancellationTokenSource? _openCancellation;
    private CancellationTokenSource? _refreshCancellation;
    private bool _disposed;

    public event EventHandler? LocationOpened;

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
