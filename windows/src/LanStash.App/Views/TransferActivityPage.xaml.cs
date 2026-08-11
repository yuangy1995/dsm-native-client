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
    private readonly DownloadStationActivityRefresher _nasRefresher;
    private readonly bool _canRefreshNasTasks;
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private bool _isLoaded;
    private bool _isWindowVisible = true;
    private bool _disposed;

    internal TransferActivityPage(
        ForegroundTransferCoordinator coordinator,
        WindowsTransferPickerService transfers,
        string profileId,
        IDownloadStationRepository downloadStationRepository)
    {
        InitializeComponent();
        _coordinator = coordinator;
        _transfers = transfers;
        _profileId = profileId;
        _canRefreshNasTasks = downloadStationRepository.ProfileId.ToString() == profileId &&
            downloadStationRepository.Availability.Status ==
                DownloadStationAvailabilityStatus.Available &&
            downloadStationRepository.Availability.SupportedFeatures.Contains(
                DownloadStationReadFeature.Tasks);
        _nasRefresher = new DownloadStationActivityRefresher(
            downloadStationRepository,
            tasks => _coordinator.SyncDownloadStationTasks(
                downloadStationRepository.ProfileId,
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
                await _nasRefresher.StartAsync();
            }
            else
            {
                await _nasRefresher.StopAsync();
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
        await _nasRefresher.RefreshAsync();
        RenderActivities();
    }

    private async void RefreshAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        await _nasRefresher.RefreshAsync();
        RenderActivities();
    }

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
        var refreshState = _nasRefresher.State;
        RefreshButton.IsEnabled = _canRefreshNasTasks && !refreshState.IsRefreshing;
        RefreshProgress.IsActive = refreshState.IsRefreshing;
        RefreshProgress.Visibility = refreshState.IsRefreshing
            ? Visibility.Visible
            : Visibility.Collapsed;
        RefreshErrorNotice.IsOpen = refreshState.HasFailed;
        TruncatedNotice.IsOpen = refreshState.IsTruncated;
        NasUnavailableNotice.IsOpen = !_canRefreshNasTasks;
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
            await _nasRefresher.DisposeAsync();
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

        public static ActivityPresentation Create(ForegroundTransferActivity activity)
        {
            var localization = LocalizationService.Current;
            var status = activity.State switch
            {
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
                ForegroundTransferState.Failed => localization.Get(
                    activity.Direction == ForegroundTransferDirection.Upload
                        ? "TransferActivityUploadFailed"
                        : "TransferActivityFailed"),
                _ => localization.Get("TransferActivityFailed"),
            };
            return new ActivityPresentation
            {
                Activity = activity,
                DisplayName = activity.DisplayName,
                SourceText = localization.Get(
                    activity.Source == ForegroundTransferSource.App
                        ? "TransferActivitySourceApp"
                        : "TransferActivitySourceNas"),
                DirectionText = localization.Get(
                    activity.Direction == ForegroundTransferDirection.Upload
                        ? "TransferActivityDirectionUpload"
                        : "TransferActivityDirectionDownload"),
                Maximum = Math.Max(1, activity.TotalBytes),
                Value = activity.BytesTransferred,
                IsIndeterminate = activity.State == ForegroundTransferState.Running &&
                    activity.TotalBytes == 0,
                StatusText = status,
                CancelAutomationName = localization.Format(
                    "TransferActivityCancelAutomationName",
                    activity.DisplayName),
                CancelVisibility = activity.Source == ForegroundTransferSource.App &&
                    activity.State == ForegroundTransferState.Running
                    ? Visibility.Visible
                    : Visibility.Collapsed,
            };
        }
    }
}
