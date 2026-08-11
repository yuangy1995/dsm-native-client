using LanStash.App.Features.Files;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Preview;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.Photos;
using LanStash.App.Features.Photos.Import;
using LanStash.App.Features.Photos.Timeline;
using LanStash.App.Features.Settings;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace LanStash.App.Views;

public sealed partial class PhotosPage : Page, IDisposable
{
    private const int ThumbnailDecodePixels = 264;
    private const string FolderGlyph = "\uE8B7";
    private const string PhotoGlyph = "\uEB9F";
    private const string VideoGlyph = "\uE714";

    private readonly PhotoBrowserViewModel _viewModel;
    private readonly IPhotoBrowserDataSource _dataSource;
    private readonly PhotoThumbnailScheduler _thumbnails;
    private readonly IPhotoTimelineDataSource? _timelineDataSource;
    private readonly WindowsTransferPickerService _transfers;
    private readonly string _profileId;
    private readonly IDisposable _cacheRegistration;
    private readonly Dictionary<Image, CancellationTokenSource> _thumbnailRequests = [];
    private CancellationTokenSource _locationCancellation = new();
    private bool _initialized;
    private bool _isSaving;
    private bool _updatingSpaces;
    private bool _isPhotoPageActive;
    private bool _disposed;

    internal PhotosPage(
        IPhotoRepository repository,
        string profileId,
        WindowsTransferPickerService transfers,
        IFileLocationsRepository? locationsRepository = null,
        IFileRecycleRepository? recycleRepository = null,
        FileRecycleReviewBlocker? recycleReviewBlocker = null,
        IFilePreviewRepository? previewRepository = null,
        IFileCopyMoveRepository? copyMoveRepository = null,
        IFileCopyMoveFolderSource? copyMoveFolderSource = null,
        FileCopyMoveReviewBlocker? copyMoveReviewBlocker = null)
        : this(
            new RepositoryPhotoBrowserDataSource(repository),
            new PhotoBrowserViewModel(),
            new PhotoThumbnailScheduler(),
            profileId,
            transfers,
            new RepositoryPhotoTimelineDataSource(repository),
            locationsRepository ?? repository as IFileLocationsRepository,
            recycleRepository,
            recycleReviewBlocker,
            previewRepository,
            copyMoveRepository,
            copyMoveFolderSource,
            copyMoveReviewBlocker)
    {
    }

    internal PhotosPage(
        IPhotoBrowserDataSource dataSource,
        PhotoBrowserViewModel viewModel,
        PhotoThumbnailScheduler thumbnails,
        string profileId,
        WindowsTransferPickerService transfers,
        IPhotoTimelineDataSource? timelineDataSource = null,
        IFileLocationsRepository? locationsRepository = null,
        IFileRecycleRepository? recycleRepository = null,
        FileRecycleReviewBlocker? recycleReviewBlocker = null,
        IFilePreviewRepository? previewRepository = null,
        IFileCopyMoveRepository? copyMoveRepository = null,
        IFileCopyMoveFolderSource? copyMoveFolderSource = null,
        FileCopyMoveReviewBlocker? copyMoveReviewBlocker = null)
    {
        EnsureMatchingProfile(dataSource.ProfileId, profileId);
        InitializeComponent();
        _dataSource = dataSource;
        _viewModel = viewModel;
        _thumbnails = thumbnails;
        _timelineDataSource = timelineDataSource;
        _cacheRegistration = AppSettingsService.Current.Caches.Register(thumbnails);
        _profileId = profileId;
        _transfers = transfers;
        InitializePhotoRecycle(locationsRepository, recycleRepository, recycleReviewBlocker);
        InitializePhotoCopyMove(copyMoveRepository, copyMoveFolderSource, copyMoveReviewBlocker);
        InitializePhotoImport();
        InitializePhotoViewer(previewRepository);
        if (_timelineDataSource is not null)
        {
            EnsureMatchingProfile(_timelineDataSource.ProfileId, profileId);
            TimelineView.Initialize(
                _timelineDataSource,
                thumbnails,
                SaveTimelineItemAsync,
                OpenTimelineViewerAsync,
                CanMovePhoto,
                MovePhotoAsync,
                MoveMultiplePhotosAsync,
                CanMovePhotoToRecycle,
                MovePhotoToRecycleAsync,
                MoveMultiplePhotosToRecycleAsync,
                CanRestorePhotoItem,
                RestorePhotoItemAsync);
        }
        DataContext = _viewModel;
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        Loaded += PhotosPage_Loaded;
        Unloaded += PhotosPage_Unloaded;
        UpdateState();
    }

    internal static FrameworkElement CreateUnavailableState()
    {
        var localization = LocalizationService.Current;
        var title = new TextBlock
        {
            Text = localization.Get("PhotoBrowserUnavailableTitle"),
            FontSize = 20,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHeadingLevel(
            title,
            Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        return new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 440,
            Spacing = 8,
            Children =
            {
                title,
                new TextBlock
                {
                    Text = localization.Get("PhotoBrowserUnavailableMessage"),
                    TextAlignment = TextAlignment.Center,
                    TextWrapping = TextWrapping.Wrap,
                },
            },
        };
    }

    private async void PhotosPage_Loaded(object sender, RoutedEventArgs e)
    {
        _isPhotoPageActive = true;
        if (_initialized)
        {
            ActivatePhotoImportPage();
            UpdatePhotoImportState();
            await ActivatePhotoRecycleLocationsAsync();
            return;
        }

        _initialized = true;
        await RunLocationChangeAsync(() => _viewModel.ActivateAsync(_dataSource));
        ActivatePhotoImportPage();
        UpdatePhotoImportState();
        if (TimelineMode.IsChecked == true && _viewModel.SelectedSpace is { } space)
        {
            await TimelineView.ShowAsync(space);
        }
        await ActivatePhotoRecycleLocationsAsync();
    }

    private void PhotosPage_Unloaded(object sender, RoutedEventArgs e)
    {
        _isPhotoPageActive = false;
        CancelThumbnailRequests();
        _ = ClosePhotoViewerAsync();
        TimelineView.HideTimeline();
        DeactivatePhotoImport();
        ClosePhotoCopyMoveDialog();
        ClosePhotoBatchCopyMoveDialog();
        ClosePhotoRecycleDialog();
        ClosePhotoBatchRecycleDialog();
        ExitPhotoBatchSelection();
        DeactivatePhotoRecycleLocations();
    }

    private void ViewModel_PropertyChanged(
        object? sender,
        System.ComponentModel.PropertyChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(UpdateState);

    private async void SpacePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingSpaces || SpacePicker.SelectedItem is not ComboBoxItem { Tag: string spaceId })
        {
            return;
        }

        ExitPhotoBatchSelection();
        TimelineView.ExitRecycleSelection();

        if (TimelineMode.IsChecked == true)
        {
            await ClosePhotoViewerAsync();
            TimelineView.ClearSelection();
        }
        await RunLocationChangeAsync(() => _viewModel.SelectSpaceAsync(spaceId));
        if (TimelineMode.IsChecked == true && _viewModel.SelectedSpace is { } space)
        {
            await TimelineView.ShowAsync(space);
        }
    }

    private async void FoldersMode_Click(object sender, RoutedEventArgs e)
    {
        await ClosePhotoViewerAsync();
        TimelineView.ExitRecycleSelection();
        TimelineView.HideTimeline();
        TimelineView.ClearSelection();
        TimelineView.Visibility = Visibility.Collapsed;
        PathBreadcrumbs.Visibility = Visibility.Visible;
        BrowserCommandBar.Visibility = Visibility.Visible;
        BrowserContentHost.Visibility = Visibility.Visible;
        UpdatePhotoImportState();
    }

    private async void TimelineMode_Click(object sender, RoutedEventArgs e)
    {
        await ClosePhotoViewerAsync();
        ExitPhotoBatchSelection();
        _viewModel.SelectedItem = null;
        PhotoGrid.SelectedItem = null;
        CancelThumbnailRequests();
        PathBreadcrumbs.Visibility = Visibility.Collapsed;
        BrowserCommandBar.Visibility = Visibility.Collapsed;
        BrowserContentHost.Visibility = Visibility.Collapsed;
        TimelineView.Visibility = Visibility.Visible;
        if (_timelineDataSource is not null && _viewModel.SelectedSpace is { } space)
        {
            await TimelineView.ShowAsync(space);
        }
        UpdatePhotoImportState();
    }

    private async void PathBreadcrumbs_ItemClicked(
        BreadcrumbBar sender,
        BreadcrumbBarItemClickedEventArgs args)
    {
        await RunLocationChangeAsync(() =>
            _viewModel.NavigateToBreadcrumbAsync(args.Item as PhotoBrowserBreadcrumb));
    }

    private async void Back_Click(object sender, RoutedEventArgs e) =>
        await RunLocationChangeAsync(_viewModel.GoBackAsync);

    private async void Up_Click(object sender, RoutedEventArgs e) =>
        await RunLocationChangeAsync(_viewModel.GoUpAsync);

    private async void Refresh_Click(object sender, RoutedEventArgs e) =>
        await RunLocationChangeAsync(_viewModel.RefreshAsync);

    private async void LoadMore_Click(object sender, RoutedEventArgs e) =>
        await RunAsync(_viewModel.LoadMoreAsync);

    private void Photos_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        HandlePhotoBatchSelectionChanged(e);
        UpdateState();
    }

    private void PhotoGrid_ContainerContentChanging(
        ListViewBase sender,
        ContainerContentChangingEventArgs args)
    {
        if (args.ItemContainer.ContentTemplateRoot is not FrameworkElement root ||
            root.FindName("PhotoThumbnail") is not Image image)
        {
            return;
        }

        CancelThumbnailRequest(image);
        image.Source = null;
        image.Visibility = Visibility.Collapsed;
        var placeholder = root.FindName("PhotoPlaceholder") as FontIcon;
        if (placeholder is not null)
        {
            placeholder.Visibility = Visibility.Visible;
        }
        if (args.InRecycleQueue || args.Item is not PhotoBrowserEntry entry)
        {
            return;
        }

        image.Tag = entry;
        if (placeholder is not null)
        {
            placeholder.Tag = entry;
            placeholder.Glyph = entry.IsFolder ? FolderGlyph :
                entry.IsVideo ? VideoGlyph : PhotoGlyph;
        }
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            args.ItemContainer,
            LocalizationService.Current.Format(
                entry.IsFolder ? "PhotoBrowserFolderAutomationName" :
                    entry.IsVideo ? "PhotoBrowserVideoAutomationName" :
                    "PhotoBrowserImageAutomationName",
                entry.Name));
        if (entry.IsImage && image.IsLoaded)
        {
            _ = LoadThumbnailAsync(image, entry);
        }
    }

    private async void Photos_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (IsSelectingPhotoBatch || sender is not GridView grid ||
            e.OriginalSource is not DependencyObject source)
        {
            return;
        }

        var container = FindPhotoItemContainer(grid, source);
        if (container is not GridViewItem ||
            grid.ItemFromContainer(container) is not PhotoBrowserEntry entry)
        {
            return;
        }

        e.Handled = true;
        _viewModel.SelectedItem = entry;
        if (entry.IsFolder)
        {
            await RunLocationChangeAsync(() => _viewModel.OpenFolderAsync(entry));
            return;
        }
        await OpenFolderViewerAsync(entry);
    }

    private static GridViewItem? FindPhotoItemContainer(
        GridView owner,
        DependencyObject source)
    {
        for (var current = source; current is not null && current != owner;
             current = VisualTreeHelper.GetParent(current))
        {
            if (current is GridViewItem item)
            {
                return item;
            }
        }
        return null;
    }

    private async void OpenSelectedAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (IsSelectingPhotoBatch || _viewModel.SelectedItem is not { } entry)
        {
            return;
        }

        args.Handled = true;
        if (entry.IsFolder)
        {
            await RunLocationChangeAsync(() => _viewModel.OpenFolderAsync(entry));
            return;
        }
        await OpenFolderViewerAsync(entry);
    }

    private async void BackAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_viewModel.CanGoBack || _viewModel.IsLoading)
        {
            return;
        }

        args.Handled = true;
        await RunLocationChangeAsync(_viewModel.GoBackAsync);
    }

    private async void UpAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!_viewModel.CanGoUp || _viewModel.IsLoading)
        {
            return;
        }

        args.Handled = true;
        await RunLocationChangeAsync(_viewModel.GoUpAsync);
    }

    private async void SaveAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (IsSelectingPhotoBatch)
        {
            return;
        }

        if (CurrentPhotoViewerItem() is { } viewerItem)
        {
            args.Handled = true;
            await SaveTimelineItemAsync(viewerItem);
            return;
        }

        if (TimelineMode.IsChecked == true)
        {
            args.Handled = true;
            if (TimelineView.CanSaveSelected)
            {
                await TimelineView.SaveSelectedAsync();
            }
            return;
        }
        if (!CanSaveSelectedMedia())
        {
            return;
        }

        args.Handled = true;
        await SaveSelectedAsync();
    }

    private async void Open_Click(object sender, RoutedEventArgs e) =>
        await OpenSelectedPhotoAsync();

    private async void Save_Click(object sender, RoutedEventArgs e) =>
        await SaveSelectedAsync();

    private async void FilterAll_Click(object sender, RoutedEventArgs e)
    {
        await ClosePhotoViewerAsync();
        CancelThumbnailRequests();
        _viewModel.SetFilter(PhotoBrowserFilter.All);
        UpdateState();
    }

    private async void FilterImages_Click(object sender, RoutedEventArgs e)
    {
        await ClosePhotoViewerAsync();
        CancelThumbnailRequests();
        _viewModel.SetFilter(PhotoBrowserFilter.Images);
        UpdateState();
    }

    private async void ShowAll_Click(object sender, RoutedEventArgs e)
    {
        await ClosePhotoViewerAsync();
        CancelThumbnailRequests();
        _viewModel.SetFilter(PhotoBrowserFilter.All);
        UpdateState();
    }

    private async Task SaveSelectedAsync()
    {
        if (!CanSaveSelectedMedia() ||
            _viewModel.SelectedItem is not { IsMedia: true } entry)
        {
            return;
        }

        await SaveTimelineItemAsync(entry.Item);
    }

    private async Task SaveTimelineItemAsync(PhotoItem item)
    {
        var size = item.SizeBytes;
        var space = _viewModel.SelectedSpace;
        if (_isSaving || item.ProfileId != _dataSource.ProfileId ||
            space is null || !PhotoTimelineViewModel.ContainsCanonicalPath(space.RootPath, item.Path) ||
            item.Kind is not (PhotoItemKind.Image or PhotoItemKind.Video) || size is not >= 0)
        {
            return;
        }
        _isSaving = true;
        UpdateState();
        try
        {
            var fileEntry = new FileBrowserEntry(new FileItem(
                item.Path,
                item.Name,
                IsDirectory: false,
                size.Value,
                item.ModifiedAt,
                Owner: null,
                CanWrite: false,
                CanDelete: false));
            await _transfers.PickAndStartDownloadAsync(_profileId, fileEntry);
        }
        catch (ObjectDisposedException)
        {
        }
        catch
        {
            var localization = LocalizationService.Current;
            var dialog = new ContentDialog
            {
                XamlRoot = XamlRoot,
                Title = localization.Get("TransferSaveErrorTitle"),
                Content = localization.Get("TransferSaveErrorMessage"),
                CloseButtonText = localization.Get("ActionClose"),
                DefaultButton = ContentDialogButton.Close,
            };
            await dialog.ShowAsync();
        }
        finally
        {
            _isSaving = false;
            UpdateState();
        }
    }

    private bool CanSaveSelectedMedia() =>
        !_viewModel.IsLoading &&
        !_isSaving &&
        _viewModel.SelectedItem is { IsMedia: true, Item.SizeBytes: >= 0 };

    private void PhotoPlaceholder_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is FontIcon { Tag: PhotoBrowserEntry entry } icon)
        {
            icon.Glyph = entry.IsFolder ? FolderGlyph :
                entry.IsVideo ? VideoGlyph : PhotoGlyph;
            icon.Visibility = Visibility.Visible;
        }
    }

    private async void Thumbnail_Loaded(object sender, RoutedEventArgs e)
    {
        if (_disposed || sender is not Image { Tag: PhotoBrowserEntry { IsImage: true } entry } image)
        {
            if (sender is Image nonImage)
            {
                nonImage.Visibility = Visibility.Collapsed;
            }
            return;
        }

        await LoadThumbnailAsync(image, entry);
    }

    private async Task LoadThumbnailAsync(Image image, PhotoBrowserEntry entry)
    {
        CancelThumbnailRequest(image);
        var request = CancellationTokenSource.CreateLinkedTokenSource(_locationCancellation.Token);
        _thumbnailRequests[image] = request;
        image.Visibility = Visibility.Collapsed;
        image.Source = null;
        try
        {
            var thumbnail = await _thumbnails.GetAsync(
                _dataSource,
                entry.Item,
                PhotoThumbnailSize.Medium,
                PhotoThumbnailPriority.Visible,
                request.Token);
            if (thumbnail is null || request.IsCancellationRequested ||
                image.Tag is not PhotoBrowserEntry current || current.Path != entry.Path)
            {
                return;
            }

            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(thumbnail.Bytes);
                await writer.StoreAsync();
                await writer.FlushAsync();
                writer.DetachStream();
            }
            stream.Seek(0);
            var bitmap = new BitmapImage
            {
                DecodePixelWidth = ThumbnailDecodePixels,
                DecodePixelHeight = ThumbnailDecodePixels,
            };
            await bitmap.SetSourceAsync(stream);
            request.Token.ThrowIfCancellationRequested();
            image.Source = bitmap;
            image.Visibility = Visibility.Visible;
            SetSiblingPlaceholderVisibility(image, Visibility.Collapsed);
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested)
        {
        }
        catch
        {
            // 单张缩略图失败时保留照片占位图，不遮挡其余照片浏览主流程。
        }
        finally
        {
            if (_thumbnailRequests.TryGetValue(image, out var current) &&
                ReferenceEquals(current, request))
            {
                _thumbnailRequests.Remove(image);
                request.Dispose();
            }
        }
    }

    private void Thumbnail_Unloaded(object sender, RoutedEventArgs e)
    {
        if (sender is Image image)
        {
            CancelThumbnailRequest(image);
            image.Source = null;
        }
    }

    private static void SetSiblingPlaceholderVisibility(Image image, Visibility visibility)
    {
        if (VisualTreeHelper.GetParent(image) is not DependencyObject parent)
        {
            return;
        }
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            if (VisualTreeHelper.GetChild(parent, index) is FontIcon icon)
            {
                icon.Visibility = visibility;
                return;
            }
        }
    }

    private async Task RunLocationChangeAsync(Func<Task> action)
    {
        ExitPhotoBatchSelection();
        await ClosePhotoViewerAsync();
        CancelThumbnailRequests();
        await RunAsync(action);
        UpdateState();
    }

    private static async Task RunAsync(Func<Task> action)
    {
        try
        {
            await action();
        }
        catch (ObjectDisposedException)
        {
            // 页面关闭后的异步结果不再回写界面。
        }
    }

    private void UpdateState()
    {
        if (_disposed || ContentState is null)
        {
            return;
        }

        LocalizeBreadcrumbRoot();
        UpdateSpacePicker();
        LoadingState.Visibility = _viewModel.ContentState == PhotoBrowserContentState.Loading
            ? Visibility.Visible
            : Visibility.Collapsed;
        EmptyState.Visibility = _viewModel.IsEmpty ? Visibility.Visible : Visibility.Collapsed;
        FilteredEmptyState.Visibility = _viewModel.IsFilteredEmpty
            ? Visibility.Visible
            : Visibility.Collapsed;
        ErrorState.Visibility = _viewModel.HasError ? Visibility.Visible : Visibility.Collapsed;
        ContentState.Visibility = _viewModel.HasContent ? Visibility.Visible : Visibility.Collapsed;

        BackButton.IsEnabled = _viewModel.CanGoBack && !_viewModel.IsLoading;
        UpButton.IsEnabled = _viewModel.CanGoUp && !_viewModel.IsLoading;
        RefreshButton.IsEnabled = !_viewModel.IsLoading && !_viewModel.IsLoadingMore;
        OpenButton.IsEnabled = CanOpenSelectedMedia();
        SaveButton.IsEnabled = CanSaveSelectedMedia();
        UpdatePhotoViewerState();
        UpdatePhotoCopyMoveControls();
        UpdatePhotoRecycleControls();
        SpacePicker.IsEnabled = !_viewModel.IsLoading && _viewModel.Spaces.Count > 1;
        FilterButton.IsEnabled = !_viewModel.IsLoading;
        FilterAllItem.IsChecked = _viewModel.Filter == PhotoBrowserFilter.All;
        FilterImagesItem.IsChecked = _viewModel.Filter == PhotoBrowserFilter.Images;
        LoadMoreButton.Visibility = _viewModel.CanLoadMore || _viewModel.HasLoadMoreError
            ? Visibility.Visible
            : Visibility.Collapsed;
        LoadMoreButton.IsEnabled = _viewModel.CanLoadMore;
        LoadMoreProgress.IsActive = _viewModel.IsLoadingMore;
        LoadMoreProgress.Visibility = _viewModel.IsLoadingMore
            ? Visibility.Visible
            : Visibility.Collapsed;
        LoadMoreError.IsOpen = _viewModel.HasLoadMoreError;
        UpdatePhotoImportState();
        UpdatePhotoBatchControls();
    }

    private void UpdateSpacePicker()
    {
        var selectedId = _viewModel.SelectedSpace?.Id;
        var itemIds = SpacePicker.Items.OfType<ComboBoxItem>()
            .Select(item => item.Tag as string)
            .ToArray();
        var desiredIds = _viewModel.Spaces.Select(space => space.Id).ToArray();
        if (!itemIds.SequenceEqual(desiredIds, StringComparer.Ordinal))
        {
            _updatingSpaces = true;
            SpacePicker.Items.Clear();
            foreach (var space in _viewModel.Spaces)
            {
                SpacePicker.Items.Add(new ComboBoxItem
                {
                    Content = LocalizedSpaceName(space.Id),
                    Tag = space.Id,
                    MinHeight = 44,
                });
            }
            _updatingSpaces = false;
        }

        _updatingSpaces = true;
        SpacePicker.SelectedItem = SpacePicker.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => string.Equals(item.Tag as string, selectedId, StringComparison.Ordinal));
        _updatingSpaces = false;
    }

    private void LocalizeBreadcrumbRoot()
    {
        if (_viewModel.SelectedSpace is not { } space || _viewModel.Breadcrumbs.Count == 0)
        {
            return;
        }
        var localized = LocalizedSpaceName(space.Id);
        if (_viewModel.Breadcrumbs[0].Name != localized)
        {
            _viewModel.Breadcrumbs[0] = new PhotoBrowserBreadcrumb(localized, space.RootPath);
        }
    }

    private static string LocalizedSpaceName(string spaceId) =>
        LocalizationService.Current.Get(spaceId == PhotoSpaceIds.Personal
            ? "PhotoBrowserPersonalSpace"
            : "PhotoBrowserSharedSpace");

    private static void EnsureMatchingProfile(Guid sourceProfileId, string profileId)
    {
        if (!Guid.TryParse(profileId, out var parsedProfileId) ||
            sourceProfileId != parsedProfileId)
        {
            throw new ArgumentException(
                "The photo browser source must match the active profile.",
                nameof(profileId));
        }
    }

    private void CancelThumbnailRequest(Image image)
    {
        if (!_thumbnailRequests.Remove(image, out var request))
        {
            return;
        }
        request.Cancel();
        request.Dispose();
    }

    private void CancelThumbnailRequests()
    {
        var oldLocation = Interlocked.Exchange(
            ref _locationCancellation,
            new CancellationTokenSource());
        oldLocation.Cancel();
        oldLocation.Dispose();
        foreach (var request in _thumbnailRequests.Values)
        {
            request.Cancel();
            request.Dispose();
        }
        _thumbnailRequests.Clear();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Loaded -= PhotosPage_Loaded;
        Unloaded -= PhotosPage_Unloaded;
        _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        DisposePhotoImport();
        DisposePhotoViewer();
        ClosePhotoCopyMoveDialog();
        ClosePhotoBatchCopyMoveDialog();
        ClosePhotoRecycleDialog();
        ClosePhotoBatchRecycleDialog();
        DisposePhotoRecycleLocations();
        CancelThumbnailRequests();
        _locationCancellation.Dispose();
        _viewModel.Dispose();
        TimelineView.Dispose();
        _cacheRegistration.Dispose();
        _thumbnails.Dispose();
    }
}
