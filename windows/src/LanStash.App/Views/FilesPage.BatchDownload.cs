using LanStash.App.Features.Files;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly HashSet<string> _downloadSelection = new(StringComparer.Ordinal);
    private bool _isSelectingDownloads;
    private bool _isSynchronizingDownloadSelection;
    private bool _isChoosingDownloadTarget;
    private Guid? _downloadBatchId;

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
        _isSelectingDownloads = true;
        _downloadSelection.Clear();
        FileList.SelectionMode = ListViewSelectionMode.Multiple;
        FileGrid.SelectionMode = ListViewSelectionMode.Multiple;
        FileList.SelectedItems.Clear();
        FileGrid.SelectedItems.Clear();
        if (_viewModel.SelectedItem is { IsDirectory: false } selected)
        {
            _downloadSelection.Add(selected.Path);
            ApplyDownloadSelection(VisibleFilesControl());
        }
        AnnounceDownloadSelection();
        UpdateState();
    }

    private void ExitDownloadSelectionMode()
    {
        if (!_isSelectingDownloads)
        {
            return;
        }
        _isSynchronizingDownloadSelection = true;
        FileList.SelectedItems.Clear();
        FileGrid.SelectedItems.Clear();
        FileList.SelectionMode = ListViewSelectionMode.Single;
        FileGrid.SelectionMode = ListViewSelectionMode.Single;
        _isSynchronizingDownloadSelection = false;
        _downloadSelection.Clear();
        _isSelectingDownloads = false;
        FileDownloadBatchStatus.IsOpen = false;
        UpdateState();
    }

    private void HandleDownloadSelectionChanged(
        ListViewBase source,
        SelectionChangedEventArgs args)
    {
        if (!_isSelectingDownloads || _isSynchronizingDownloadSelection)
        {
            return;
        }

        foreach (var removed in args.RemovedItems.OfType<FileBrowserEntry>())
        {
            _downloadSelection.Remove(removed.Path);
        }
        var rejected = false;
        foreach (var added in args.AddedItems.OfType<FileBrowserEntry>())
        {
            if (added.IsDirectory ||
                (_downloadSelection.Count == BoundedFileDownloadBatch.MaximumFileCount &&
                    !_downloadSelection.Contains(added.Path)))
            {
                _isSynchronizingDownloadSelection = true;
                source.SelectedItems.Remove(added);
                _isSynchronizingDownloadSelection = false;
                rejected = true;
                continue;
            }
            _downloadSelection.Add(added.Path);
        }
        if (rejected)
        {
            ShowBatchDownloadMessage(
                "FileDownloadBatchSelectionLimitMessage",
                InfoBarSeverity.Warning);
        }
        else
        {
            AnnounceDownloadSelection();
        }
        UpdateState();
    }

    private async Task StartSelectedDownloadsAsync()
    {
        var items = _viewModel.Items
            .Where(item => !item.IsDirectory && _downloadSelection.Contains(item.Path))
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
        DownloadMultipleButton.Visibility = _isSelectingDownloads
            ? Visibility.Collapsed
            : Visibility.Visible;
        DownloadMultipleButton.IsEnabled =
            !_viewModel.IsLoading && _downloadBatchId is null &&
            _folderUploadBatchId is null && _viewModel.Items.Any(item => !item.IsDirectory);
        DownloadSelectedFilesButton.Visibility = _isSelectingDownloads
            ? Visibility.Visible
            : Visibility.Collapsed;
        DownloadSelectedFilesButton.IsEnabled = _downloadSelection.Count is > 0 and <= BoundedFileDownloadBatch.MaximumFileCount;
        DownloadSelectedFilesButton.IsEnabled &= !_isChoosingDownloadTarget;
        CancelDownloadSelectionButton.Visibility = _isSelectingDownloads
            ? Visibility.Visible
            : Visibility.Collapsed;
        CancelDownloadSelectionButton.IsEnabled = !_isChoosingDownloadTarget;

        if (_isSelectingDownloads || _downloadBatchId is not null || _isChoosingDownloadTarget)
        {
            CreateFolderButton.IsEnabled = false;
            RenameButton.IsEnabled = false;
            CopyFileButton.IsEnabled = false;
            MoveFileButton.IsEnabled = false;
            MoveToRecycleButton.IsEnabled = false;
            RestoreFromRecycleButton.IsEnabled = false;
            UploadButton.IsEnabled = false;
            UploadFolderButton.IsEnabled = false;
            DownloadButton.IsEnabled = false;
            PreviewButton.IsEnabled = false;
            ShareLinkButton.IsEnabled = false;
        }
    }

    private void SynchronizeDownloadSelectionAfterLayoutChange()
    {
        if (_isSelectingDownloads)
        {
            ApplyDownloadSelection(VisibleFilesControl());
        }
    }

    private void ApplyDownloadSelection(ListViewBase target)
    {
        _isSynchronizingDownloadSelection = true;
        target.SelectedItems.Clear();
        foreach (var item in _viewModel.Items.Where(item => _downloadSelection.Contains(item.Path)))
        {
            target.SelectedItems.Add(item);
        }
        _isSynchronizingDownloadSelection = false;
    }

    private ListViewBase VisibleFilesControl() =>
        _viewModel.IsListLayout ? FileList : FileGrid;

    private void AnnounceDownloadSelection() =>
        ShowBatchDownloadMessage(
            "FileDownloadBatchSelectionCountMessage",
            InfoBarSeverity.Informational,
            _downloadSelection.Count);

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
