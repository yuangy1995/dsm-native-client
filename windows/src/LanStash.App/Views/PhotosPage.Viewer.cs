using System.Globalization;
using LanStash.App.Features.Files;
using LanStash.App.Features.Files.Preview;
using LanStash.App.Features.Photos;
using LanStash.App.Features.Photos.Timeline;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private IFilePreviewRepository? _previewRepository;
    private FilePreviewViewModel? _previewViewModel;
    private IReadOnlyList<PhotoItem> _photoViewerItems = [];
    private int _photoViewerIndex = -1;
    private long _photoViewerGeneration;

    private void InitializePhotoViewer(IFilePreviewRepository? previewRepository)
    {
        if (previewRepository is not null)
        {
            EnsureMatchingProfile(previewRepository.ProfileId, _profileId);
        }
        _previewRepository = previewRepository;
        _previewViewModel = new FilePreviewViewModel();
        PhotoPreviewPane.Attach(_previewViewModel);
        PhotoPreviewPane.CloseRequested += PhotoPreviewPane_CloseRequested;
        PhotoPreviewPane.RetryRequested += PhotoPreviewPane_RetryRequested;
        PhotoPreviewPane.SaveCopyRequested += PhotoPreviewPane_SaveCopyRequested;
        UpdatePhotoViewerState();
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

    private async Task ClosePhotoViewerAsync()
    {
        Interlocked.Increment(ref _photoViewerGeneration);
        _photoViewerItems = [];
        _photoViewerIndex = -1;
        if (_previewViewModel is null)
        {
            UpdatePhotoViewerState();
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
    }

    private async void PhotoPreviewPane_CloseRequested(object? sender, EventArgs e) =>
        await ClosePhotoViewerAsync();

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
        if (_photoViewerIndex > 0)
        {
            await OpenPhotoViewerIndexAsync(_photoViewerIndex - 1);
        }
    }

    private async void PhotoViewerNext_Click(object sender, RoutedEventArgs e)
    {
        if (_photoViewerIndex + 1 < _photoViewerItems.Count)
        {
            await OpenPhotoViewerIndexAsync(_photoViewerIndex + 1);
        }
    }

    private async void PhotoViewerSave_Click(object sender, RoutedEventArgs e)
    {
        if (CurrentPhotoViewerItem() is { } item)
        {
            await SaveTimelineItemAsync(item);
        }
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
        PhotoViewerHost.Visibility = isOpen ? Visibility.Visible : Visibility.Collapsed;
        PhotoViewerColumn.Width = isOpen ? new GridLength(420) : new GridLength(0);
        PhotoViewerPreviousButton.IsEnabled = _photoViewerIndex > 0;
        PhotoViewerNextButton.IsEnabled = _photoViewerIndex >= 0 &&
            _photoViewerIndex + 1 < _photoViewerItems.Count;
        PhotoViewerSaveButton.IsEnabled = item is not null && !_isSaving;
        PhotoPreviewPane.SetSaveCopyEnabled(PhotoViewerSaveButton.IsEnabled);

        var localization = LocalizationService.Current;
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
        PhotoViewerPathValue.Text = item.Path;
        AutomationProperties.SetName(
            PhotoViewerMetadata,
            localization.Format("PhotoViewerMetadataAutomationName", item.Name));
    }

    private void ClearPhotoViewerMetadata()
    {
        PhotoViewerNameValue.Text = string.Empty;
        PhotoViewerKindValue.Text = string.Empty;
        PhotoViewerSizeValue.Text = string.Empty;
        PhotoViewerCreatedValue.Text = string.Empty;
        PhotoViewerModifiedValue.Text = string.Empty;
        PhotoViewerPathValue.Text = string.Empty;
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

    private void DisposePhotoViewer()
    {
        if (_previewViewModel is not null)
        {
            PhotoPreviewPane.CloseRequested -= PhotoPreviewPane_CloseRequested;
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
