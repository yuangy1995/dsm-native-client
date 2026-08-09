using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class TransferActivityPage : Page, IDisposable
{
    private readonly ForegroundTransferCoordinator _coordinator;
    private readonly WindowsTransferPickerService _transfers;
    private readonly string _profileId;
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private bool _disposed;

    internal TransferActivityPage(
        ForegroundTransferCoordinator coordinator,
        WindowsTransferPickerService transfers,
        string profileId)
    {
        InitializeComponent();
        _coordinator = coordinator;
        _transfers = transfers;
        _profileId = profileId;
        _timer.Tick += Timer_Tick;
        Loaded += TransferActivityPage_Loaded;
        Unloaded += TransferActivityPage_Unloaded;
        RenderActivities();
    }

    private void TransferActivityPage_Loaded(object sender, RoutedEventArgs e)
    {
        RenderActivities();
        _timer.Start();
    }

    private void TransferActivityPage_Unloaded(object sender, RoutedEventArgs e) =>
        _timer.Stop();

    private void Timer_Tick(object? sender, object e) => RenderActivities();

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
    }

    public void Dispose()
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
    }

    private sealed class ActivityPresentation
    {
        public required ForegroundTransferActivity Activity { get; init; }
        public required string DisplayName { get; init; }
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
                CancelVisibility = activity.State == ForegroundTransferState.Running
                    ? Visibility.Visible
                    : Visibility.Collapsed,
            };
        }
    }
}
