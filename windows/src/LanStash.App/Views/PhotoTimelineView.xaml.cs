using System.ComponentModel;
using System.Globalization;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Photos;
using LanStash.App.Features.Photos.Timeline;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
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
    private Func<PhotoItem, bool>? _canSaveMultiple;
    private Func<IReadOnlyList<PhotoItem>, Task>? _saveMultiple;
    private Func<PhotoItem, IReadOnlyList<PhotoItem>, Task>? _open;
    private Func<PhotoItem, bool>? _canMove;
    private Func<PhotoItem, bool>? _canCopy;
    private Func<PhotoItem, Task>? _move;
    private Func<IReadOnlyList<PhotoItem>, Task>? _copyMultiple;
    private Func<IReadOnlyList<PhotoItem>, Task>? _moveMultiple;
    private Func<PhotoItem, bool>? _canMoveToRecycle;
    private Func<PhotoItem, Task>? _moveToRecycle;
    private Func<IReadOnlyList<PhotoItem>, Task>? _moveMultipleToRecycle;
    private Func<PhotoItem, bool>? _canRestore;
    private Func<PhotoItem, Task>? _restore;
    private Func<IReadOnlyList<PhotoItem>, Task>? _restoreMultiple;
    private Func<PhotoItem, bool>? _canShare;
    private Func<PhotoItem, Task>? _share;
    private Func<PhotoItem, bool>? _canManageShareLinks;
    private Func<PhotoItem, Task>? _manageShareLinks;
    private CancellationTokenSource _thumbnailCancellation = new();
    private bool _syncingControls;
    private bool _syncingBatchSelection;
    private PhotoBatchSelectionOperation _batchSelectionOperation;
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
        Func<PhotoItem, bool>? canSaveMultiple = null,
        Func<IReadOnlyList<PhotoItem>, Task>? saveMultiple = null,
        Func<PhotoItem, IReadOnlyList<PhotoItem>, Task>? open = null,
        Func<PhotoItem, bool>? canCopy = null,
        Func<PhotoItem, bool>? canMove = null,
        Func<PhotoItem, Task>? move = null,
        Func<IReadOnlyList<PhotoItem>, Task>? copyMultiple = null,
        Func<IReadOnlyList<PhotoItem>, Task>? moveMultiple = null,
        Func<PhotoItem, bool>? canMoveToRecycle = null,
        Func<PhotoItem, Task>? moveToRecycle = null,
        Func<IReadOnlyList<PhotoItem>, Task>? moveMultipleToRecycle = null,
        Func<PhotoItem, bool>? canRestore = null,
        Func<PhotoItem, Task>? restore = null,
        Func<IReadOnlyList<PhotoItem>, Task>? restoreMultiple = null,
        Func<PhotoItem, bool>? canShare = null,
        Func<PhotoItem, Task>? share = null,
        Func<PhotoItem, bool>? canManageShareLinks = null,
        Func<PhotoItem, Task>? manageShareLinks = null)
    {
        _source = source;
        _thumbnails = thumbnails;
        _save = save;
        _canSaveMultiple = canSaveMultiple;
        _saveMultiple = saveMultiple;
        _open = open;
        _canCopy = canCopy;
        _canMove = canMove;
        _move = move;
        _copyMultiple = copyMultiple;
        _moveMultiple = moveMultiple;
        _canMoveToRecycle = canMoveToRecycle;
        _moveToRecycle = moveToRecycle;
        _moveMultipleToRecycle = moveMultipleToRecycle;
        _canRestore = canRestore;
        _restore = restore;
        _restoreMultiple = restoreMultiple;
        _canShare = canShare;
        _share = share;
        _canManageShareLinks = canManageShareLinks;
        _manageShareLinks = manageShareLinks;
    }

    internal async Task ShowAsync(PhotoSpace space)
    {
        if (_disposed || _source is null) return;
        CancelThumbnailRequests();
        _viewModel.Activate(_source, space);
        ExitRecycleSelection();
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
        ExitRecycleSelection();
        await _viewModel.RefreshAsync();
        LocalizeGroupTitles();
        UpdateState();
    }

    internal void HideTimeline()
    {
        ExitRecycleSelection();
        _viewModel.Cancel();
        CancelThumbnailRequests();
    }

    internal bool CanSaveSelected =>
        _batchSelectionOperation == PhotoBatchSelectionOperation.None && TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
        _viewModel.CanSave(entry.Item);

    internal bool CanOpenSelected =>
        _batchSelectionOperation == PhotoBatchSelectionOperation.None && TimelineGrid.SelectedItem is PhotoTimelineEntry entry && CanOpen(entry.Item);

    internal bool CanShareSelected =>
        _batchSelectionOperation == PhotoBatchSelectionOperation.None &&
        TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
        _canShare?.Invoke(entry.Item) == true;

    internal bool CanManageShareLinksSelected =>
        _batchSelectionOperation == PhotoBatchSelectionOperation.None &&
        TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
        _canManageShareLinks?.Invoke(entry.Item) == true;

    internal bool CanRestoreSelected =>
        _batchSelectionOperation == PhotoBatchSelectionOperation.None && TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
        _canRestore?.Invoke(entry.Item) == true;

    internal bool CanMoveSelected =>
        _batchSelectionOperation == PhotoBatchSelectionOperation.None && TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
        _canMove?.Invoke(entry.Item) == true;

    internal bool CanMoveSelectedToRecycle =>
        _batchSelectionOperation == PhotoBatchSelectionOperation.None && TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
        _canMoveToRecycle?.Invoke(entry.Item) == true;

    internal bool HasSelectedItem(PhotoItem item) =>
        TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
        HasSameRevision(entry.Item, item);

    internal bool HasSelectedBatchItems(
        IReadOnlyList<PhotoItem> items,
        PhotoBatchSelectionOperation operation)
    {
        var selected = SelectedBatchItems();
        return _batchSelectionOperation == operation && selected.Count == items.Count &&
            selected.All(item => items.Any(candidate => HasSameRevision(candidate, item)));
    }

    internal bool HasSelectedRecycleItems(IReadOnlyList<PhotoItem> items) =>
        HasSelectedBatchItems(items, PhotoBatchSelectionOperation.Recycle);

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

    internal async Task ShareSelectedAsync()
    {
        if (!CanShareSelected ||
            TimelineGrid.SelectedItem is not PhotoTimelineEntry entry ||
            _share is null)
        {
            return;
        }
        await _share(entry.Item);
    }

    internal async Task ManageShareLinksSelectedAsync()
    {
        if (!CanManageShareLinksSelected ||
            TimelineGrid.SelectedItem is not PhotoTimelineEntry entry ||
            _manageShareLinks is null)
        {
            return;
        }
        await _manageShareLinks(entry.Item);
    }

    internal async Task RestoreSelectedAsync()
    {
        if (TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
            _canRestore?.Invoke(entry.Item) == true && _restore is not null)
            await _restore(entry.Item);
    }

    internal async Task MoveSelectedAsync()
    {
        if (TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
            _canMove?.Invoke(entry.Item) == true && _move is not null)
            await _move(entry.Item);
    }

    internal async Task MoveSelectedToRecycleAsync()
    {
        if (TimelineGrid.SelectedItem is PhotoTimelineEntry entry &&
            _canMoveToRecycle?.Invoke(entry.Item) == true && _moveToRecycle is not null)
            await _moveToRecycle(entry.Item);
    }

    internal void ClearSelection() => TimelineGrid.SelectedItem = null;

    internal void ExitBatchSelection()
    {
        _syncingBatchSelection = true;
        TimelineGrid.SelectedItems.Clear();
        TimelineGrid.SelectionMode = ListViewSelectionMode.Single;
        _syncingBatchSelection = false;
        _batchSelectionOperation = PhotoBatchSelectionOperation.None;
        RecycleBatchStatus.IsOpen = false;
        UpdateState();
    }

    internal void ExitRecycleSelection() => ExitBatchSelection();

    internal void ShowRecycleBatchSummary(
        FileRecycleBatchSummary summary,
        FileRecycleOperation operation = FileRecycleOperation.MoveToRecycle)
    {
        RecycleBatchStatus.Severity = summary.NeedsReviewCount > 0 ||
            summary.FailedCount > 0 || summary.CancelledCount > 0 ||
            summary.NotStartedCount > 0
            ? InfoBarSeverity.Warning
            : InfoBarSeverity.Success;
        RecycleBatchStatus.Message = FileRecycleBatchDialogContent.FormatSummary(
            LocalizationService.Current,
            summary,
            operation);
        RecycleBatchStatus.IsOpen = true;
    }

    internal void ShowMoveBatchSummary(FileCopyMoveBatchSummary summary)
    {
        RecycleBatchStatus.Severity = summary.NeedsReviewCount > 0 ||
            summary.FailedCount > 0 || summary.CancelledCount > 0 ||
            summary.NotStartedCount > 0
            ? InfoBarSeverity.Warning
            : InfoBarSeverity.Success;
        RecycleBatchStatus.Message = FilesPage.FormatBatchCopyMoveSummary(
            LocalizationService.Current,
            summary,
            FileCopyMoveOperation.Move);
        RecycleBatchStatus.IsOpen = true;
    }

    internal void RefreshActionState() => UpdateState();

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();
    private void JumpMenu_Opening(object sender, object e)
    {
        JumpMenu.Items.Clear();
        var localization = LocalizationService.Current;
        var culture = CultureInfo.GetCultureInfo(localization.ResolvedLanguage);
        foreach (var year in _viewModel.Groups
                     .Where(group => group.Month is not null)
                     .GroupBy(group => group.Month!.Value.Year)
                     .OrderByDescending(group => group.Key))
        {
            var yearMenu = new MenuFlyoutSubItem
            {
                Text = localization.Format("PhotoTimelineJumpYear", year.Key),
                MinHeight = 44,
            };
            foreach (var group in year.OrderByDescending(item => item.Month))
            {
                var item = new MenuFlyoutItem
                {
                    Text = group.Month!.Value.ToString("MMMM", culture),
                    Tag = group,
                    MinHeight = 44,
                };
                AutomationProperties.SetName(
                    item,
                    localization.Format("PhotoTimelineJumpMonthAutomationName", group.Title));
                item.Click += JumpMonth_Click;
                yearMenu.Items.Add(item);
            }
            JumpMenu.Items.Add(yearMenu);
        }
        var unknown = _viewModel.Groups.FirstOrDefault(group => group.Month is null);
        if (unknown is not null)
        {
            var item = new MenuFlyoutItem
            {
                Text = unknown.Title,
                Tag = unknown,
                MinHeight = 44,
            };
            AutomationProperties.SetName(
                item,
                localization.Format("PhotoTimelineJumpMonthAutomationName", unknown.Title));
            item.Click += JumpMonth_Click;
            JumpMenu.Items.Add(item);
        }
    }

    private void JumpMonth_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not MenuFlyoutItem { Tag: PhotoTimelineGroup group } ||
            group.Items.FirstOrDefault() is not { } entry)
        {
            return;
        }
        TimelineGrid.ScrollIntoView(entry, ScrollIntoViewAlignment.Leading);
        TimelineGrid.UpdateLayout();
        if (FocusJumpTarget(entry))
        {
            return;
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            TimelineGrid.UpdateLayout();
            if (!FocusJumpTarget(entry))
            {
                TimelineGrid.Focus(FocusState.Keyboard);
            }
        });
    }

    private bool FocusJumpTarget(PhotoTimelineEntry entry) =>
        TimelineGrid.ContainerFromItem(entry) is GridViewItem container &&
        container.Focus(FocusState.Keyboard);

    private void Cancel_Click(object sender, RoutedEventArgs e) { _viewModel.Cancel(); UpdateState(); }
    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_syncingControls)
        {
            ExitRecycleSelection();
            _viewModel.Query = SearchBox.Text;
        }
        LocalizeGroupTitles(); UpdateState();
    }
    private void FilterPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_syncingControls && FilterPicker.SelectedItem is ComboBoxItem { Tag: string value } && Enum.TryParse<PhotoTimelineFilter>(value, out var filter))
        { ExitRecycleSelection(); _viewModel.SetFilter(filter); LocalizeGroupTitles(); UpdateState(); }
    }
    private void ClearFilters_Click(object sender, RoutedEventArgs e) { SearchBox.Text = string.Empty; FilterPicker.SelectedIndex = 0; }
    private void TimelineGrid_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_batchSelectionOperation != PhotoBatchSelectionOperation.None &&
            !_syncingBatchSelection)
        {
            var rejected = false;
            var rejectedForLimit = false;
            foreach (var added in e.AddedItems.OfType<PhotoTimelineEntry>())
            {
                if (!CanSelectForBatch(added.Item, _batchSelectionOperation) ||
                    TimelineGrid.SelectedItems.Count > FileCopyMoveBatchViewModel.MaximumItemCount)
                {
                    rejectedForLimit |= TimelineGrid.SelectedItems.Count >
                        FileRecycleBatchViewModel.MaximumItemCount;
                    _syncingBatchSelection = true;
                    TimelineGrid.SelectedItems.Remove(added);
                    _syncingBatchSelection = false;
                    rejected = true;
                }
            }
            ShowRecycleSelectionMessage(
                rejected
                    ? rejectedForLimit
                        ? SelectionLimitResource(_batchSelectionOperation)
                        : SelectionInvalidResource(_batchSelectionOperation)
                    : SelectionCountResource(_batchSelectionOperation),
                rejected ? InfoBarSeverity.Warning : InfoBarSeverity.Informational,
                rejected ? null : TimelineGrid.SelectedItems.Count);
        }
        UpdateState();
    }
    private async void Open_Click(object sender, RoutedEventArgs e)
    { await OpenSelectedAsync(); }
    private async void Save_Click(object sender, RoutedEventArgs e)
    { await SaveSelectedAsync(); }
    private async void ShareLink_Click(object sender, RoutedEventArgs e)
    { await ShareSelectedAsync(); }
    private async void ManageShareLinks_Click(object sender, RoutedEventArgs e)
    { await ManageShareLinksSelectedAsync(); }
    private void SaveMultiple_Click(object sender, RoutedEventArgs e) =>
        EnterBatchSelection(PhotoBatchSelectionOperation.Save);
    private async void SaveSelectedItems_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedBatchItems();
        if (_batchSelectionOperation == PhotoBatchSelectionOperation.Save &&
            items.Count is > 0 and <= BoundedFileDownloadBatch.MaximumFileCount &&
            _saveMultiple is not null)
        {
            await _saveMultiple(items);
        }
    }
    private async void Move_Click(object sender, RoutedEventArgs e)
    { await MoveSelectedAsync(); }
    private async void Restore_Click(object sender, RoutedEventArgs e)
    { await RestoreSelectedAsync(); }
    private async void MoveToRecycle_Click(object sender, RoutedEventArgs e)
    { await MoveSelectedToRecycleAsync(); }
    private void CopyMultiple_Click(object sender, RoutedEventArgs e) =>
        EnterBatchSelection(PhotoBatchSelectionOperation.Copy);
    private async void CopySelectedItems_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedBatchItems();
        if (_batchSelectionOperation == PhotoBatchSelectionOperation.Copy &&
            items.Count is > 0 and <= FileCopyMoveBatchViewModel.MaximumItemCount &&
            _copyMultiple is not null)
        {
            await _copyMultiple(items);
        }
    }
    private void MoveMultiple_Click(object sender, RoutedEventArgs e) =>
        EnterBatchSelection(PhotoBatchSelectionOperation.Move);
    private async void MoveSelectedItems_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedBatchItems();
        if (_batchSelectionOperation == PhotoBatchSelectionOperation.Move &&
            items.Count is > 0 and <= FileCopyMoveBatchViewModel.MaximumItemCount &&
            _moveMultiple is not null)
        {
            await _moveMultiple(items);
        }
    }
    private void MoveMultipleToRecycle_Click(object sender, RoutedEventArgs e)
        => EnterBatchSelection(PhotoBatchSelectionOperation.Recycle);
    private void RestoreMultiple_Click(object sender, RoutedEventArgs e)
        => EnterBatchSelection(PhotoBatchSelectionOperation.Restore);

    private void EnterBatchSelection(PhotoBatchSelectionOperation operation)
    {
        if (_disposed || _viewModel.Phase == PhotoTimelinePhase.Scanning ||
            !_viewModel.Groups.SelectMany(group => group.Items)
                .Any(entry => CanSelectForBatch(entry.Item, operation)))
        {
            return;
        }
        var selected = TimelineGrid.SelectedItem as PhotoTimelineEntry;
        _syncingBatchSelection = true;
        TimelineGrid.SelectedItems.Clear();
        TimelineGrid.SelectionMode = ListViewSelectionMode.Multiple;
        if (selected is not null && CanSelectForBatch(selected.Item, operation))
        {
            TimelineGrid.SelectedItems.Add(selected);
        }
        _syncingBatchSelection = false;
        _batchSelectionOperation = operation;
        ShowRecycleSelectionMessage(
            SelectionCountResource(operation),
            InfoBarSeverity.Informational,
            TimelineGrid.SelectedItems.Count);
        UpdateState();
    }
    private async void MoveSelectedToRecycle_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedBatchItems();
        if (_batchSelectionOperation == PhotoBatchSelectionOperation.Recycle &&
            items.Count is > 0 and <= FileRecycleBatchViewModel.MaximumItemCount &&
            _moveMultipleToRecycle is not null)
        {
            await _moveMultipleToRecycle(items);
        }
    }
    private async void RestoreSelectedItems_Click(object sender, RoutedEventArgs e)
    {
        var items = SelectedBatchItems();
        if (_batchSelectionOperation == PhotoBatchSelectionOperation.Restore &&
            items.Count is > 0 and <= FileRecycleBatchViewModel.MaximumItemCount &&
            _restoreMultiple is not null)
        {
            await _restoreMultiple(items);
        }
    }
    private void CancelBatchSelection_Click(object sender, RoutedEventArgs e) => ExitBatchSelection();
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
        JumpButton.IsEnabled = hasVisible &&
            _batchSelectionOperation == PhotoBatchSelectionOperation.None;
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
        ShareLinkButton.IsEnabled = CanShareSelected;
        ManageShareLinksButton.IsEnabled = CanManageShareLinksSelected;
        MoveButton.IsEnabled = CanMoveSelected;
        MoveButton.Visibility = CanMoveSelected ? Visibility.Visible : Visibility.Collapsed;
        MoveToRecycleButton.Content = LocalizationService.Current.Get("FileRecycleMoveAction");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            MoveToRecycleButton,
            LocalizationService.Current.Get(
                "FileRecycleMoveToRecycle.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        MoveToRecycleButton.IsEnabled = CanMoveSelectedToRecycle;
        MoveToRecycleButton.Visibility = CanMoveSelectedToRecycle
            ? Visibility.Visible
            : Visibility.Collapsed;
        var hasCopyBatchCandidates = _viewModel.Phase != PhotoTimelinePhase.Scanning &&
            _viewModel.Groups.SelectMany(group => group.Items)
                .Any(entry => _canCopy?.Invoke(entry.Item) == true);
        var hasSaveBatchCandidates = _viewModel.Phase != PhotoTimelinePhase.Scanning &&
            _viewModel.Groups.SelectMany(group => group.Items)
                .Any(entry => _canSaveMultiple?.Invoke(entry.Item) == true);
        var hasMoveBatchCandidates = _viewModel.Phase != PhotoTimelinePhase.Scanning &&
            _viewModel.Groups.SelectMany(group => group.Items)
                .Any(entry => _canMove?.Invoke(entry.Item) == true);
        var hasRecycleBatchCandidates = _viewModel.Phase != PhotoTimelinePhase.Scanning &&
            _viewModel.Groups.SelectMany(group => group.Items)
                .Any(entry => _canMoveToRecycle?.Invoke(entry.Item) == true);
        var hasRestoreBatchCandidates = _viewModel.Phase != PhotoTimelinePhase.Scanning &&
            _viewModel.Groups.SelectMany(group => group.Items)
                .Any(entry => _canRestore?.Invoke(entry.Item) == true);
        var localization = LocalizationService.Current;
        var isSelectingSave = _batchSelectionOperation == PhotoBatchSelectionOperation.Save;
        var isSelectingMove = _batchSelectionOperation == PhotoBatchSelectionOperation.Move;
        var isSelectingCopy = _batchSelectionOperation == PhotoBatchSelectionOperation.Copy;
        var isSelectingRecycle = _batchSelectionOperation == PhotoBatchSelectionOperation.Recycle;
        var isSelectingRestore = _batchSelectionOperation == PhotoBatchSelectionOperation.Restore;
        var isSelectingBatch = _batchSelectionOperation != PhotoBatchSelectionOperation.None;
        SaveMultipleButton.Visibility = !isSelectingBatch && hasSaveBatchCandidates
            ? Visibility.Visible
            : Visibility.Collapsed;
        SaveMultipleButton.IsEnabled = !isSelectingBatch && hasSaveBatchCandidates;
        SaveSelectedItemsButton.Visibility = isSelectingSave
            ? Visibility.Visible
            : Visibility.Collapsed;
        SaveSelectedItemsButton.IsEnabled = TimelineGrid.SelectedItems.Count is > 0 and <=
            BoundedFileDownloadBatch.MaximumFileCount;
        CopyMultipleButton.Visibility = !isSelectingBatch && hasCopyBatchCandidates
            ? Visibility.Visible
            : Visibility.Collapsed;
        CopyMultipleButton.IsEnabled = !isSelectingBatch && hasCopyBatchCandidates;
        CopySelectedItemsButton.Visibility = isSelectingCopy
            ? Visibility.Visible
            : Visibility.Collapsed;
        CopySelectedItemsButton.IsEnabled = TimelineGrid.SelectedItems.Count is > 0 and <=
            FileCopyMoveBatchViewModel.MaximumItemCount;
        MoveMultipleButton.Visibility = !isSelectingBatch && hasMoveBatchCandidates
            ? Visibility.Visible
            : Visibility.Collapsed;
        MoveMultipleButton.IsEnabled = !isSelectingBatch && hasMoveBatchCandidates;
        MoveSelectedItemsButton.Visibility = isSelectingMove
            ? Visibility.Visible
            : Visibility.Collapsed;
        MoveSelectedItemsButton.IsEnabled = TimelineGrid.SelectedItems.Count is > 0 and <=
            FileCopyMoveBatchViewModel.MaximumItemCount;
        MoveMultipleToRecycleButton.Content = localization.Get("FileRecycleBatchMoveMultiple.Label");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            MoveMultipleToRecycleButton,
            localization.Get("FileRecycleBatchMoveMultiple.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        MoveSelectedToRecycleButton.Content = localization.Get("FileRecycleBatchMoveSelected.Label");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            MoveSelectedToRecycleButton,
            localization.Get("FileRecycleBatchMoveSelected.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        CancelRecycleSelectionButton.Content = localization.Get("FileBrowserCancelDownloadSelection.Label");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            CancelRecycleSelectionButton,
            localization.Get("FileBrowserCancelDownloadSelection.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
        MoveMultipleToRecycleButton.Visibility = !isSelectingBatch && hasRecycleBatchCandidates
            ? Visibility.Visible
            : Visibility.Collapsed;
        MoveMultipleToRecycleButton.IsEnabled = !isSelectingBatch && hasRecycleBatchCandidates;
        MoveSelectedToRecycleButton.Visibility = isSelectingRecycle
            ? Visibility.Visible
            : Visibility.Collapsed;
        MoveSelectedToRecycleButton.IsEnabled = TimelineGrid.SelectedItems.Count is > 0 and <=
            FileRecycleBatchViewModel.MaximumItemCount;
        RestoreMultipleButton.Visibility = !isSelectingBatch && hasRestoreBatchCandidates
            ? Visibility.Visible
            : Visibility.Collapsed;
        RestoreMultipleButton.IsEnabled = !isSelectingBatch && hasRestoreBatchCandidates;
        RestoreSelectedItemsButton.Visibility = isSelectingRestore
            ? Visibility.Visible
            : Visibility.Collapsed;
        RestoreSelectedItemsButton.IsEnabled = TimelineGrid.SelectedItems.Count is > 0 and <=
            FileRecycleBatchViewModel.MaximumItemCount;
        CancelRecycleSelectionButton.Visibility = isSelectingBatch
            ? Visibility.Visible
            : Visibility.Collapsed;
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

    private IReadOnlyList<PhotoItem> SelectedBatchItems() =>
        TimelineGrid.SelectedItems
            .OfType<PhotoTimelineEntry>()
            .Select(entry => entry.Item)
            .ToArray();

    internal void ShowRecycleSelectionMessage(
        string resourceKey,
        InfoBarSeverity severity,
        object? argument = null)
    {
        RecycleBatchStatus.Severity = severity;
        RecycleBatchStatus.Message = argument is null
            ? LocalizationService.Current.Get(resourceKey)
            : LocalizationService.Current.Format(resourceKey, argument);
        RecycleBatchStatus.IsOpen = true;
    }

    private bool CanSelectForBatch(
        PhotoItem item,
        PhotoBatchSelectionOperation operation) => operation switch
        {
            PhotoBatchSelectionOperation.Save => _canSaveMultiple?.Invoke(item) == true,
            PhotoBatchSelectionOperation.Copy => _canCopy?.Invoke(item) == true,
            PhotoBatchSelectionOperation.Move => _canMove?.Invoke(item) == true,
            PhotoBatchSelectionOperation.Recycle => _canMoveToRecycle?.Invoke(item) == true,
            PhotoBatchSelectionOperation.Restore => _canRestore?.Invoke(item) == true,
            _ => false,
        };

    private static string SelectionCountResource(PhotoBatchSelectionOperation operation) =>
        operation switch
        {
            PhotoBatchSelectionOperation.Save => "FileDownloadBatchSelectionCountMessage",
            PhotoBatchSelectionOperation.Restore => "FileRestoreBatchSelectionCount",
            PhotoBatchSelectionOperation.Copy or PhotoBatchSelectionOperation.Move =>
                "FileCopyMoveBatchSelectionCount",
            _ => "FileRecycleBatchSelectionCount",
        };

    private static string SelectionLimitResource(PhotoBatchSelectionOperation operation) =>
        operation switch
        {
            PhotoBatchSelectionOperation.Save => "FileDownloadBatchSelectionLimitMessage",
            PhotoBatchSelectionOperation.Restore => "FileRestoreBatchSelectionLimit",
            PhotoBatchSelectionOperation.Copy or PhotoBatchSelectionOperation.Move =>
                "FileCopyMoveBatchSelectionLimit",
            _ => "FileRecycleBatchSelectionLimit",
        };

    private static string SelectionInvalidResource(PhotoBatchSelectionOperation operation) =>
        operation switch
        {
            PhotoBatchSelectionOperation.Save => "PhotoSaveBatchSelectionInvalid",
            PhotoBatchSelectionOperation.Copy => "PhotoCopyBatchSelectionInvalid",
            PhotoBatchSelectionOperation.Move => "PhotoMoveBatchSelectionInvalid",
            PhotoBatchSelectionOperation.Restore => "PhotoRestoreBatchSelectionInvalid",
            _ => "PhotoRecycleBatchSelectionInvalid",
        };

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
        foreach (var request in _thumbnailRequests.Values) { request.Cancel(); request.Dispose(); }
        _thumbnailRequests.Clear();
    }

    public void Dispose()
    {
        if (_disposed) return; _disposed = true; _viewModel.PropertyChanged -= ViewModel_PropertyChanged;
        CancelThumbnailRequests(); _thumbnailCancellation.Dispose(); _viewModel.Dispose();
    }
}
