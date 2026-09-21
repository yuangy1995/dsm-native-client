using System.Collections.ObjectModel;
using System.ComponentModel;
using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Settings;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace LanStash.App.Views.Photos;

public sealed partial class SynologyPhotosPage : Page, IDisposable
{
    private readonly SynologyPhotosWorkspace _model;
    private readonly IWindowsTransferSavePicker _savePicker;
    private readonly SynologyPhotoThumbnailCache<BitmapImage> _thumbnails;
    private readonly IDisposable _cacheRegistration;
    private readonly LocalizationService _l = LocalizationService.Current;
    private readonly ObservableCollection<SynologyPhotoGroup> _groups = [];
    private readonly Dictionary<string, SynologyPhotoGroup> _groupsByKey = [];
    private readonly Dictionary<SelectorItem, CancellationTokenSource> _visibleRequests = [];
    private string _displayedSearchText = "";
    private bool _ready;
    private bool _rendering;
    private bool _disposed;
    private bool _windowVisible = true;
    private long _viewGeneration;
    private CancellationTokenSource _viewCancellation = new();
    private ContentDialog? _dialog;

    internal SynologyPhotosPage(ISynologyPhotosRepository repository, IWindowsTransferSavePicker savePicker)
    {
        InitializeComponent();
        _model = new(repository); _savePicker = savePicker;
        _thumbnails = new(repository, (bytes, token) => SynologyPhotoImages.DecodeAsync(bytes, 320, token));
        _cacheRegistration = AppSettingsService.Current.Caches.Register(_thumbnails);
        PhotosSource.Source = _groups; LibraryGrid.ItemsSource = PhotosSource.View;
        _model.PropertyChanged += ModelChanged;
        _model.ContentChanged += RebuildGroups;
        _model.RequestChanged += RequestChanged;
        _model.Preview.PropertyChanged += PreviewChanged;
        _model.Deletion.PropertyChanged += ModelChanged;
        _l.LanguageChanged += LanguageChanged;
        Loaded += PageLoaded; Unloaded += PageUnloaded; KeyDown += PageKeyDown;
        LibraryGrid.PointerWheelChanged += LibraryWheelChanged;
        SizeChanged += (_, _) =>
        {
            Sections.MinWidth = ActualWidth >= 760 ? 320 : 160;
            SearchBox.Width = Math.Clamp(ActualWidth - 540, 100, 280);
        };
        _ready = true; Localize(); Render();
    }

    public static FrameworkElement CreateUnavailableState() => new TextBlock
    {
        Text = LocalizationService.Current.Get("PhotosServiceUnavailable"), TextWrapping = TextWrapping.Wrap,
        MaxWidth = 520, Margin = new Thickness(24), HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    internal Task ShowSectionAsync(SynologyPhotosSection section) => _model.SelectSectionAsync(section);

    private async void PageLoaded(object sender, RoutedEventArgs args)
    { if (!_disposed && _windowVisible) await _model.LoadIfNeededAsync(); }
    private void PageUnloaded(object sender, RoutedEventArgs args) => Suspend();
    public void SetWindowVisible(bool visible)
    {
        _windowVisible = visible;
        if (!visible) Suspend();
        else if (!_disposed && IsLoaded) _ = _model.LoadIfNeededAsync();
    }
    private void Suspend()
    {
        if (_disposed) return;
        _dialog?.Hide(); _model.Suspend(); _saveCancellation?.Cancel();
    }
    private void RequestChanged()
    {
        _viewGeneration++; _viewCancellation.Cancel(); _viewCancellation.Dispose(); _viewCancellation = new();
        CancelThumbnails(); _thumbnails.Clear(); _groups.Clear(); _groupsByKey.Clear();
    }
    private void CancelThumbnails()
    {
        foreach (var (container, cancellation) in _visibleRequests)
        {
            cancellation.Cancel();
            if (FindChild<Image>(container) is { } image) image.Source = null;
        }
        _visibleRequests.Clear();
    }
    private void LanguageChanged(object? sender, EventArgs args)
    { if (_disposed) return; Localize(); _groups.Clear(); _groupsByKey.Clear(); RebuildGroups(); Render(); }
    private void Localize()
    {
        PageTitle.Text = _l.Get("ModulePhotos"); SpaceTitle.Text = _l.Get("PhotosPersonalSpace");
        ToolTipService.SetToolTip(SpaceTitle, _l.Get("PhotosSharedSpaceClosed"));
        TimelineTab.Header = _l.Get("PhotosLibraryTimeline"); FoldersTab.Header = _l.Get("PhotosLibraryFolders");
        AlbumsTab.Header = _l.Get("PhotosLibraryAlbums"); SharingTab.Header = _l.Get("PhotosLibrarySharing");
        SearchBox.PlaceholderText = _l.Get("PhotosSearchPlaceholder");
        AutomationProperties.SetName(SearchBox, _l.Get("PhotosSearchPlaceholder"));
        AutomationProperties.SetName(MonthPicker, _l.Get("PhotosChooseMonth"));
        foreach (var (button, key) in new (Button, string)[] { (RefreshButton, "PhotosRefresh"), (BackButton, "PhotosBack"), (FiltersButton, "PhotosFilters") })
        { AutomationProperties.SetName(button, _l.Get(key)); ToolTipService.SetToolTip(button, _l.Get(key)); }
        RetryButton.Content = _l.Get("PhotosRetry"); ReviewButton.Content = _l.Get("PhotosReviewDeletion");
        NewerButton.Content = _l.Get("PhotosLoadNewer"); OlderButton.Content = _l.Get("PhotosLoadOlder");
        foreach (var (button, key) in new (AppBarButton, string)[]
        {
            (PreviousPhotoButton, "PhotosPreviousPhoto"), (NextPhotoButton, "PhotosNextPhoto"), (MotionButton, "PhotosPlayLive"),
            (SaveButton, "PhotosSaveOriginal"), (DeleteButton, "PhotosDeleteOriginal"), (DetailsButton, "PhotosDetails"), (ClosePreviewButton, "PhotosClose"),
        }) { button.Label = _l.Get(key); AutomationProperties.SetName(button, _l.Get(key)); }
        PreviewRetryButton.Content = _l.Get("PhotosRetry");
        CancelSaveButton.Content = _l.Get("PhotosCancel");
        PreviewCancelSaveButton.Content = _l.Get("PhotosCancel");
        PreviewReviewButton.Content = _l.Get("PhotosReviewDeletion");
        AutomationProperties.SetName(LibraryGrid, _l.Get("ModulePhotos"));
    }
    private void ModelChanged(object? sender, PropertyChangedEventArgs args) => Render();
    private void Render()
    {
        if (!_ready || _disposed) return;
        _rendering = true;
        try
        {
            var busy = _model.Deletion.IsBusy;
            Sections.SelectedIndex = (int)_model.Section; Sections.IsEnabled = !busy;
            SearchBox.Visibility = Visible(_model.Section == SynologyPhotosSection.Timeline);
            FiltersButton.Visibility = SearchBox.Visibility;
            FiltersButton.IsEnabled = !busy && !_model.IsLoading;
            SearchBox.IsEnabled = !busy;
            // 分页/进度刷新不能覆盖用户尚未提交的搜索草稿。
            if (_displayedSearchText != _model.SearchText)
            { _displayedSearchText = _model.SearchText; SearchBox.Text = _displayedSearchText; }
            MonthPicker.ItemsSource = _model.Months; MonthPicker.SelectedItem = _model.SelectedMonth;
            MonthPicker.Visibility = Visible(_model.Months.Count > 0); MonthPicker.IsEnabled = !busy;
            BackButton.Visibility = Visible(_model.CanGoBack); BackButton.IsEnabled = !busy;
            RefreshButton.IsEnabled = !busy;
            CategoryButtons.ItemsSource = _model.Categories.OrderBy(value => value).Select(value => new SynologyPhotoCategoryChoice(value, CategoryTitle(value))).ToArray();
            CategoryButtons.Visibility = Visible(_model.ShowsCategories && _model.Categories.Count > 0);
            CategoryButtons.IsEnabled = !busy;
            ShareScopePicker.ItemsSource = Enum.GetValues<SynologyPhotoShareScope>().Select(scope => new SynologyPhotoShareChoice(scope, ShareTitle(scope))).ToArray();
            ShareScopePicker.DisplayMemberPath = nameof(SynologyPhotoShareChoice.Title);
            ShareScopePicker.SelectedIndex = (int)_model.ShareScope;
            ShareScopePicker.Visibility = Visible(_model.Section == SynologyPhotosSection.Sharing && _model.Album is null);
            ShareScopePicker.IsEnabled = !busy;
            LocationTitle.Text = _model.CategoryItem?.Name ?? _model.Album?.Name ??
                (_model.Category is { } category ? CategoryTitle(category) :
                    _model.FolderHistory.LastOrDefault()?.Name is { Length: > 0 } folder ? folder : "");
            LocationTitle.Visibility = Visible(LocationTitle.Text.Length > 0);
            ErrorBar.IsOpen = _model.ErrorKey is not null; ErrorBar.Message = _model.ErrorKey is { } error ? _l.Get(error) : "";
            DeletionBar.IsOpen = _model.Deletion.Pending is not null || _model.Deletion.ErrorKey is not null;
            DeletionBar.Message = _l.Get(_model.Deletion.ErrorKey ?? "PhotosDeletePending");
            ReviewButton.Visibility = Visible(_model.Deletion.Pending is not null); ReviewButton.IsEnabled = !busy;
            NewerButton.Visibility = Visible(_model.HasPrevious); NewerButton.IsEnabled = !_model.IsLoadingPrevious && !_model.IsLoading && !busy;
            PreviousProgress.IsActive = _model.IsLoadingPrevious; PreviousProgress.Visibility = Visible(_model.IsLoadingPrevious);
            PreviousError.Text = _model.PreviousErrorKey is { } previous ? _l.Get(previous) : "";
            OlderButton.Visibility = Visible(_model.HasMore || _model.HasMoreCollections);
            OlderButton.IsEnabled = !_model.IsLoading && !_model.IsLoadingMore && !busy;
            NextProgress.IsActive = _model.IsLoadingMore; NextProgress.Visibility = Visible(_model.IsLoadingMore);
            var empty = _model.Items.Count + _model.Collections.Count + _model.SharedEntries.Count == 0;
            EmptyPanel.Visibility = Visible(empty);
            LoadingProgress.IsActive = _model.IsLoading; LoadingProgress.Visibility = Visible(_model.IsLoading);
            EmptyTitle.Text = _l.Get(_model.IsLoading ? "PhotosLoading" : _model.ErrorKey is not null ? "PhotosLoadFailed" : _model.IsFiltering ? "PhotosFilteredEmpty" : "PhotosEmpty");
            EmptyMessage.Text = _l.Get(_model.IsLoading ? "PhotosLoadingDescription" : _model.ErrorKey ??
                (_model.IsFiltering ? "PhotosFilteredEmptyDescription" : "PhotosEmptyDescription"));
            CountText.Text = _l.Format("PhotosLoadedCount", _model.Items.Count + _model.Collections.Count + _model.SharedEntries.Count);
            RenderPreviewControls();
        }
        finally { _rendering = false; }
    }

    private void RebuildGroups()
    {
        if (_disposed) return;
        var desired = new List<(string Key, string Title, SynologyPhotoCell[] Cells)>();
        if (_model.Collections.Count > 0)
            desired.Add(("collections", _l.Get(_model.Section == SynologyPhotosSection.Folders ? "PhotosLibraryFolders" : "PhotosLibraryAlbums"),
                _model.Collections.Select(item => new SynologyPhotoCell { Id = $"collection:{item.Id}", Collection = item }).ToArray()));
        if (_model.SharedEntries.Count > 0)
            desired.Add(("sharing", ShareTitle(_model.ShareScope), _model.SharedEntries.Select(item => new SynologyPhotoCell { Id = $"shared:{item.Id}", Shared = item }).ToArray()));
        if (_model.ShowsTimeline)
        {
            foreach (var group in _model.Items.GroupBy(photo => DateOnly.FromDateTime((_model.Category == SynologyPhotoCategory.Recent ? photo.IndexedAt : photo.TakenAt).LocalDateTime)).OrderByDescending(group => group.Key))
                desired.Add(($"day:{group.Key:yyyyMMdd}", group.Key.ToString("D", System.Globalization.CultureInfo.CurrentCulture), group.Select(PhotoCell).ToArray()));
        }
        else if (_model.Items.Count > 0) desired.Add(("photos", _l.Get("ModulePhotos"), _model.Items.Select(PhotoCell).ToArray()));
        var keys = desired.Select(group => group.Key).ToHashSet();
        for (var index = _groups.Count - 1; index >= 0; index--)
            if (!keys.Contains(_groups[index].Key)) { _groupsByKey.Remove(_groups[index].Key); _groups.RemoveAt(index); }
        for (var index = 0; index < desired.Count; index++)
        {
            var target = desired[index];
            if (!_groupsByKey.TryGetValue(target.Key, out var group))
            { group = new(target.Key, target.Title); _groupsByKey.Add(target.Key, group); _groups.Insert(index, group); }
            else if (!ReferenceEquals(_groups[index], group)) _groups.Move(_groups.IndexOf(group), index);
            var ids = target.Cells.Select(cell => cell.Id).ToHashSet();
            for (var cellIndex = group.Count - 1; cellIndex >= 0; cellIndex--)
                if (!ids.Contains(group[cellIndex].Id)) group.RemoveAt(cellIndex);
            var existing = group.Select(cell => cell.Id).ToHashSet();
            foreach (var cell in target.Cells) if (existing.Add(cell.Id)) group.Add(cell);
        }
    }
    private static SynologyPhotoCell PhotoCell(SynologyPhoto photo) => new() { Id = $"photo:{photo.Id.ProfileId}:{photo.Id.Space}:{photo.Id.ItemId}", Photo = photo };
    private string CategoryTitle(SynologyPhotoCategory category) => _l.Get(category switch
    {
        SynologyPhotoCategory.Recent => "PhotosCategoryRecent", SynologyPhotoCategory.People => "PhotosCategoryPeople",
        SynologyPhotoCategory.Subjects => "PhotosCategorySubjects", SynologyPhotoCategory.Locations => "PhotosCategoryLocations",
        SynologyPhotoCategory.Tags => "PhotosCategoryTags", _ => "PhotosCategoryVideos",
    });
    private string ShareTitle(SynologyPhotoShareScope scope) => _l.Get(scope switch
    { SynologyPhotoShareScope.WithMe => "PhotosSharedWithMe", SynologyPhotoShareScope.WithOthers => "PhotosSharedWithOthers", _ => "PhotosPhotoRequests" });
    private static Visibility Visible(bool value) => value ? Visibility.Visible : Visibility.Collapsed;

    private async void Library_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        var container = args.ItemContainer;
        var generation = _viewGeneration; var itemIndex = args.ItemIndex; var boundItem = args.Item;
        if (args.InRecycleQueue || args.Phase == 0)
        {
            if (_visibleRequests.Remove(container, out var previous)) previous.Cancel();
            if (FindChild<Image>(container) is { } previousImage) previousImage.Source = null;
            if (!args.InRecycleQueue) args.RegisterUpdateCallback(1, Library_ContainerContentChanging);
            return;
        }
        if (_disposed || !_windowVisible) return;
        if (args.Item is SynologyPhotoCell { Photo: { Thumbnail: not null } photo } cell && FindChild<Image>(container) is { } image)
        {
            using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_viewCancellation.Token);
            _visibleRequests[container] = cancellation;
            try
            {
                var bitmap = await _thumbnails.GetAsync(photo, cancellation.Token);
                if (!_disposed && !cancellation.IsCancellationRequested && ReferenceEquals(container.Content, cell)) image.Source = bitmap;
            }
            catch (OperationCanceledException) { }
            catch (Exception) { /* 单张缩略图失败保留可点击占位，原图预览拥有独立重试入口。 */ }
            finally
            { if (_visibleRequests.TryGetValue(container, out var current) && ReferenceEquals(current, cancellation)) _visibleRequests.Remove(container); }
        }
        if (!_disposed && _windowVisible && IsLoaded && generation == _viewGeneration &&
            ReferenceEquals(container.Content, boundItem) && itemIndex >= Math.Max(0, LibraryGrid.Items.Count - 12))
            await _model.LoadNextAsync(automatic: true);
    }
    private static T? FindChild<T>(DependencyObject parent) where T : DependencyObject
    {
        if (parent is T value) return value;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
            if (FindChild<T>(VisualTreeHelper.GetChild(parent, index)) is { } child) return child;
        return null;
    }
    private async void Library_ItemClick(object sender, ItemClickEventArgs args)
    { if (args.ClickedItem is SynologyPhotoCell cell) await OpenCellAsync(cell); }
    private async Task OpenCellAsync(SynologyPhotoCell cell)
    {
        if (_model.Deletion.IsBusy) return;
        if (cell.Photo is { } photo) await _model.Preview.OpenAsync(photo);
        else if (cell.Collection is { } collection) await _model.OpenCollectionAsync(collection);
        else if (cell.Shared is { AlbumId: not null } shared) await _model.OpenSharedAsync(shared);
    }
    private async void Sections_SelectionChanged(object sender, SelectionChangedEventArgs args)
    { if (_ready && !_rendering && Sections.SelectedIndex >= 0) await _model.SelectSectionAsync((SynologyPhotosSection)Sections.SelectedIndex); }
    private async void ShareScope_SelectionChanged(object sender, SelectionChangedEventArgs args)
    { if (_ready && !_rendering && ShareScopePicker.SelectedItem is SynologyPhotoShareChoice choice) await _model.SelectShareScopeAsync(choice.Scope); }
    private async void Search_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    { await _model.SearchAsync(args.QueryText); _displayedSearchText = _model.SearchText; sender.Text = _displayedSearchText; }
    private async void Month_SelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (!_ready || _rendering || MonthPicker.SelectedItem is not SynologyPhotoMonth month) return;
        await _model.JumpToMonthAsync(month);
        if (LibraryGrid.Items.Count > 0) LibraryGrid.ScrollIntoView(LibraryGrid.Items[0]);
    }
    private async void Category_Click(object sender, RoutedEventArgs args)
    { if (sender is Button { Tag: SynologyPhotoCategory category }) await _model.OpenCategoryAsync(category); }
    private async void Refresh_Click(object sender, RoutedEventArgs args) => await _model.RefreshAsync();
    private async void Back_Click(object sender, RoutedEventArgs args) => await _model.GoBackAsync();
    private async void Older_Click(object sender, RoutedEventArgs args) => await _model.LoadNextAsync();
    private async void Newer_Click(object sender, RoutedEventArgs args) => await _model.LoadPreviousAsync();
    private async void Review_Click(object sender, RoutedEventArgs args) => await _model.Deletion.ReviewAsync();
    private async void Retry_Click(object sender, RoutedEventArgs args)
    {
        if (_model.SelectedMonth is { } month && _model.Items.Count == 0) await _model.JumpToMonthAsync(month);
        else if (_model.HasLoaded && (_model.HasMore || _model.HasMoreCollections)) await _model.LoadNextAsync();
        else await _model.RefreshAsync();
    }
    private void CopyLink_Click(object sender, RoutedEventArgs args)
    {
        if (sender is not Button { Tag: SynologyPhotoSharedEntry { Url: { } url } } || url.Scheme != Uri.UriSchemeHttps || url.UserInfo.Length != 0) return;
        try { var data = new DataPackage(); data.SetText(url.AbsoluteUri); Clipboard.SetContent(data); ShowSaveMessage("PhotosLinkCopied", false); }
        catch (Exception) { ShowSaveMessage("PhotosCopyLinkFailed", true); }
    }
    private async void LibraryWheelChanged(object sender, PointerRoutedEventArgs args)
    {
        if (_model.HasPrevious && args.GetCurrentPoint(LibraryGrid).Properties.MouseWheelDelta > 0 && FindChild<ScrollViewer>(LibraryGrid) is { VerticalOffset: < 48 })
            await _model.LoadPreviousAsync(automatic: true);
    }
    private async void PageKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (_dialog is not null) return;
        if (_model.Preview.Photo is not null)
        {
            if (args.Key == VirtualKey.Escape) { _model.Preview.Close(); args.Handled = true; }
            else if (args.Key is VirtualKey.Left or VirtualKey.Right && _model.Preview.MediaSource is null)
            { await AdjacentAsync(args.Key == VirtualKey.Left ? -1 : 1); args.Handled = true; }
        }
        else if (args.Key == VirtualKey.Enter && LibraryGrid.SelectedItem is SynologyPhotoCell cell && args.OriginalSource is not TextBox)
        { await OpenCellAsync(cell); args.Handled = true; }
        else if (args.Key == VirtualKey.F5) { await _model.RefreshAsync(); args.Handled = true; }
    }
    public void Dispose()
    {
        if (_disposed) return;
        Suspend(); _disposed = true;
        _l.LanguageChanged -= LanguageChanged; _model.PropertyChanged -= ModelChanged;
        _model.ContentChanged -= RebuildGroups; _model.RequestChanged -= RequestChanged;
        _model.Preview.PropertyChanged -= PreviewChanged; _model.Deletion.PropertyChanged -= ModelChanged;
        ClosePlayer(); _model.Dispose(); _thumbnails.Dispose(); _cacheRegistration.Dispose();
        _viewCancellation.Cancel(); _viewCancellation.Dispose(); _groups.Clear(); _groupsByKey.Clear();
        Loaded -= PageLoaded; Unloaded -= PageUnloaded; KeyDown -= PageKeyDown;
        LibraryGrid.PointerWheelChanged -= LibraryWheelChanged;
    }
}
