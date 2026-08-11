using LanStash.App.Features.Photos.Timeline;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private bool _isChoosingPhotoBatchSaveTarget;
    private Guid? _photoSaveBatchId;

    private async void SaveMultiplePhotos_Click(object sender, RoutedEventArgs e)
    {
        await ClosePhotoViewerAsync();
        EnterPhotoBatchSelection(PhotoBatchSelectionOperation.Save);
    }

    private async void SaveSelectedPhotos_Click(object sender, RoutedEventArgs e) =>
        await SaveMultiplePhotosAsync(SelectedFolderPhotos(), timelineMode: false);

    private Task SaveMultiplePhotosAsync(IReadOnlyList<PhotoItem> items) =>
        SaveMultiplePhotosAsync(items, timelineMode: true);

    private async Task SaveMultiplePhotosAsync(
        IReadOnlyList<PhotoItem> items,
        bool timelineMode)
    {
        if (_disposed || !_isPhotoPageActive || _isSaving ||
            _isChoosingPhotoBatchSaveTarget || _photoSaveBatchId is not null ||
            _viewModel.SelectedSpace is not { } sourceSpace ||
            timelineMode != (TimelineMode.IsChecked == true))
        {
            return;
        }

        var sourcePath = timelineMode ? sourceSpace.RootPath : _viewModel.CurrentPath;
        var downloads = items
            .Where(item => item.SizeBytes is >= 0)
            .Select(item => new FileDownloadBatchItem(
                item.Path,
                item.Name,
                item.SizeBytes!.Value))
            .ToArray();
        if (!PhotoBatchSaveSourceIsCurrent(
                sourceSpace,
                sourcePath,
                items,
                timelineMode) ||
            BoundedFileDownloadBatch.Validate(downloads) !=
                FileDownloadBatchValidationStatus.Valid)
        {
            ShowPhotoBatchSelectionMessage(
                "PhotoSaveBatchSelectionInvalid",
                InfoBarSeverity.Error,
                timelineMode: timelineMode);
            return;
        }

        _isChoosingPhotoBatchSaveTarget = true;
        UpdateState();
        TimelineView.RefreshActionState();
        try
        {
            var start = await _transfers.PickAndStartDownloadBatchAsync(
                _profileId,
                downloads);
            if (start.Status == FileDownloadBatchValidationStatus.Empty)
            {
                return;
            }
            if (start.Status != FileDownloadBatchValidationStatus.Valid ||
                start.BatchId is null)
            {
                ShowPhotoBatchSaveStartError(start.Status, timelineMode);
                return;
            }

            _photoSaveBatchId = start.BatchId;
            if (timelineMode)
            {
                TimelineView.ExitBatchSelection();
            }
            else
            {
                ExitPhotoBatchSelection(closeStatus: false);
            }
            ShowPhotoBatchSaveStarted(downloads.Length);
        }
        catch (ObjectDisposedException)
        {
        }
        catch
        {
            ShowPhotoBatchSelectionMessage(
                "FileDownloadBatchFolderErrorMessage",
                InfoBarSeverity.Error,
                timelineMode: timelineMode);
        }
        finally
        {
            _isChoosingPhotoBatchSaveTarget = false;
            UpdateState();
            TimelineView.RefreshActionState();
        }
    }

    private bool CanSavePhotoForBatch(PhotoItem item) =>
        !_disposed && !_isSaving && _photoSaveBatchId is null &&
        !_isChoosingPhotoBatchSaveTarget &&
        item.ProfileId == _dataSource.ProfileId &&
        _viewModel.ActiveProfileId == _dataSource.ProfileId &&
        _viewModel.SelectedSpace is { } space &&
        PhotoTimelineViewModel.ContainsCanonicalPath(space.RootPath, item.Path) &&
        item.Kind is PhotoItemKind.Image or PhotoItemKind.Video &&
        item.SizeBytes is >= 0;

    private bool PhotoBatchSaveSourceIsCurrent(
        PhotoSpace sourceSpace,
        string sourcePath,
        IReadOnlyList<PhotoItem> items,
        bool timelineMode)
    {
        if (_disposed || !_isPhotoPageActive || _isSaving ||
            _viewModel.SelectedSpace?.Id != sourceSpace.Id ||
            timelineMode != (TimelineMode.IsChecked == true) ||
            !timelineMode && !string.Equals(
                _viewModel.CurrentPath,
                sourcePath,
                StringComparison.Ordinal) ||
            timelineMode && !TimelineView.HasSelectedBatchItems(
                items,
                PhotoBatchSelectionOperation.Save) ||
            !timelineMode &&
                (_photoBatchSelectionOperation != PhotoBatchSelectionOperation.Save ||
                    !FolderSelectionMatches(items)))
        {
            return false;
        }

        return items.Count is > 0 and <= BoundedFileDownloadBatch.MaximumFileCount &&
            items.All(CanSavePhotoForBatch);
    }

    private void ShowPhotoBatchSaveStartError(
        FileDownloadBatchValidationStatus status,
        bool timelineMode) =>
        ShowPhotoBatchSelectionMessage(status switch
        {
            FileDownloadBatchValidationStatus.TargetExists =>
                "FileDownloadBatchTargetExistsMessage",
            FileDownloadBatchValidationStatus.TargetBusy =>
                "FileDownloadBatchBusyMessage",
            FileDownloadBatchValidationStatus.TooMany =>
                "FileDownloadBatchTooManyMessage",
            _ => "PhotoSaveBatchSelectionInvalid",
        }, InfoBarSeverity.Error, timelineMode: timelineMode);

    private void ShowPhotoBatchSaveStarted(int count)
    {
        var localization = LocalizationService.Current;
        var cancel = new Button
        {
            Content = localization.Get("ActionCancel"),
            MinHeight = 44,
        };
        AutomationProperties.SetName(
            cancel,
            localization.Get("PhotoSaveBatchCancelAutomationName"));
        cancel.Click += (_, _) =>
        {
            if (_photoSaveBatchId is not { } batchId)
            {
                return;
            }
            cancel.IsEnabled = false;
            _transfers.CancelDownloadBatch(batchId);
            ShowPhotoBatchMessage(
                "FileDownloadBatchCancellingMessage",
                InfoBarSeverity.Informational,
                clearAction: false);
        };
        PhotoRecycleBatchStatus.ActionButton = cancel;
        PhotoRecycleBatchStatus.Severity = InfoBarSeverity.Informational;
        PhotoRecycleBatchStatus.Message = localization.Format(
            "PhotoSaveBatchStartedMessage",
            count);
        PhotoRecycleBatchStatus.IsOpen = true;
    }

    private void Transfers_PhotoDownloadBatchFinished(
        ForegroundDownloadBatchFinished finished)
    {
        if (!string.Equals(finished.ProfileId, _profileId, StringComparison.Ordinal))
        {
            return;
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed || _photoSaveBatchId != finished.BatchId)
            {
                return;
            }
            _photoSaveBatchId = null;
            PhotoRecycleBatchStatus.ActionButton = null;
            var summary = finished.Summary;
            PhotoRecycleBatchStatus.Severity = summary.FailedCount > 0 ||
                summary.CancelledCount > 0 || summary.NotStartedCount > 0
                ? InfoBarSeverity.Warning
                : InfoBarSeverity.Success;
            PhotoRecycleBatchStatus.Message = LocalizationService.Current.Format(
                "PhotoSaveBatchSummaryMessage",
                summary.SelectedCount,
                summary.CompletedCount,
                summary.FailedCount,
                summary.CancelledCount,
                summary.NotStartedCount);
            PhotoRecycleBatchStatus.IsOpen = true;
            UpdateState();
            TimelineView.RefreshActionState();
        });
    }

    private void ShowPhotoBatchMessage(
        string resourceKey,
        InfoBarSeverity severity,
        object? argument = null,
        bool clearAction = true)
    {
        if (clearAction)
        {
            PhotoRecycleBatchStatus.ActionButton = null;
        }
        PhotoRecycleBatchStatus.Severity = severity;
        PhotoRecycleBatchStatus.Message = argument is null
            ? LocalizationService.Current.Get(resourceKey)
            : LocalizationService.Current.Format(resourceKey, argument);
        PhotoRecycleBatchStatus.IsOpen = true;
    }
}
