using LanStash.App.Features.Files;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private enum FileBatchSelectionOperation
    {
        Download,
        Copy,
        Move,
        Recycle,
        Restore,
        Compress,
    }

    private readonly HashSet<string> _batchSelection = new(StringComparer.Ordinal);
    private FileBatchSelectionOperation? _batchSelectionOperation;
    private bool _isSynchronizingDownloadSelection;
    private bool _isChoosingDownloadTarget;
    private Guid? _downloadBatchId;

    private bool _isSelectingDownloads =>
        _batchSelectionOperation == FileBatchSelectionOperation.Download;
    private bool _isSelectingCopyMove =>
        _batchSelectionOperation is FileBatchSelectionOperation.Copy or
            FileBatchSelectionOperation.Move;
    private bool _isSelectingRecycle =>
        _batchSelectionOperation is FileBatchSelectionOperation.Recycle or
            FileBatchSelectionOperation.Restore;
    private bool _isSelectingRestore =>
        _batchSelectionOperation == FileBatchSelectionOperation.Restore;
    private bool _isSelectingArchiveCompression =>
        _batchSelectionOperation == FileBatchSelectionOperation.Compress;
    private bool _isSelectingItems => _batchSelectionOperation is not null;

    private async void DownloadMultiple_Click(object sender, RoutedEventArgs e)
    {
        await ClosePreviewAsync();
        EnterDownloadSelectionMode();
    }

    private async void DownloadSelectedFiles_Click(object sender, RoutedEventArgs e) =>
        await StartSelectedDownloadsAsync();

    private void CancelDownloadSelection_Click(object sender, RoutedEventArgs e) =>
        ExitDownloadSelectionMode();

    private void EnterDownloadSelectionMode()
    {
        if (_disposed || _viewModel.IsLoading || _downloadBatchId is not null ||
            _folderUploadBatchId is not null)
        {
            return;
        }
        var selected = _viewModel.SelectedItem;
        _batchSelectionOperation = FileBatchSelectionOperation.Download;
        _batchSelection.Clear();
        FileList.SelectionMode = ListViewSelectionMode.Multiple;
        FileGrid.SelectionMode = ListViewSelectionMode.Multiple;
        FileList.SelectedItems.Clear();
        FileGrid.SelectedItems.Clear();
        if (selected is { IsDirectory: false })
        {
            _batchSelection.Add(selected.Path);
            ApplyDownloadSelection(VisibleFilesControl());
        }
        AnnounceBatchSelection();
        UpdateState();
    }

    private void ExitDownloadSelectionMode()
    {
        CloseBatchCopyMoveDialog();
        CloseBatchRecycleDialog();
        CloseArchiveCompressionDialog();
        if (!_isSelectingItems)
        {
            return;
        }
        _isSynchronizingDownloadSelection = true;
        FileList.SelectedItems.Clear();
        FileGrid.SelectedItems.Clear();
        FileList.SelectionMode = ListViewSelectionMode.Single;
        FileGrid.SelectionMode = ListViewSelectionMode.Single;
        _isSynchronizingDownloadSelection = false;
        _batchSelection.Clear();
        _batchSelectionOperation = null;
        FileDownloadBatchStatus.IsOpen = false;
        FileCopyMoveBatchStatus.IsOpen = false;
        FileRecycleBatchStatus.IsOpen = false;
        FileArchiveCompressionStatus.IsOpen = false;
        UpdateState();
    }

    private void HandleDownloadSelectionChanged(
        ListViewBase source,
        SelectionChangedEventArgs args)
    {
        if (!_isSelectingItems || _isSynchronizingDownloadSelection)
        {
            return;
        }

        foreach (var removed in args.RemovedItems.OfType<FileBrowserEntry>())
        {
            _batchSelection.Remove(removed.Path);
        }
        var rejected = false;
        var rejectedForLimit = false;
        foreach (var added in args.AddedItems.OfType<FileBrowserEntry>())
        {
            var rejectsItem = _isSelectingDownloads
                ? added.IsDirectory
                : _isSelectingArchiveCompression
                    ? !CanSelectForArchiveCompression(added.Item)
                : _isSelectingRecycle
                    ? _isSelectingRestore
                        ? !CanSelectForBatchRestore(added.Item)
                        : !CanSelectForBatchRecycle(added.Item)
                    : !FileCopyMoveViewModel.IsDestination(added.Path) ||
                        (_batchSelectionOperation == FileBatchSelectionOperation.Move &&
                            !added.Item.CanDelete);
            if (rejectsItem ||
                (_batchSelection.Count == BoundedFileDownloadBatch.MaximumFileCount &&
                    !_batchSelection.Contains(added.Path)))
            {
                rejectedForLimit |= !rejectsItem;
                _isSynchronizingDownloadSelection = true;
                source.SelectedItems.Remove(added);
                _isSynchronizingDownloadSelection = false;
                rejected = true;
                continue;
            }
            _batchSelection.Add(added.Path);
        }
        if (rejected)
        {
            ShowBatchSelectionMessage(
                _isSelectingDownloads
                    ? "FileDownloadBatchSelectionLimitMessage"
                    : _isSelectingArchiveCompression
                        ? rejectedForLimit
                            ? "FileArchiveCompressionSelectionLimit"
                            : "FileArchiveCompressionSelectionInvalid"
                    : _isSelectingRecycle
                        ? rejectedForLimit
                            ? _isSelectingRestore
                                ? "FileRestoreBatchSelectionLimit"
                                : "FileRecycleBatchSelectionLimit"
                            : _isSelectingRestore
                                ? "FileRestoreBatchSelectionInvalid"
                                : "FileRecycleBatchSelectionInvalid"
                        : rejectedForLimit
                            ? "FileCopyMoveBatchSelectionLimit"
                            : "FileCopyMoveBatchSelectionInvalid",
                InfoBarSeverity.Warning);
        }
        else
        {
            AnnounceBatchSelection();
        }
        UpdateState();
    }

    private async Task StartSelectedDownloadsAsync()
    {
        var items = _viewModel.Items
            .Where(item => !item.IsDirectory && _batchSelection.Contains(item.Path))
            .Select(item => new FileDownloadBatchItem(item.Path, item.Name, item.Item.Size))
            .ToArray();
        if (BoundedFileDownloadBatch.Validate(items) != FileDownloadBatchValidationStatus.Valid)
        {
            ShowBatchDownloadMessage("FileDownloadBatchInvalidMessage", InfoBarSeverity.Error);
            return;
        }

        _isChoosingDownloadTarget = true;
        UpdateState();
        try
        {
            var start = await _transfers.PickAndStartDownloadBatchAsync(
                _profileId.ToString(),
                items);
            if (start.Status == FileDownloadBatchValidationStatus.Empty)
            {
                return;
            }
            if (start.Status != FileDownloadBatchValidationStatus.Valid || start.BatchId is null)
            {
                ShowBatchDownloadStartError(start.Status);
                return;
            }
            ExitDownloadSelectionMode();
            _downloadBatchId = start.BatchId;
            ShowDownloadBatchStarted(items.Length);
            UpdateState();
        }
        catch (ObjectDisposedException)
        {
        }
        catch
        {
            ShowBatchDownloadMessage("FileDownloadBatchFolderErrorMessage", InfoBarSeverity.Error);
        }
        finally
        {
            _isChoosingDownloadTarget = false;
            UpdateState();
        }
    }

    private void ShowDownloadBatchStarted(int count)
    {
        var localization = LocalizationService.Current;
        var cancel = new Button
        {
            Content = localization.Get("ActionCancel"),
            MinHeight = 44,
        };
        AutomationProperties.SetName(cancel, localization.Get("FileDownloadBatchCancelAutomationName"));
        cancel.Click += (_, _) =>
        {
            if (_downloadBatchId is not { } batchId)
            {
                return;
            }
            cancel.IsEnabled = false;
            _transfers.CancelDownloadBatch(batchId);
            ShowBatchDownloadMessage(
                "FileDownloadBatchCancellingMessage",
                InfoBarSeverity.Informational,
                clearAction: false);
        };
        FileDownloadBatchStatus.ActionButton = cancel;
        FileDownloadBatchStatus.Severity = InfoBarSeverity.Informational;
        FileDownloadBatchStatus.Message = localization.Format("FileDownloadBatchStartedMessage", count);
        FileDownloadBatchStatus.IsOpen = true;
    }

    private void Transfers_DownloadBatchFinished(ForegroundDownloadBatchFinished finished)
    {
        if (!string.Equals(finished.ProfileId, _profileId.ToString(), StringComparison.Ordinal))
        {
            return;
        }
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed || _downloadBatchId != finished.BatchId)
            {
                return;
            }
            _downloadBatchId = null;
            FileDownloadBatchStatus.ActionButton = null;
            var summary = finished.Summary;
            FileDownloadBatchStatus.Severity =
                summary.FailedCount > 0 || summary.CancelledCount > 0 ||
                    summary.NotStartedCount > 0
                    ? InfoBarSeverity.Warning
                    : InfoBarSeverity.Success;
            FileDownloadBatchStatus.Message = LocalizationService.Current.Format(
                "FileDownloadBatchSummaryMessage",
                summary.SelectedCount,
                summary.CompletedCount,
                summary.FailedCount,
                summary.CancelledCount,
                summary.NotStartedCount);
            FileDownloadBatchStatus.IsOpen = true;
            UpdateState();
        });
    }

    private void UpdateBatchDownloadControls()
    {
        DownloadMultipleButton.Visibility = _isSelectingItems
            ? Visibility.Collapsed
            : Visibility.Visible;
        DownloadMultipleButton.IsEnabled =
            !_viewModel.IsLoading && _downloadBatchId is null &&
            _folderUploadBatchId is null && _viewModel.Items.Any(item => !item.IsDirectory);
        DownloadSelectedFilesButton.Visibility = _isSelectingDownloads
            ? Visibility.Visible
            : Visibility.Collapsed;
        DownloadSelectedFilesButton.IsEnabled = _batchSelection.Count is > 0 and <= BoundedFileDownloadBatch.MaximumFileCount;
        DownloadSelectedFilesButton.IsEnabled &= !_isChoosingDownloadTarget;
        MoveSelectedToRecycleButton.Visibility = _isSelectingRecycle
            && !_isSelectingRestore
            ? Visibility.Visible
            : Visibility.Collapsed;
        MoveSelectedToRecycleButton.IsEnabled = _batchSelection.Count is > 0 and <=
            FileRecycleBatchViewModel.MaximumItemCount;
        RestoreSelectedItemsButton.Visibility = _isSelectingRestore
            ? Visibility.Visible
            : Visibility.Collapsed;
        RestoreSelectedItemsButton.IsEnabled = _batchSelection.Count is > 0 and <=
            FileRecycleBatchViewModel.MaximumItemCount;
        CreateArchiveSelectedButton.Visibility = _isSelectingArchiveCompression
            ? Visibility.Visible
            : Visibility.Collapsed;
        CreateArchiveSelectedButton.IsEnabled = _batchSelection.Count is > 0 and <= 20;
        CancelDownloadSelectionButton.Visibility = _isSelectingItems
            ? Visibility.Visible
            : Visibility.Collapsed;
        CancelDownloadSelectionButton.IsEnabled = !_isChoosingDownloadTarget;

        if (_isSelectingItems || _downloadBatchId is not null || _isChoosingDownloadTarget)
        {
            CreateFolderButton.IsEnabled = false;
            RenameButton.IsEnabled = false;
            CopyFileButton.IsEnabled = false;
            MoveFileButton.IsEnabled = false;
            MoveToRecycleButton.IsEnabled = false;
            MoveMultipleToRecycleButton.IsEnabled = false;
            RestoreMultipleItemsButton.IsEnabled = false;
            RestoreFromRecycleButton.IsEnabled = false;
            CreateArchiveButton.IsEnabled = false;
            ExtractArchiveButton.IsEnabled = false;
            UploadButton.IsEnabled = false;
            UploadFolderButton.IsEnabled = false;
            DownloadButton.IsEnabled = false;
            PreviewButton.IsEnabled = false;
            ShareLinkButton.IsEnabled = false;
        }
    }

    private void SynchronizeDownloadSelectionAfterLayoutChange()
    {
        if (_isSelectingItems)
        {
            ApplyDownloadSelection(VisibleFilesControl());
        }
    }

    private void ApplyDownloadSelection(ListViewBase target)
    {
        _isSynchronizingDownloadSelection = true;
        target.SelectedItems.Clear();
        foreach (var item in _viewModel.Items.Where(item => _batchSelection.Contains(item.Path)))
        {
            target.SelectedItems.Add(item);
        }
        _isSynchronizingDownloadSelection = false;
    }

    private ListViewBase VisibleFilesControl() =>
        _viewModel.IsListLayout ? FileList : FileGrid;

    private void AnnounceBatchSelection() =>
        ShowBatchSelectionMessage(
            _isSelectingDownloads
                ? "FileDownloadBatchSelectionCountMessage"
                : _isSelectingArchiveCompression
                    ? "FileArchiveCompressionSelectionCount"
                : _isSelectingRecycle
                    ? _isSelectingRestore
                        ? "FileRestoreBatchSelectionCount"
                        : "FileRecycleBatchSelectionCount"
                    : "FileCopyMoveBatchSelectionCount",
            InfoBarSeverity.Informational,
            _batchSelection.Count);

    private void ShowBatchSelectionMessage(
        string resourceKey,
        InfoBarSeverity severity,
        object? argument = null)
    {
        if (_isSelectingRecycle)
        {
            FileRecycleBatchStatus.Severity = severity;
            FileRecycleBatchStatus.Message = argument is null
                ? LocalizationService.Current.Get(resourceKey)
                : LocalizationService.Current.Format(resourceKey, argument);
            FileRecycleBatchStatus.IsOpen = true;
            return;
        }
        if (_isSelectingArchiveCompression)
        {
            FileArchiveCompressionStatus.Severity = severity;
            FileArchiveCompressionStatus.Message = argument is null
                ? LocalizationService.Current.Get(resourceKey)
                : LocalizationService.Current.Format(resourceKey, argument);
            FileArchiveCompressionStatus.IsOpen = true;
            return;
        }
        if (_isSelectingCopyMove)
        {
            FileCopyMoveBatchStatus.Severity = severity;
            FileCopyMoveBatchStatus.Message = argument is null
                ? LocalizationService.Current.Get(resourceKey)
                : LocalizationService.Current.Format(resourceKey, argument);
            FileCopyMoveBatchStatus.IsOpen = true;
            return;
        }
        ShowBatchDownloadMessage(resourceKey, severity, argument);
    }

    private void ShowBatchDownloadStartError(FileDownloadBatchValidationStatus status) =>
        ShowBatchDownloadMessage(status switch
        {
            FileDownloadBatchValidationStatus.TargetExists => "FileDownloadBatchTargetExistsMessage",
            FileDownloadBatchValidationStatus.TargetBusy => "FileDownloadBatchBusyMessage",
            FileDownloadBatchValidationStatus.TooMany => "FileDownloadBatchTooManyMessage",
            _ => "FileDownloadBatchInvalidMessage",
        }, InfoBarSeverity.Error);

    private void ShowBatchDownloadMessage(
        string resourceKey,
        InfoBarSeverity severity,
        object? argument = null,
        bool clearAction = true)
    {
        if (clearAction)
        {
            FileDownloadBatchStatus.ActionButton = null;
        }
        FileDownloadBatchStatus.Severity = severity;
        FileDownloadBatchStatus.Message = argument is null
            ? LocalizationService.Current.Get(resourceKey)
            : LocalizationService.Current.Format(resourceKey, argument);
        FileDownloadBatchStatus.IsOpen = true;
    }
}
