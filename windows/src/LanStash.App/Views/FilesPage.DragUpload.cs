using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private long _fileUploadDragGeneration;
    private long _fileUploadDropGeneration;

    private async void FileUpload_DragOver(object sender, DragEventArgs e)
    {
        var generation = Interlocked.Increment(ref _fileUploadDragGeneration);
        e.AcceptedOperation = DataPackageOperation.None;
        var deferral = e.GetDeferral();
        try
        {
            var sourcePaths = await TryGetDroppedFilePathsAsync(e.DataView);
            if (generation != Volatile.Read(ref _fileUploadDragGeneration) ||
                !CanAcceptFileUploadDrop() || sourcePaths is null)
            {
                if (generation == Volatile.Read(ref _fileUploadDragGeneration))
                {
                    FileUploadDropOverlay.Visibility = Visibility.Collapsed;
                }
                return;
            }

            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = LocalizationService.Current.Get(
                "FileUploadDropCaption");
            e.DragUIOverride.IsCaptionVisible = true;
            FileUploadDropStatus.IsOpen = false;
            FileUploadDropOverlay.Visibility = Visibility.Visible;
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void FileUpload_DragLeave(object sender, DragEventArgs e)
    {
        Interlocked.Increment(ref _fileUploadDragGeneration);
        FileUploadDropOverlay.Visibility = Visibility.Collapsed;
    }

    private async void FileUpload_Drop(object sender, DragEventArgs e)
    {
        Interlocked.Increment(ref _fileUploadDragGeneration);
        var generation = Interlocked.Increment(ref _fileUploadDropGeneration);
        FileUploadDropOverlay.Visibility = Visibility.Collapsed;
        var targetPath = _viewModel.CurrentPath;
        var deferral = e.GetDeferral();
        try
        {
            var sourcePaths = await TryGetDroppedFilePathsAsync(e.DataView);
            if (generation != Volatile.Read(ref _fileUploadDropGeneration))
            {
                return;
            }
            if (!CanAcceptFileUploadDrop() || sourcePaths is null ||
                !string.Equals(targetPath, _viewModel.CurrentPath, StringComparison.Ordinal))
            {
                ShowFileUploadDropError("FileUploadDropInvalidMessage");
                return;
            }

            _isChoosingUpload = true;
            FileUploadDropStatus.IsOpen = false;
            UpdateState();
            try
            {
                var status = _transfers.StartUploadBatch(
                    _profileId.ToString(),
                    targetPath,
                    sourcePaths);
                ShowFileUploadBatchStart(status, sourcePaths.Count);
            }
            catch (ObjectDisposedException)
            {
            }
            catch
            {
                ShowFileUploadDropError("FileUploadDropFailureMessage");
            }
            finally
            {
                _isChoosingUpload = false;
                UpdateState();
            }
        }
        finally
        {
            deferral.Complete();
        }
    }

    private bool CanAcceptFileUploadDrop() =>
        !_disposed &&
        !_viewModel.IsLoading &&
        !_isChoosingUpload &&
        !IsReadOnlyLocation() &&
        !string.IsNullOrWhiteSpace(_viewModel.CurrentPath);

    private static async Task<IReadOnlyList<string>?> TryGetDroppedFilePathsAsync(
        DataPackageView dataView)
    {
        try
        {
            if (!dataView.Contains(StandardDataFormats.StorageItems))
            {
                return null;
            }
            var items = await dataView.GetStorageItemsAsync();
            if (items.Count == 0 || items.Count > BoundedFileUploadBatch.MaximumFileCount)
            {
                return null;
            }
            var paths = new List<string>(items.Count);
            foreach (var item in items)
            {
                if (item is not StorageFile file || string.IsNullOrWhiteSpace(file.Path))
                {
                    return null;
                }
                paths.Add(file.Path);
            }
            return BoundedFileUploadBatch.ValidatePaths(paths) ==
                FileUploadBatchValidationStatus.Valid ? paths : null;
        }
        catch
        {
            return null;
        }
    }

    private void ShowFileUploadDropError(string resourceKey)
    {
        FileUploadDropStatus.Severity = Microsoft.UI.Xaml.Controls.InfoBarSeverity.Error;
        FileUploadDropStatus.Message = LocalizationService.Current.Get(resourceKey);
        FileUploadDropStatus.IsOpen = true;
    }

    private void ShowFileUploadBatchStart(
        FileUploadBatchValidationStatus status,
        int selectedCount)
    {
        if (status == FileUploadBatchValidationStatus.Empty)
        {
            return;
        }

        var localization = LocalizationService.Current;
        FileUploadDropStatus.Severity = status == FileUploadBatchValidationStatus.Valid
            ? Microsoft.UI.Xaml.Controls.InfoBarSeverity.Informational
            : Microsoft.UI.Xaml.Controls.InfoBarSeverity.Error;
        FileUploadDropStatus.Message = status switch
        {
            FileUploadBatchValidationStatus.Valid =>
                localization.Format("FileUploadBatchStartedMessage", selectedCount),
            FileUploadBatchValidationStatus.TooMany =>
                localization.Get("FileUploadBatchTooManyMessage"),
            FileUploadBatchValidationStatus.DuplicateTarget =>
                localization.Get("FileUploadBatchDuplicateMessage"),
            FileUploadBatchValidationStatus.TargetBusy =>
                localization.Get("FileUploadBatchBusyMessage"),
            _ => localization.Get("FileUploadDropInvalidMessage"),
        };
        FileUploadDropStatus.IsOpen = true;
    }

    private void ShowFileUploadBatchSummary(FileUploadBatchSummary summary)
    {
        FileUploadDropStatus.Severity =
            summary.NeedsReviewCount > 0 || summary.FailedCount > 0 ||
                summary.CancelledCount > 0 || summary.NotStartedCount > 0
                ? Microsoft.UI.Xaml.Controls.InfoBarSeverity.Warning
                : Microsoft.UI.Xaml.Controls.InfoBarSeverity.Success;
        FileUploadDropStatus.Message = LocalizationService.Current.Format(
            "FileUploadBatchSummaryMessage",
            summary.SelectedCount,
            summary.ConfirmedCount,
            summary.NeedsReviewCount,
            summary.FailedCount,
            summary.CancelledCount,
            summary.NotStartedCount);
        FileUploadDropStatus.IsOpen = true;
    }

    private void DeactivateFileUploadDrop()
    {
        Interlocked.Increment(ref _fileUploadDragGeneration);
        Interlocked.Increment(ref _fileUploadDropGeneration);
        FileUploadDropOverlay.Visibility = Visibility.Collapsed;
        FileUploadDropStatus.IsOpen = false;
    }
}
