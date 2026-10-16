using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.Domain;
using System.Collections.ObjectModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class TransferActivityPage : Page, IAsyncDisposable
{
    private readonly ForegroundTransferCoordinator _coordinator;
    private readonly WindowsTransferPickerService _transfers;
    private readonly string _profileId;
    private readonly DownloadStationActivityRefresher _downloadRefresher;
    private readonly FileStationActivityRefresher _fileRefresher;
    private readonly bool _canRefreshDownloadTasks;
    private readonly bool _canRefreshFileTasks;
    private readonly IFileBackgroundTaskRepository _fileRepository;
    private readonly Func<string, Task>? _openOriginalFolder;
    private IReadOnlyList<FileBackgroundTaskProgress> _pendingFileControls = [];
    private ContentDialog? _detailsDialog;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly ObservableCollection<ActivityPresentation> _presentations = [];
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private bool _isLoaded;
    private bool _isWindowVisible = true;
    private bool _disposed;

    internal TransferActivityPage(
        ForegroundTransferCoordinator coordinator,
        WindowsTransferPickerService transfers,
        string profileId,
        IDownloadStationRepository downloadStationRepository,
        IFileBackgroundTaskRepository fileBackgroundTaskRepository,
        Func<string, Task>? openOriginalFolder = null)
    {
        InitializeComponent();
        ActivityList.ItemsSource = _presentations;
        _coordinator = coordinator;
        _transfers = transfers;
        _profileId = profileId;
        _fileRepository = fileBackgroundTaskRepository;
        _openOriginalFolder = openOriginalFolder;
        _canRefreshDownloadTasks = downloadStationRepository.ProfileId.ToString() == profileId &&
            downloadStationRepository.Availability.Status ==
                DownloadStationAvailabilityStatus.Available &&
            downloadStationRepository.Availability.SupportedFeatures.Contains(
                DownloadStationReadFeature.Tasks);
        _canRefreshFileTasks = fileBackgroundTaskRepository.ProfileId.ToString() == profileId &&
            fileBackgroundTaskRepository.IsAvailable;
        _downloadRefresher = new DownloadStationActivityRefresher(
            downloadStationRepository,
            tasks => _coordinator.SyncDownloadStationTasks(
                downloadStationRepository.ProfileId,
                tasks));
        _fileRefresher = new FileStationActivityRefresher(
            fileBackgroundTaskRepository,
            tasks => _coordinator.SyncFileStationTasks(
                fileBackgroundTaskRepository.ProfileId,
                tasks));
        _timer.Tick += Timer_Tick;
        Loaded += TransferActivityPage_Loaded;
        Unloaded += TransferActivityPage_Unloaded;
        RenderActivities();
    }

    private async void TransferActivityPage_Loaded(object sender, RoutedEventArgs e)
    {
        _isLoaded = true;
        RenderActivities();
        _timer.Start();
        await UpdateNasRefreshLifecycleAsync();
        await RefreshFileOperationsAsync();
    }

    private async void TransferActivityPage_Unloaded(object sender, RoutedEventArgs e)
    {
        _isLoaded = false;
        _timer.Stop();
        await UpdateNasRefreshLifecycleAsync();
    }

    internal async Task SetWindowVisibleAsync(bool isVisible)
    {
        _isWindowVisible = isVisible;
        await UpdateNasRefreshLifecycleAsync();
    }

    internal bool RevealActivity(Guid id)
    {
        if (_disposed) return false;
        RenderActivities();
        var row = _presentations.FirstOrDefault(item => item.Activity.Id == id);
        if (row is null) return false;
        ActivityList.ScrollIntoView(row, ScrollIntoViewAlignment.Leading);
        ActivityList.UpdateLayout();
        (ActivityList.ContainerFromItem(row) as Control)?.Focus(FocusState.Programmatic);
        return true;
    }

    private async Task UpdateNasRefreshLifecycleAsync()
    {
        Task transition;
        await _lifecycleGate.WaitAsync();
        try
        {
            if (_disposed)
            {
                return;
            }
            if (_isLoaded && _isWindowVisible)
            {
                transition = Task.WhenAll(
                    _downloadRefresher.StartAsync(),
                    _fileRefresher.StartAsync());
            }
            else
            {
                transition = Task.WhenAll(
                    _downloadRefresher.StopAsync(),
                    _fileRefresher.StopAsync());
            }
        }
        finally
        {
            _lifecycleGate.Release();
        }
        // 只串行化状态切换，不持锁等待 NAS；隐藏/关闭才能立即撤销正在等待的读取。
        await transition;
        RenderActivities();
    }

    private void Timer_Tick(object? sender, object e) => RenderActivities();

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        await RefreshNasTasksAsync();
        RenderActivities();
    }

    private async void RefreshAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await RefreshNasTasksAsync();
        RenderActivities();
    }

    private async Task RefreshNasTasksAsync()
    {
        if (_disposed) return;
        await Task.WhenAll(_downloadRefresher.RefreshAsync(), _fileRefresher.RefreshAsync());
        await RefreshFileOperationsAsync();
    }

    private async Task RefreshFileOperationsAsync()
    {
        if (_disposed || _fileRepository.ProfileId.ToString() != _profileId) return;
        try { var pending = await _fileRepository.GetTaskOperationsAsync(); if (!_disposed) _pendingFileControls = pending; }
        catch { /* 保留已经显示的原操作；列表读取失败单独呈现。 */ }
        RenderActivities();
    }

    private async void DownloadLoadMore_Click(object sender, RoutedEventArgs e) => await LoadMoreNasTasksAsync(downloads: true);
    private async void FileLoadMore_Click(object sender, RoutedEventArgs e) => await LoadMoreNasTasksAsync(downloads: false);
    internal async Task LoadMoreNasTasksAsync(bool downloads)
    {
        if (_disposed || !_isLoaded || !_isWindowVisible) return;
        var reading = downloads ? _downloadRefresher.LoadMoreAsync() : _fileRefresher.LoadMoreAsync();
        RenderActivities();
        await reading;
        RenderActivities();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement
            {
                Tag: ForegroundTransferActivity
                {
                    State: ForegroundTransferState.Running or ForegroundTransferState.Paused,
                } activity,
            })
        {
            _transfers.Cancel(_profileId, activity.Id);
        }
    }

    private void Pause_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { Tag: ForegroundTransferActivity activity })
        {
            _coordinator.SetPaused(_profileId, activity.Id, activity.State != ForegroundTransferState.Paused);
            RenderActivities();
        }
    }

    private void RenderActivities()
    {
        if (_disposed)
        {
            return;
        }

        var items = _coordinator.GetActivities(_profileId).ToList();
        foreach (var pending in _pendingFileControls)
            if (!items.Any(a => a.SourceIdentifier == "file:" + pending.Change.Task.Id))
                items.Add(new(pending.Change.RequestId, _profileId, ForegroundTransferSource.NasFileStation, "file:" + pending.Change.Task.Id,
                    "", pending.Change.Task.Kind.ToString(), ForegroundTransferDirection.NasOperation, 0, 0,
                    ForegroundTransferState.ResultNeedsReview, null, pending.Change.Task.Kind));
        var ids = items.Select(item => item.Id).ToHashSet();
        for (var index = _presentations.Count - 1; index >= 0; index--)
            if (!ids.Contains(_presentations[index].Activity.Id)) _presentations.RemoveAt(index);
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            if (index >= _presentations.Count || _presentations[index].Activity.Id != item.Id)
            {
                var existing = _presentations.FirstOrDefault(row => row.Activity.Id == item.Id);
                if (existing is null) _presentations.Insert(index, ActivityPresentation.Create(item));
                else _presentations.Move(_presentations.IndexOf(existing), index);
            }
            if (_presentations[index].Activity != item) _presentations[index] = ActivityPresentation.Create(item);
        }
        ActivityList.Visibility = items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        EmptyState.Visibility = items.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        var downloadState = _downloadRefresher.State;
        var fileState = _fileRefresher.State;
        var isRefreshing = downloadState.IsRefreshing || fileState.IsRefreshing;
        RefreshButton.IsEnabled = (_canRefreshDownloadTasks || _canRefreshFileTasks) &&
            !isRefreshing;
        RefreshProgress.IsActive = isRefreshing;
        RefreshProgress.Visibility = isRefreshing
            ? Visibility.Visible
            : Visibility.Collapsed;
        DownloadRefreshErrorNotice.IsOpen = downloadState.HasFailed;
        FileRefreshErrorNotice.IsOpen = fileState.HasFailed;
        DownloadRefreshErrorNotice.Message = LocalizationService.Current.Get(
            downloadState.HasSnapshot
                ? "TransferActivityDownloadRefreshErrorPrevious"
                : "TransferActivityDownloadRefreshErrorInitial");
        FileRefreshErrorNotice.Message = LocalizationService.Current.Get(
            fileState.HasSnapshot
                ? "TransferActivityFileRefreshErrorPrevious"
                : "TransferActivityFileRefreshErrorInitial");
        DownloadTruncatedNotice.IsOpen = downloadState.IsTruncated;
        FileTruncatedNotice.IsOpen = fileState.IsTruncated;
        DownloadTruncatedNotice.Message = LocalizationService.Current.Format("TransferActivityDownloadPageSummary", downloadState.DisplayedTaskCount,
            downloadState.SourceTotal?.ToString("N0", System.Globalization.CultureInfo.CurrentCulture) ?? LocalizationService.Current.Get("DownloadStationValueUnavailable"));
        FileTruncatedNotice.Message = LocalizationService.Current.Format("TransferActivityFilePageSummary", fileState.DisplayedTaskCount, fileState.SourceTotal);
        DownloadLoadMoreButton.IsEnabled = _downloadRefresher.CanLoadMore;
        FileLoadMoreButton.IsEnabled = _fileRefresher.CanLoadMore;
        DownloadUnavailableNotice.IsOpen = !_canRefreshDownloadTasks && _canRefreshFileTasks;
        FileUnavailableNotice.IsOpen = _canRefreshDownloadTasks && !_canRefreshFileTasks;
        NasUnavailableNotice.IsOpen = !_canRefreshDownloadTasks && !_canRefreshFileTasks;
    }

    public async ValueTask DisposeAsync()
    {
        await _lifecycleGate.WaitAsync();
        try
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _detailsDialog?.Hide();
            _timer.Stop();
            _timer.Tick -= Timer_Tick;
            Loaded -= TransferActivityPage_Loaded;
            Unloaded -= TransferActivityPage_Unloaded;
            await Task.WhenAll(_downloadRefresher.DisposeAsync().AsTask(), _fileRefresher.DisposeAsync().AsTask());
            _presentations.Clear();
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private sealed class ActivityPresentation
    {
        public required ForegroundTransferActivity Activity { get; init; }
        public required string DisplayName { get; init; }
        public required string SourceText { get; init; }
        public required string DirectionText { get; init; }
        public required double Maximum { get; init; }
        public required double Value { get; init; }
        public required bool IsIndeterminate { get; init; }
        public required string StatusText { get; init; }
        public required string SpeedText { get; init; }
        public required Visibility SpeedVisibility { get; init; }
        public required string PauseText { get; init; }
        public required string PauseAutomationName { get; init; }
        public required Visibility PauseVisibility { get; init; }
        public required string CancelAutomationName { get; init; }
        public required Visibility CancelVisibility { get; init; }
        public required Visibility ProgressVisibility { get; init; }

        public static ActivityPresentation Create(ForegroundTransferActivity activity)
        {
            var localization = LocalizationService.Current;
            var isFileTask = activity.Source == ForegroundTransferSource.NasFileStation;
            var status = activity.State switch
            {
                ForegroundTransferState.Running when isFileTask =>
                    activity.ProgressFraction is { } progress
                        ? localization.Format("TransferActivityFileProgress", progress)
                        : localization.Get("TransferActivityFileRunning"),
                ForegroundTransferState.Running when activity.TotalBytes == 0 =>
                    localization.Format("TransferActivityUnknownProgress", activity.BytesTransferred),
                ForegroundTransferState.Running => localization.Format(
                    activity.Direction == ForegroundTransferDirection.Upload
                        ? "TransferActivityUploadProgress"
                        : "TransferActivityProgress",
                    activity.BytesTransferred,
                    activity.TotalBytes),
                ForegroundTransferState.Paused when activity.Source == ForegroundTransferSource.App =>
                    localization.Format("TransferActivityPausedProgress", activity.BytesTransferred),
                ForegroundTransferState.Paused => localization.Get("TransferActivityPaused"),
                ForegroundTransferState.Completed => localization.Get(
                    activity.Direction == ForegroundTransferDirection.Upload
                        ? "TransferActivityUploadCompleted"
                        : "TransferActivityCompleted"),
                ForegroundTransferState.Cancelled => localization.Get("TransferActivityCancelled"),
                ForegroundTransferState.CancelledBeforeSubmission =>
                    localization.Get("TransferActivityCancelledBeforeSubmission"),
                ForegroundTransferState.ResultNeedsReview when isFileTask => localization.Get("FileTaskPending"),
                ForegroundTransferState.ResultNeedsReview =>
                    localization.Get("TransferActivityUploadNeedsReview"),
                ForegroundTransferState.EndedNeedsReview =>
                    localization.Get("TransferActivityFileEndedNeedsReview"),
                ForegroundTransferState.Failed when activity.ItemResults.Any(item => item.State == ForegroundTransferItemState.Completed) =>
                    localization.Get(activity.Direction == ForegroundTransferDirection.Upload ? "TransferUploadPartial" : "FileStructureDownloadPartial"),
                ForegroundTransferState.Failed => localization.Get(
                    activity.Direction == ForegroundTransferDirection.Upload
                        ? "TransferActivityUploadFailed"
                        : "TransferActivityFailed"),
                _ => localization.Get("TransferActivityFailed"),
            };
            return new ActivityPresentation
            {
                Activity = activity,
                DisplayName = isFileTask
                    ? localization.Get(FileTaskNameKey(activity.FileTaskKind))
                    : activity.DisplayName,
                SourceText = localization.Get(activity.Source switch
                {
                    ForegroundTransferSource.App => "TransferActivitySourceApp",
                    ForegroundTransferSource.NasFileStation => "TransferActivitySourceFileStation",
                    _ => "TransferActivitySourceNas",
                }),
                DirectionText = localization.Get(isFileTask
                    ? "TransferActivityDirectionNasOperation"
                    : activity.Direction == ForegroundTransferDirection.Upload
                        ? "TransferActivityDirectionUpload"
                        : "TransferActivityDirectionDownload"),
                Maximum = isFileTask ? 1 : Math.Max(1, activity.TotalBytes),
                Value = isFileTask ? activity.ProgressFraction ?? 0 : activity.BytesTransferred,
                IsIndeterminate = activity.State == ForegroundTransferState.Running &&
                    (isFileTask
                        ? activity.ProgressFraction is null
                        : activity.TotalBytes == 0),
                StatusText = status,
                SpeedText = localization.Format("TransferActivitySpeed", activity.BytesPerSecond / 1024),
                SpeedVisibility = activity.Source == ForegroundTransferSource.App && activity.State == ForegroundTransferState.Running
                    ? Visibility.Visible : Visibility.Collapsed,
                PauseText = localization.Get(activity.State == ForegroundTransferState.Paused ? "TransferActivityResume" : "TransferActivityPause"),
                PauseAutomationName = localization.Format(activity.State == ForegroundTransferState.Paused
                    ? "TransferActivityResumeName" : "TransferActivityPauseName", activity.DisplayName),
                PauseVisibility = activity.CanPause ? Visibility.Visible : Visibility.Collapsed,
                CancelAutomationName = localization.Format(
                    "TransferActivityCancelAutomationName",
                    activity.DisplayName),
                CancelVisibility = activity.Source == ForegroundTransferSource.App &&
                    activity.State is ForegroundTransferState.Running or ForegroundTransferState.Paused
                    ? Visibility.Visible
                    : Visibility.Collapsed,
                ProgressVisibility = isFileTask &&
                    activity.State == ForegroundTransferState.EndedNeedsReview
                    ? Visibility.Collapsed
                    : Visibility.Visible,
            };
        }

        public static string FileTaskNameKey(FileBackgroundTaskKind? kind) => kind switch
        {
            FileBackgroundTaskKind.CopyOrMove => "TransferActivityFileCopyMove",
            FileBackgroundTaskKind.Delete => "TransferActivityFileDelete",
            FileBackgroundTaskKind.Compress => "TransferActivityFileCompress",
            FileBackgroundTaskKind.Extract => "TransferActivityFileExtract",
            _ => "TransferActivityFileTask",
        };
    }
}
