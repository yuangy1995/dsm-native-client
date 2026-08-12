using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.Domain;
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
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private bool _isLoaded;
    private bool _isWindowVisible = true;
    private bool _disposed;

    internal TransferActivityPage(
        ForegroundTransferCoordinator coordinator,
        WindowsTransferPickerService transfers,
        string profileId,
        IDownloadStationRepository downloadStationRepository,
        IFileBackgroundTaskRepository fileBackgroundTaskRepository)
    {
        InitializeComponent();
        _coordinator = coordinator;
        _transfers = transfers;
        _profileId = profileId;
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

    private async Task UpdateNasRefreshLifecycleAsync()
    {
        await _lifecycleGate.WaitAsync();
        try
        {
            if (_disposed)
            {
                return;
            }
            if (_isLoaded && _isWindowVisible)
            {
                await Task.WhenAll(
                    _downloadRefresher.StartAsync(),
                    _fileRefresher.StartAsync());
            }
            else
            {
                await Task.WhenAll(
                    _downloadRefresher.StopAsync(),
                    _fileRefresher.StopAsync());
            }
            RenderActivities();
        }
        finally
        {
            _lifecycleGate.Release();
        }
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

    private Task RefreshNasTasksAsync() => Task.WhenAll(
        _downloadRefresher.RefreshAsync(),
        _fileRefresher.RefreshAsync());

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement
            {
                Tag: ForegroundTransferActivity
                {
                    State: ForegroundTransferState.Running,
                } activity,
            })
        {
            _transfers.Cancel(_profileId, activity.Id);
        }
    }

    private void RenderActivities()
    {
        if (_disposed)
        {
            return;
        }

        var items = _coordinator.GetActivities(_profileId)
            .Select(ActivityPresentation.Create)
            .ToArray();
        ActivityList.ItemsSource = items;
        ActivityList.Visibility = items.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        EmptyState.Visibility = items.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
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
            _timer.Stop();
            _timer.Tick -= Timer_Tick;
            Loaded -= TransferActivityPage_Loaded;
            Unloaded -= TransferActivityPage_Unloaded;
            await _downloadRefresher.DisposeAsync();
            await _fileRefresher.DisposeAsync();
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
                ForegroundTransferState.Running => localization.Format(
                    activity.Direction == ForegroundTransferDirection.Upload
                        ? "TransferActivityUploadProgress"
                        : "TransferActivityProgress",
                    activity.BytesTransferred,
                    activity.TotalBytes),
                ForegroundTransferState.Paused => localization.Get("TransferActivityPaused"),
                ForegroundTransferState.Completed => localization.Get(
                    activity.Direction == ForegroundTransferDirection.Upload
                        ? "TransferActivityUploadCompleted"
                        : "TransferActivityCompleted"),
                ForegroundTransferState.Cancelled => localization.Get("TransferActivityCancelled"),
                ForegroundTransferState.CancelledBeforeSubmission =>
                    localization.Get("TransferActivityCancelledBeforeSubmission"),
                ForegroundTransferState.ResultNeedsReview =>
                    localization.Get("TransferActivityUploadNeedsReview"),
                ForegroundTransferState.EndedNeedsReview =>
                    localization.Get("TransferActivityFileEndedNeedsReview"),
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
                CancelAutomationName = localization.Format(
                    "TransferActivityCancelAutomationName",
                    activity.DisplayName),
                CancelVisibility = activity.Source == ForegroundTransferSource.App &&
                    activity.State == ForegroundTransferState.Running
                    ? Visibility.Visible
                    : Visibility.Collapsed,
                ProgressVisibility = isFileTask &&
                    activity.State == ForegroundTransferState.EndedNeedsReview
                    ? Visibility.Collapsed
                    : Visibility.Visible,
            };
        }

        private static string FileTaskNameKey(FileBackgroundTaskKind? kind) => kind switch
        {
            FileBackgroundTaskKind.CopyOrMove => "TransferActivityFileCopyMove",
            FileBackgroundTaskKind.Delete => "TransferActivityFileDelete",
            FileBackgroundTaskKind.Compress => "TransferActivityFileCompress",
            FileBackgroundTaskKind.Extract => "TransferActivityFileExtract",
            _ => "TransferActivityFileTask",
        };
    }
}
