using LanStash.App.Features.Files;
using LanStash.App.Features.Files.Downloads;
using LanStash.Domain;
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
        if (selected is not null && FileDownloadSelection.IsValidItem(selected.Item))
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
        foreach (var added in args.AddedItems.OfType<FileBrowserEntry>())
        {
            var rejectsItem = _isSelectingDownloads
                ? !FileDownloadSelection.IsValidItem(added.Item)
                : _isSelectingArchiveCompression
                    ? !CanSelectForArchiveCompression(added.Item)
                : _isSelectingRecycle
                    ? _isSelectingRestore
                        ? !CanSelectForBatchRestore(added.Item)
                        : !CanSelectForBatchRecycle(added.Item)
                    : !FileCopyMoveViewModel.IsDestination(added.Path) ||
                        (_batchSelectionOperation == FileBatchSelectionOperation.Move &&
                            !added.Item.CanDelete);
            if (rejectsItem)
            {
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
                    ? "FileSelectionDownloadInvalid"
                    : _isSelectingArchiveCompression
                        ? "FileArchiveCompressionSelectionInvalid"
                    : _isSelectingRecycle
                        ? _isSelectingRestore
                            ? "FileRestoreBatchSelectionInvalid"
                            : "FileRecycleBatchSelectionInvalid"
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
        if (_disposed || !_isSelectingDownloads || _isChoosingDownloadTarget || _downloadBatchId is not null || _viewModel.IsLoading) return;
        var items = _viewModel.Items.Where(item => _batchSelection.Contains(item.Path)).Select(item => item.Item).ToArray();
        if (items.Length != _batchSelection.Count || !FileDownloadSelection.IsValid(items))
        {
            ShowBatchDownloadMessage("FileSelectionDownloadInvalid", InfoBarSeverity.Error);
            return;
        }
        var sourcePath = _viewModel.CurrentPath;
        bool SourceIsCurrent()
        {
            if (_disposed || !_isSelectingDownloads || _viewModel.IsLoading || _isSynchronizingDownloadSelection || _viewModel.CurrentPath != sourcePath) return false;
            var visible = VisibleFilesControl().SelectedItems;
            return visible.Count == items.Length &&
                FileDownloadSelection.MatchesSnapshot(items, visible.OfType<FileBrowserEntry>().Select(item => item.Item).ToArray(), _batchSelection) &&
                FileDownloadSelection.MatchesSnapshot(items, _viewModel.Items.Select(item => item.Item).ToArray(), _batchSelection);
        }
        _isChoosingDownloadTarget = true;
        UpdateState();
        try
        {
            var activityId = await _transfers.PickAndStartSelectedDownloadAsync(_profileId.ToString(), items, SourceIsCurrent);
            if (_disposed) return;
            if (activityId is null)
            {
                if (!SourceIsCurrent()) ShowBatchDownloadMessage("FileSelectionDownloadChanged", InfoBarSeverity.Warning);
                return;
            }
            ExitDownloadSelectionMode();
            _downloadBatchId = activityId;
            ShowDownloadBatchStarted(items.Length);
            UpdateState();
        }
        catch (ObjectDisposedException) { }
        catch
        {
            if (!_disposed) ShowBatchDownloadMessage("FileSelectionDownloadFailed", InfoBarSeverity.Error);
        }
        finally
        {
            _isChoosingDownloadTarget = false;
            if (!_disposed) UpdateState();
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
            _transfers.Cancel(_profileId.ToString(), batchId);
            ShowBatchDownloadMessage(
                "FileDownloadBatchCancellingMessage",
                InfoBarSeverity.Informational,
                clearAction: false);
        };
        FileDownloadBatchStatus.ActionButton = cancel;
        FileDownloadBatchStatus.Severity = InfoBarSeverity.Informational;
        FileDownloadBatchStatus.Message = localization.Format("FileSelectionDownloadStarted", count);
        FileDownloadBatchStatus.IsOpen = true;
    }

    private void Transfers_SelectionDownloadFinished(ForegroundSelectionDownloadFinished finished)
    {
        if (!string.Equals(finished.ProfileId, _profileId.ToString(), StringComparison.Ordinal)) return;
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_disposed || _downloadBatchId != finished.ActivityId) return;
            _downloadBatchId = null;
            FileDownloadBatchStatus.ActionButton = null;
            FileDownloadBatchStatus.Severity = finished.Status == FileDownloadBatchAttemptStatus.Completed
                ? InfoBarSeverity.Success : InfoBarSeverity.Warning;
            FileDownloadBatchStatus.Message = LocalizationService.Current.Format(finished.Status switch
            {
                FileDownloadBatchAttemptStatus.Completed => "FileSelectionDownloadCompleted",
                FileDownloadBatchAttemptStatus.Cancelled => "FileSelectionDownloadCancelled",
                _ => "FileSelectionDownloadFailed"
            }, finished.SelectedCount);
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
            _folderUploadBatchId is null && _viewModel.Items.Any(item => FileDownloadSelection.IsValidItem(item.Item));
        DownloadSelectedFilesButton.Visibility = _isSelectingDownloads
            ? Visibility.Visible
            : Visibility.Collapsed;
        DownloadSelectedFilesButton.IsEnabled = _batchSelection.Count > 0;
        DownloadSelectedFilesButton.IsEnabled &= !_isChoosingDownloadTarget;
        MoveSelectedToRecycleButton.Visibility = _isSelectingRecycle
            && !_isSelectingRestore
            ? Visibility.Visible
            : Visibility.Collapsed;
        MoveSelectedToRecycleButton.IsEnabled = _batchSelection.Count > 0;
        RestoreSelectedItemsButton.Visibility = _isSelectingRestore
            ? Visibility.Visible
            : Visibility.Collapsed;
        RestoreSelectedItemsButton.IsEnabled = _batchSelection.Count > 0;
        CreateArchiveSelectedButton.Visibility = _isSelectingArchiveCompression
            ? Visibility.Visible
            : Visibility.Collapsed;
        CreateArchiveSelectedButton.IsEnabled = _batchSelection.Count > 0;
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
                ? "FileSelectionDownloadCount"
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
