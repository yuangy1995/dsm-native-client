using System.ComponentModel;
using System.Globalization;
using LanStash.App.Features.Photos;
using LanStash.App.Features.Photos.Timeline;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace LanStash.App.Views;

public sealed partial class PhotoTimelineView : UserControl, IDisposable
{
    private readonly PhotoTimelineViewModel _viewModel = new();
    private readonly Dictionary<Image, CancellationTokenSource> _thumbnailRequests = [];
    private IPhotoTimelineDataSource? _source;
    private PhotoThumbnailScheduler? _thumbnails;
    private Func<PhotoItem, Task>? _save;
    private Func<PhotoItem, IReadOnlyList<PhotoItem>, Task>? _open;
    private Func<PhotoItem, bool>? _canRestore;
    private Func<PhotoItem, Task>? _restore;
    private CancellationTokenSource _thumbnailCancellation = new();
    private bool _syncingControls;
    private bool _disposed;

    public PhotoTimelineView()
    {
        InitializeComponent();
        ((CollectionViewSource)Resources["TimelineCollection"]).Source = _viewModel.Groups;
        FilterPicker.SelectedIndex = 0;
        _viewModel.PropertyChanged += ViewModel_PropertyChanged;
        UpdateState();
    }

    internal void Initialize(
        IPhotoTimelineDataSource source,
        PhotoThumbnailScheduler thumbnails,
        Func<PhotoItem, Task> save,
        Func<PhotoItem, IReadOnlyList<PhotoItem>, Task>? open = null,
        Func<PhotoItem, bool>? canRestore = null,
        Func<PhotoItem, Task>? restore = null)
    {
        _source = source;
        _thumbnails = thumbnails;
        _save = save;
        _open = open;
        _canRestore = canRestore;
        _restore = restore;
    }

    internal async Task ShowAsync(PhotoSpace space)
    {
        if (_disposed || _source is null) return;
        CancelThumbnailRequests();
        _viewModel.Activate(_source, space);
        ClearSelection();
        SyncControlsFromModel();
        LocalizeGroupTitles();
        UpdateState();
        await _viewModel.ScanIfNeededAsync();
        LocalizeGroupTitles();
        UpdateState();
    }

    internal async Task RefreshAsync()
    {
        if (_disposed || _source is null) return;
        await _viewModel.RefreshAsync();
        LocalizeGroupTitles();
        UpdateState();
    }

    internal void HideTimeline()
    {
        _viewModel.Cancel();
        CancelThumbnailRequests();
    }

    internal bool CanSaveSelected =>
        TimelineGrid.SelectedItem is PhotoTimelineEntry entry && _viewModel.CanSave(entry.Item);

    internal bool CanOpenSelected =>
        TimelineGrid.SelectedItem is PhotoTimelineEntry entry && CanOpen(entry.Item);

    internal bool CanRestoreSelected =>
        TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
        _canRestore?.Invoke(entry.Item) == true;

    internal bool HasSelectedItem(PhotoItem item) =>
        TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
        HasSameRevision(entry.Item, item);

    internal async Task SaveSelectedAsync()
    {
        if (TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
            _viewModel.CanSave(entry.Item) && _save is not null)
            await _save(entry.Item);
    }

    internal async Task OpenSelectedAsync()
    {
        if (TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
            CanOpen(entry.Item) && _open is not null)
            await _open(entry.Item, VisibleMediaItems());
    }

    internal async Task RestoreSelectedAsync()
    {
        if (TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
            _canRestore?.Invoke(entry.Item) == true && _restore is not null)
            await _restore(entry.Item);
    }

    internal void ClearSelection() => TimelineGrid.SelectedItem = null;

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();
    private void Cancel_Click(object sender, RoutedEventArgs e) { _viewModel.Cancel(); UpdateState(); }
    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    { if (!_syncingControls) _viewModel.Query = SearchBox.Text; LocalizeGroupTitles(); UpdateState(); }
    private void FilterPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_syncingControls && FilterPicker.SelectedItem is ComboBoxItem { Tag: string value } && Enum.TryParse<PhotoTimelineFilter>(value, out var filter))
        { _viewModel.SetFilter(filter); LocalizeGroupTitles(); UpdateState(); }
    }
    private void ClearFilters_Click(object sender, RoutedEventArgs e) { SearchBox.Text = string.Empty; FilterPicker.SelectedIndex = 0; }
    private void TimelineGrid_SelectionChanged(object sender, SelectionChangedEventArgs e) => UpdateState();
    private async void Open_Click(object sender, RoutedEventArgs e)
    { await OpenSelectedAsync(); }
    private async void Save_Click(object sender, RoutedEventArgs e)
    { await SaveSelectedAsync(); }
    private async void Restore_Click(object sender, RoutedEventArgs e)
    { await RestoreSelectedAsync(); }
    private async void OpenAccelerator_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    { if (CanOpenSelected) { args.Handled = true; await OpenSelectedAsync(); } }
    private async void TimelineGrid_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    { if (CanOpenSelected) { e.Handled = true; await OpenSelectedAsync(); } }

    private void ViewModel_PropertyChanged(object? sender, PropertyChangedEventArgs e) => DispatcherQueue.TryEnqueue(() => { LocalizeGroupTitles(); UpdateState(); });

    private void LocalizeGroupTitles()
    {
        var localization = LocalizationService.Current;
        var culture = CultureInfo.GetCultureInfo(localization.ResolvedLanguage);
        foreach (var group in _viewModel.Groups)
            group.Title = group.Month?.ToString("Y", culture) ?? localization.Get("PhotoTimelineUnknownMonth");
    }

    private void SyncControlsFromModel()
    {
        _syncingControls = true;
        SearchBox.Text = _viewModel.Query;
        FilterPicker.SelectedIndex = (int)_viewModel.Filter;
        _syncingControls = false;
    }

    private void UpdateState()
    {
        if (_disposed || IdleState is null) return;
        var hasVisible = _viewModel.Groups.Any(group => group.Items.Count > 0);
        IdleState.Visibility = _viewModel.Phase == PhotoTimelinePhase.Idle ? Visibility.Visible : Visibility.Collapsed;
        LoadingState.Visibility = _viewModel.Phase == PhotoTimelinePhase.Scanning && !_viewModel.HasCompletedSnapshot ? Visibility.Visible : Visibility.Collapsed;
        var showsBaseline = _viewModel.Phase == PhotoTimelinePhase.Scanning && _viewModel.HasCompletedSnapshot;
        EmptyState.Visibility = _viewModel.Phase == PhotoTimelinePhase.Empty || showsBaseline && _viewModel.CommittedIsEmpty
            ? Visibility.Visible : Visibility.Collapsed;
        ErrorState.Visibility = _viewModel.Phase == PhotoTimelinePhase.Error ? Visibility.Visible : Visibility.Collapsed;
        FilteredEmptyState.Visibility = (_viewModel.Phase == PhotoTimelinePhase.Content || showsBaseline) &&
            !_viewModel.CommittedIsEmpty && !hasVisible ? Visibility.Visible : Visibility.Collapsed;
        TimelineGrid.Visibility = (_viewModel.Phase == PhotoTimelinePhase.Content || _viewModel.Phase == PhotoTimelinePhase.Scanning) &&
            _viewModel.HasCompletedSnapshot && hasVisible ? Visibility.Visible : Visibility.Collapsed;
        TruncatedNotice.IsOpen = _viewModel.IsTruncated;
        PartialNotice.IsOpen = _viewModel.IsPartial;
        RefreshFailedNotice.IsOpen = _viewModel.RefreshFailed;
        RefreshProgress.IsActive = showsBaseline;
        RefreshProgress.Visibility = showsBaseline ? Visibility.Visible : Visibility.Collapsed;
        RefreshCancelButton.Visibility = showsBaseline ? Visibility.Visible : Visibility.Collapsed;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            RefreshProgress,
            LocalizationService.Current.Get("PhotoTimelineLoading.Text"));
        PartialNotice.Message = LocalizationService.Current.Format("PhotoTimelinePartialMessage", _viewModel.SkippedFolderCount);
        RefreshButton.IsEnabled = _viewModel.Phase != PhotoTimelinePhase.Scanning;
        SearchBox.IsEnabled = _viewModel.HasCompletedSnapshot;
        FilterPicker.IsEnabled = _viewModel.HasCompletedSnapshot;
        OpenButton.IsEnabled = CanOpenSelected;
        SaveButton.IsEnabled = CanSaveSelected;
        RestoreButton.Content = LocalizationService.Current.Get("FileRecycleRestoreAction");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            RestoreButton,
            LocalizationService.Current.Get(
                "FileRecycleRestore.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        RestoreButton.IsEnabled = CanRestoreSelected;
        RestoreButton.Visibility = CanRestoreSelected ? Visibility.Visible : Visibility.Collapsed;
    }

    private void TimelineGrid_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.ItemContainer.ContentTemplateRoot is not FrameworkElement root || root.FindName("TimelineThumbnail") is not Image image) return;
        CancelThumbnailRequest(image); image.Source = null; image.Visibility = Visibility.Collapsed;
        if (root.FindName("TimelinePlaceholder") is FontIcon icon)
        { icon.Glyph = args.Item is PhotoTimelineEntry { IsVideo: true } ? "\uE714" : "\uEB9F"; icon.Visibility = Visibility.Visible; }
        if (args.InRecycleQueue || args.Item is not PhotoTimelineEntry entry) return;
        image.Tag = entry;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(args.ItemContainer,
            LocalizationService.Current.Format(entry.IsVideo ? "PhotoTimelineVideoAutomationName" : "PhotoTimelineImageAutomationName", entry.Name));
        if (entry.IsImage && image.IsLoaded) _ = LoadThumbnailAsync(image, entry);
    }

    private async void Thumbnail_Loaded(object sender, RoutedEventArgs e)
    { if (sender is Image { Tag: PhotoTimelineEntry { IsImage: true } entry } image) await LoadThumbnailAsync(image, entry); }

    private async Task LoadThumbnailAsync(Image image, PhotoTimelineEntry entry)
    {
        if (_source is null || _thumbnails is null) return;
        CancelThumbnailRequest(image);
        var request = CancellationTokenSource.CreateLinkedTokenSource(_thumbnailCancellation.Token);
        _thumbnailRequests[image] = request;
        try
        {
            var thumbnail = await _thumbnails.GetAsync(_source, entry.Item, PhotoThumbnailSize.Medium, PhotoThumbnailPriority.Visible, request.Token);
            if (thumbnail is null || request.IsCancellationRequested || image.Tag is not PhotoTimelineEntry current ||
                !HasSameRevision(current.Item, entry.Item)) return;
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream)) { writer.WriteBytes(thumbnail.Bytes); await writer.StoreAsync(); await writer.FlushAsync(); writer.DetachStream(); }
            stream.Seek(0); var bitmap = new BitmapImage { DecodePixelWidth = 264, DecodePixelHeight = 264 }; await bitmap.SetSourceAsync(stream);
            request.Token.ThrowIfCancellationRequested(); image.Source = bitmap; image.Visibility = Visibility.Visible;
            if (VisualTreeHelper.GetParent(image) is DependencyObject parent)
                for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) if (VisualTreeHelper.GetChild(parent, i) is FontIcon icon) icon.Visibility = Visibility.Collapsed;
        }
        catch (OperationCanceledException) when (request.IsCancellationRequested) { }
        catch { }
        finally
        {
            if (_thumbnailRequests.TryGetValue(image, out var current) && ReferenceEquals(current, request))
            { _thumbnailRequests.Remove(image); request.Dispose(); }
        }
    }

    private void Thumbnail_Unloaded(object sender, RoutedEventArgs e) { if (sender is Image image) CancelThumbnailRequest(image); }
    private IReadOnlyList<PhotoItem> VisibleMediaItems() =>
        _viewModel.Groups
            .SelectMany(group => group.Items)
            .Select(entry => entry.Item)
            .Where(CanOpen)
            .ToArray();

    private static bool CanOpen(PhotoItem item) =>
        item.Kind is PhotoItemKind.Image or PhotoItemKind.Video &&
        item.SizeBytes is >= 0;

    private static bool HasSameRevision(PhotoItem left, PhotoItem right) =>
        left.ProfileId == right.ProfileId &&
        string.Equals(left.Path, right.Path, StringComparison.Ordinal) &&
        left.ModifiedAt == right.ModifiedAt &&
        left.SizeBytes == right.SizeBytes &&
        left.Kind == right.Kind;

    private void CancelThumbnailRequest(Image image) { if (_thumbnailRequests.Remove(image, out var request)) { request.Cancel(); request.Dispose(); } }
    private void CancelThumbnailRequests()
    {
        var old = Interlocked.Exchange(ref _thumbnailCancellation, new CancellationTokenSource()); old.Cancel(); old.Dispose();
        foreach (var request in _thumbnailRequests.Values) { request.Cancel(); request.Dispose(); } _thumbnailRequests.Clear();
    }

    public void Dispose()
    {
        if (_disposed) return; _disposed = true; _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        CancelThumbnailRequests(); _thumbnailCancellation.Dispose(); _viewModel.Dispose();
    }
}
