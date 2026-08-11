using System.ComponentModel;
using System.Globalization;
using LanStash.App.Features.Files;
using LanStash.App.Features.Files.Preview;
using LanStash.App.Features.Photos;
using LanStash.App.Features.Photos.Timeline;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private IFilePreviewRepository? _previewRepository;
    private FilePreviewViewModel? _previewViewModel;
    private IReadOnlyList<PhotoItem> _photoViewerItems = [];
    private int _photoViewerIndex = -1;
    private long _photoViewerGeneration;
    private bool _isPhotoViewerImmersive;

    private void InitializePhotoViewer(IFilePreviewRepository? previewRepository)
    {
        if (previewRepository is not null)
        {
            EnsureMatchingProfile(previewRepository.ProfileId, _profileId);
        }
        _previewRepository = previewRepository;
        _previewViewModel = new FilePreviewViewModel();
        _previewViewModel.PropertyChanged += PhotoPreviewViewModel_PropertyChanged;
        PhotoPreviewPane.Attach(_previewViewModel);
        PhotoPreviewPane.CloseRequested += PhotoPreviewPane_CloseRequested;
        PhotoPreviewPane.KeyboardCloseRequested += PhotoPreviewPane_KeyboardCloseRequested;
        PhotoPreviewPane.RetryRequested += PhotoPreviewPane_RetryRequested;
        PhotoPreviewPane.SaveCopyRequested += PhotoPreviewPane_SaveCopyRequested;
        UpdatePhotoViewerState();
    }

    private void PhotoPreviewViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(FilePreviewViewModel.Snapshot))
        {
            return;
        }

        if (DispatcherQueue.HasThreadAccess)
        {
            UpdatePhotoViewerState();
        }
        else
        {
            DispatcherQueue.TryEnqueue(UpdatePhotoViewerState);
        }
    }

    private bool CanOpenSelectedMedia() =>
        _viewModel.SelectedItem is { IsMedia: true } entry &&
        CanOpenPhotoViewerItem(entry.Item);

    private bool CanOpenPhotoViewerItem(PhotoItem item)
    {
        var space = _viewModel.SelectedSpace;
        return _previewRepository is not null &&
            !_viewModel.IsLoading &&
            item.ProfileId == _dataSource.ProfileId &&
            space is not null &&
            PhotoTimelineViewModel.ContainsCanonicalPath(space.RootPath, item.Path) &&
            item.Kind is PhotoItemKind.Image or PhotoItemKind.Video &&
            item.SizeBytes is >= 0;
    }

    private async Task OpenSelectedPhotoAsync()
    {
        if (_viewModel.SelectedItem is { IsMedia: true } entry)
        {
            await OpenFolderViewerAsync(entry);
        }
    }

    private async Task OpenFolderViewerAsync(PhotoBrowserEntry entry)
    {
        if (!CanOpenPhotoViewerItem(entry.Item))
        {
            return;
        }
        var items = _viewModel.Items
            .Select(item => item.Item)
            .Where(CanOpenPhotoViewerItem)
            .ToArray();
        await OpenPhotoViewerAsync(entry.Item, items);
    }

    private async Task OpenTimelineViewerAsync(
        PhotoItem item,
        IReadOnlyList<PhotoItem> visibleItems)
    {
        await OpenPhotoViewerAsync(item, visibleItems.Where(CanOpenPhotoViewerItem).ToArray());
    }

    private async Task OpenPhotoViewerAsync(PhotoItem item, IReadOnlyList<PhotoItem> items)
    {
        if (_previewRepository is null || _previewViewModel is null ||
            !CanOpenPhotoViewerItem(item))
        {
            return;
        }

        var index = IndexOfSameRevision(items, item);
        if (index < 0)
        {
            return;
        }

        _photoViewerItems = items;
        _photoViewerIndex = index;
        await OpenPhotoViewerIndexAsync(index);
    }

    private async Task OpenPhotoViewerIndexAsync(int index)
    {
        if (_previewRepository is null || _previewViewModel is null ||
            index < 0 || index >= _photoViewerItems.Count)
        {
            return;
        }

        var item = _photoViewerItems[index];
        if (!CanOpenPhotoViewerItem(item))
        {
            return;
        }

        var generation = Interlocked.Increment(ref _photoViewerGeneration);
        _photoViewerIndex = index;
        UpdatePhotoViewerState();
        try
        {
            await _previewViewModel.OpenAsync(
                _previewRepository,
                _dataSource.ProfileId,
                ToFileItem(item));
        }
        catch (ObjectDisposedException)
        {
            return;
        }

        if (generation == Volatile.Read(ref _photoViewerGeneration) && !_disposed)
        {
            UpdatePhotoViewerState();
            PhotoPreviewPane.FocusHeading();
        }
    }

    private async Task ClosePhotoViewerAsync(bool restoreBrowserFocus = false)
    {
        Interlocked.Increment(ref _photoViewerGeneration);
        ExitPhotoViewerImmersive(restoreFocus: false);
        _photoViewerItems = [];
        _photoViewerIndex = -1;
        if (_previewViewModel is null)
        {
            UpdatePhotoViewerState();
            if (restoreBrowserFocus)
            {
                FocusPhotoBrowserAfterViewerClose();
            }
            return;
        }
        try
        {
            await PhotoPreviewPane.CloseAsync();
            await _previewViewModel.CloseAsync();
        }
        catch (ObjectDisposedException)
        {
        }
        UpdatePhotoViewerState();
        if (restoreBrowserFocus)
        {
            FocusPhotoBrowserAfterViewerClose();
        }
    }

    private async void PhotoPreviewPane_CloseRequested(object? sender, EventArgs e) =>
        await ClosePhotoViewerAsync(restoreBrowserFocus: true);

    private void PhotoPreviewPane_KeyboardCloseRequested(
        object? sender,
        FilePreviewKeyboardCloseRequestedEventArgs e)
    {
        if (ExitPhotoViewerImmersive())
        {
            e.Handled = true;
        }
    }

    private async void PhotoPreviewPane_RetryRequested(object? sender, EventArgs e)
    {
        if (_photoViewerIndex >= 0)
        {
            await OpenPhotoViewerIndexAsync(_photoViewerIndex);
        }
    }

    private async void PhotoPreviewPane_SaveCopyRequested(
        object? sender,
        FilePreviewSaveCopyRequestedEventArgs e)
    {
        if (CurrentPhotoViewerItem() is { } item)
        {
            await SaveTimelineItemAsync(item);
        }
    }

    private async void PhotoViewerPrevious_Click(object sender, RoutedEventArgs e)
    {
        await OpenPhotoViewerOffsetAsync(-1);
    }

    private async void PhotoViewerNext_Click(object sender, RoutedEventArgs e)
    {
        await OpenPhotoViewerOffsetAsync(1);
    }

    private async void PhotoViewerSave_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPhotoViewerItem() is { } item)
        {
            await SaveTimelineItemAsync(item);
        }
    }

    private async void PhotoViewerPreviousAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_photoViewerIndex <= 0)
        {
            return;
        }

        args.Handled = true;
        await OpenPhotoViewerOffsetAsync(-1);
    }

    private async void PhotoViewerNextAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (_photoViewerIndex + 1 >= _photoViewerItems.Count)
        {
            return;
        }

        args.Handled = true;
        await OpenPhotoViewerOffsetAsync(1);
    }

    private void PhotoViewerImmersive_Click(object sender, RoutedEventArgs e) =>
        TogglePhotoViewerImmersive();

    private void PhotoViewerImmersiveAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (CurrentPhotoViewerItem() is null)
        {
            return;
        }

        args.Handled = true;
        TogglePhotoViewerImmersive();
    }

    private async Task<bool> OpenPhotoViewerOffsetAsync(int offset)
    {
        var nextIndex = _photoViewerIndex + offset;
        if (nextIndex < 0 || nextIndex >= _photoViewerItems.Count)
        {
            return false;
        }

        await OpenPhotoViewerIndexAsync(nextIndex);
        return true;
    }

    private void TogglePhotoViewerImmersive()
    {
        if (CurrentPhotoViewerItem() is null)
        {
            return;
        }

        if (!_isPhotoViewerImmersive &&
            (Application.Current as App)?.MainWindow?.EnterPhotoViewerFullScreen() != true)
        {
            return;
        }

        if (_isPhotoViewerImmersive)
        {
            (Application.Current as App)?.MainWindow?.ExitPhotoViewerFullScreen();
        }
        _isPhotoViewerImmersive = !_isPhotoViewerImmersive;
        UpdatePhotoViewerState();
        PhotoPreviewPane.FocusHeading();
    }

    private bool ExitPhotoViewerImmersive(bool restoreFocus = true)
    {
        if (!_isPhotoViewerImmersive)
        {
            (Application.Current as App)?.MainWindow?.ExitPhotoViewerFullScreen();
            return false;
        }

        (Application.Current as App)?.MainWindow?.ExitPhotoViewerFullScreen();
        _isPhotoViewerImmersive = false;
        UpdatePhotoViewerState();
        if (restoreFocus)
        {
            PhotoPreviewPane.FocusHeading();
        }
        return true;
    }

    internal void SetWindowVisible(bool isVisible)
    {
        if (isVisible)
        {
            return;
        }

        ExitPhotoViewerImmersive(restoreFocus: false);
        PhotoPreviewPane.PauseMediaPlayback();
    }

    private PhotoItem? CurrentPhotoViewerItem() =>
        _photoViewerIndex >= 0 && _photoViewerIndex < _photoViewerItems.Count
            ? _photoViewerItems[_photoViewerIndex]
            : null;

    private void UpdatePhotoViewerState()
    {
        if (PhotoViewerHost is null)
        {
            return;
        }

        var item = CurrentPhotoViewerItem();
        var isOpen = item is not null;
        if (!isOpen)
        {
            ExitPhotoViewerImmersive(restoreFocus: false);
        }
        PhotoViewerHost.Visibility = isOpen ? Visibility.Visible : Visibility.Collapsed;
        ApplyPhotoViewerLayout(isOpen);
        PhotoViewerPreviousButton.IsEnabled = _photoViewerIndex > 0;
        PhotoViewerNextButton.IsEnabled = _photoViewerIndex >= 0 &&
            _photoViewerIndex + 1 < _photoViewerItems.Count;
        PhotoViewerSaveButton.IsEnabled = item is not null && !_isSaving;
        PhotoPreviewPane.SetSaveCopyEnabled(PhotoViewerSaveButton.IsEnabled);

        var localization = LocalizationService.Current;
        UpdatePhotoViewerImmersiveButton(localization, isOpen);
        PhotoViewerPositionText.Text = isOpen
            ? localization.Format(
                "PhotoViewerPosition",
                _photoViewerIndex + 1,
                _photoViewerItems.Count)
            : string.Empty;
        if (item is null)
        {
            ClearPhotoViewerMetadata();
            return;
        }

        PhotoViewerNameValue.Text = item.Name;
        PhotoViewerKindValue.Text = localization.Get(item.Kind == PhotoItemKind.Video
            ? "PhotoViewerKindVideo"
            : "PhotoViewerKindImage");
        PhotoViewerSizeValue.Text = FormatPhotoViewerBytes(item.SizeBytes);
        PhotoViewerCreatedValue.Text = FormatPhotoViewerDate(item.CreatedAt);
        PhotoViewerModifiedValue.Text = FormatPhotoViewerDate(item.ModifiedAt);
        var metadata = CurrentPhotoPreviewMetadata(item);
        PhotoViewerDimensionsValue.Text = FormatPhotoViewerDimensions(metadata);
        PhotoViewerTakenValue.Text = FormatPhotoViewerCapturedAt(metadata);
        PhotoViewerDurationValue.Text = FormatPhotoViewerDuration(metadata);
        PhotoViewerCameraValue.Text = FormatPhotoViewerCamera(metadata);
        PhotoViewerPathValue.Text = item.Path;
        AutomationProperties.SetName(
            PhotoViewerHost,
            localization.Format("PhotoViewerHostAutomationName", item.Name));
        AutomationProperties.SetName(
            PhotoViewerPositionText,
            localization.Format(
                "PhotoViewerPositionAutomationName",
                _photoViewerIndex + 1,
                _photoViewerItems.Count));
        AutomationProperties.SetName(
            PhotoViewerMetadata,
            localization.Format("PhotoViewerMetadataAutomationName", item.Name));
    }

    private void ApplyPhotoViewerLayout(bool isOpen)
    {
        var isImmersive = isOpen && _isPhotoViewerImmersive;
        Grid.SetColumn(PhotoViewerHost, isImmersive ? 0 : 1);
        Grid.SetColumnSpan(PhotoViewerHost, isImmersive ? 2 : 1);
        PhotoViewerColumn.Width = isOpen && !isImmersive
            ? new GridLength(420)
            : new GridLength(0);
        ApplyPhotoBrowserSurfaceVisibility(isImmersive);
    }

    private void ApplyPhotoBrowserSurfaceVisibility(bool isViewerImmersive)
    {
        var browserVisibility = isViewerImmersive
            ? Visibility.Collapsed
            : Visibility.Visible;
        PhotoBrowserHeader.Visibility = browserVisibility;
        PhotoBrowserModeBar.Visibility = browserVisibility;
        ImportStatus.Visibility = browserVisibility;

        if (isViewerImmersive)
        {
            PathBreadcrumbs.Visibility = Visibility.Collapsed;
            BrowserCommandBar.Visibility = Visibility.Collapsed;
            BrowserContentHost.Visibility = Visibility.Collapsed;
            TimelineView.Visibility = Visibility.Collapsed;
            return;
        }

        var isTimelineMode = TimelineMode.IsChecked == true;
        PathBreadcrumbs.Visibility = isTimelineMode ? Visibility.Collapsed : Visibility.Visible;
        BrowserCommandBar.Visibility = isTimelineMode ? Visibility.Collapsed : Visibility.Visible;
        BrowserContentHost.Visibility = isTimelineMode ? Visibility.Collapsed : Visibility.Visible;
        TimelineView.Visibility = isTimelineMode ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdatePhotoViewerImmersiveButton(LocalizationService localization, bool isOpen)
    {
        var isImmersive = isOpen && _isPhotoViewerImmersive;
        PhotoViewerImmersiveButton.IsEnabled = isOpen;
        PhotoViewerImmersiveButton.Content = localization.Get(isImmersive
            ? "PhotoViewerExitImmersive.Content"
            : "PhotoViewerEnterImmersive.Content");
        var automationName = localization.Get(isImmersive
            ? "PhotoViewerExitImmersive.AutomationProperties.Name"
            : "PhotoViewerEnterImmersive.AutomationProperties.Name");
        AutomationProperties.SetName(PhotoViewerImmersiveButton, automationName);
        ToolTipService.SetToolTip(PhotoViewerImmersiveButton, automationName);
    }

    private void FocusPhotoBrowserAfterViewerClose()
    {
        if (_disposed)
        {
            return;
        }

        if (TimelineMode.IsChecked == true)
        {
            TimelineView.Focus(FocusState.Programmatic);
            return;
        }

        PhotoGrid.Focus(FocusState.Programmatic);
    }

    private void ClearPhotoViewerMetadata()
    {
        PhotoViewerNameValue.Text = string.Empty;
        PhotoViewerKindValue.Text = string.Empty;
        PhotoViewerSizeValue.Text = string.Empty;
        PhotoViewerCreatedValue.Text = string.Empty;
        PhotoViewerModifiedValue.Text = string.Empty;
        PhotoViewerDimensionsValue.Text = string.Empty;
        PhotoViewerTakenValue.Text = string.Empty;
        PhotoViewerDurationValue.Text = string.Empty;
        PhotoViewerCameraValue.Text = string.Empty;
        PhotoViewerPathValue.Text = string.Empty;
    }

    private FilePreviewMediaMetadata? CurrentPhotoPreviewMetadata(PhotoItem item)
    {
        var snapshot = _previewViewModel?.Snapshot;
        if (snapshot is
            {
                ProfileId: { } profileId,
                Item: { } previewItem,
                MediaMetadata: { } metadata,
            } &&
            profileId == item.ProfileId &&
            string.Equals(previewItem.Path, item.Path, StringComparison.Ordinal) &&
            previewItem.Size == item.SizeBytes &&
            previewItem.ModifiedAt == item.ModifiedAt)
        {
            return metadata;
        }
        return null;
    }

    private static FileItem ToFileItem(PhotoItem item) => new(
        item.Path,
        item.Name,
        IsDirectory: false,
        item.SizeBytes ?? -1,
        item.ModifiedAt,
        Owner: null,
        CanWrite: false,
        CanDelete: false);

    private static int IndexOfSameRevision(IReadOnlyList<PhotoItem> items, PhotoItem item)
    {
        for (var index = 0; index < items.Count; index++)
        {
            if (HasSameRevision(items[index], item))
            {
                return index;
            }
        }
        return -1;
    }

    private static bool HasSameRevision(PhotoItem left, PhotoItem right) =>
        left.ProfileId == right.ProfileId &&
        string.Equals(left.Path, right.Path, StringComparison.Ordinal) &&
        left.ModifiedAt == right.ModifiedAt &&
        left.SizeBytes == right.SizeBytes &&
        left.Kind == right.Kind;

    private static string FormatPhotoViewerDate(DateTimeOffset? value)
    {
        if (value is null)
        {
            return LocalizationService.Current.Get("PhotoViewerValueUnavailable");
        }
        var culture = CultureInfo.GetCultureInfo(LocalizationService.Current.ResolvedLanguage);
        return value.Value.LocalDateTime.ToString("g", culture);
    }

    private static string FormatPhotoViewerBytes(long? bytes)
    {
        if (bytes is null)
        {
            return LocalizationService.Current.Get("PhotoViewerValueUnavailable");
        }
        string[] unitKeys =
        [
            "PhotoViewerByteValueB",
            "PhotoViewerByteValueKB",
            "PhotoViewerByteValueMB",
            "PhotoViewerByteValueGB",
            "PhotoViewerByteValueTB",
        ];
        var scaled = (double)Math.Max(0, bytes.Value);
        var unit = 0;
        while (scaled >= 1024 && unit < unitKeys.Length - 1)
        {
            scaled /= 1024;
            unit++;
        }
        var format = unit == 0 ? "N0" : scaled >= 10 ? "N1" : "N2";
        var culture = CultureInfo.GetCultureInfo(LocalizationService.Current.ResolvedLanguage);
        return LocalizationService.Current.Format(
            unitKeys[unit],
            scaled.ToString(format, culture));
    }

    private static string FormatPhotoViewerDimensions(FilePreviewMediaMetadata? metadata)
    {
        if (metadata is not { PixelWidth: > 0, PixelHeight: > 0 })
        {
            return LocalizationService.Current.Get("PhotoViewerValueUnavailable");
        }

        return LocalizationService.Current.Format(
            "PhotoViewerDimensionsValue",
            metadata.PixelWidth.Value,
            metadata.PixelHeight.Value);
    }

    private static string FormatPhotoViewerCapturedAt(FilePreviewMediaMetadata? metadata)
    {
        if (metadata?.CapturedAt is null)
        {
            return LocalizationService.Current.Get("PhotoViewerValueUnavailable");
        }
        var culture = CultureInfo.GetCultureInfo(LocalizationService.Current.ResolvedLanguage);
        return metadata.CapturedAt.Value.LocalDateTime.ToString("g", culture);
    }

    private static string FormatPhotoViewerDuration(FilePreviewMediaMetadata? metadata)
    {
        if (metadata?.Duration is not { } duration || duration <= TimeSpan.Zero)
        {
            return LocalizationService.Current.Get("PhotoViewerValueUnavailable");
        }

        var totalHours = (long)duration.TotalHours;
        return totalHours > 0
            ? LocalizationService.Current.Format(
                "PhotoViewerDurationValueHours",
                totalHours,
                duration.Minutes,
                duration.Seconds)
            : LocalizationService.Current.Format(
                "PhotoViewerDurationValueMinutes",
                duration.Minutes,
                duration.Seconds);
    }

    private static string FormatPhotoViewerCamera(FilePreviewMediaMetadata? metadata)
    {
        var parts = new[]
            {
                metadata?.CameraManufacturer,
                metadata?.CameraModel,
            }
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value!.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        return parts.Length == 0
            ? LocalizationService.Current.Get("PhotoViewerValueUnavailable")
            : string.Join(" ", parts);
    }

    private void DisposePhotoViewer()
    {
        ExitPhotoViewerImmersive(restoreFocus: false);
        if (_previewViewModel is not null)
        {
            _previewViewModel.PropertyChanged -= PhotoPreviewViewModel_PropertyChanged;
            PhotoPreviewPane.CloseRequested -= PhotoPreviewPane_CloseRequested;
            PhotoPreviewPane.KeyboardCloseRequested -= PhotoPreviewPane_KeyboardCloseRequested;
            PhotoPreviewPane.RetryRequested -= PhotoPreviewPane_RetryRequested;
            PhotoPreviewPane.SaveCopyRequested -= PhotoPreviewPane_SaveCopyRequested;
            _previewViewModel.Dispose();
            _previewViewModel = null;
        }
        PhotoPreviewPane.Dispose();
        _previewRepository = null;
        _photoViewerItems = [];
        _photoViewerIndex = -1;
    }
}
