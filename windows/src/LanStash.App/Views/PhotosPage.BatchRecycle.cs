using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.Photos;
using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal enum PhotoBatchSelectionOperation
{
    None,
    Save,
    Copy,
    Move,
    Recycle,
    Restore,
}

public sealed partial class PhotosPage
{
    private FileRecycleBatchViewModel? _photoBatchRecycleModel;
    private ContentDialog? _photoBatchRecycleDialog;
    private bool _isClosingPhotoBatchRecycle;
    private PhotoBatchSelectionOperation _photoBatchSelectionOperation;
    private bool _isSynchronizingPhotoBatchSelection;

    private bool IsSelectingPhotoBatch =>
        _photoBatchSelectionOperation != PhotoBatchSelectionOperation.None;

    private async void MoveMultiplePhotosToRecycle_Click(object sender, RoutedEventArgs e)
    {
        await ClosePhotoViewerAsync();
        EnterPhotoBatchSelection(PhotoBatchSelectionOperation.Recycle);
    }

    private async void MoveSelectedPhotosToRecycle_Click(object sender, RoutedEventArgs e) =>
        await ShowPhotoBatchRecycleAsync(
            SelectedFolderPhotos(),
            timelineMode: false,
            FileRecycleOperation.MoveToRecycle);

    private async void RestoreMultiplePhotos_Click(object sender, RoutedEventArgs e)
    {
        await ClosePhotoViewerAsync();
        EnterPhotoBatchSelection(PhotoBatchSelectionOperation.Restore);
    }

    private async void RestoreSelectedPhotos_Click(object sender, RoutedEventArgs e) =>
        await ShowPhotoBatchRecycleAsync(
            SelectedFolderPhotos(),
            timelineMode: false,
            FileRecycleOperation.Restore);

    private void CancelPhotoBatchSelection_Click(object sender, RoutedEventArgs e) =>
        ExitPhotoBatchSelection();

    private void EnterPhotoBatchSelection(PhotoBatchSelectionOperation operation)
    {
        if (!CanEnterPhotoBatchSelection(operation))
        {
            return;
        }

        var selected = _viewModel.SelectedItem;
        _isSynchronizingPhotoBatchSelection = true;
        PhotoGrid.SelectedItems.Clear();
        PhotoGrid.SelectionMode = ListViewSelectionMode.Multiple;
        if (selected is not null && CanSelectPhotoForBatch(selected.Item, operation))
        {
            PhotoGrid.SelectedItems.Add(selected);
        }
        _isSynchronizingPhotoBatchSelection = false;
        _photoBatchSelectionOperation = operation;
        ShowPhotoBatchSelectionMessage(
            SelectionCountResource(operation),
            InfoBarSeverity.Informational,
            PhotoGrid.SelectedItems.Count);
        UpdateState();
    }

    private bool CanEnterPhotoBatchSelection(PhotoBatchSelectionOperation operation) =>
        operation != PhotoBatchSelectionOperation.None &&
        !_disposed && !_viewModel.IsLoading && !IsSelectingPhotoBatch &&
        _photoSaveBatchId is null && !_isChoosingPhotoBatchSaveTarget &&
        _photoCopyMoveDialog is null && _photoBatchCopyMoveDialog is null &&
        _photoRecycleDialog is null && _photoBatchRecycleDialog is null &&
        !_isClosingPhotoCopyMove && !_isClosingPhotoBatchCopyMove &&
        !_isClosingPhotoRecycle && !_isClosingPhotoBatchRecycle &&
        TimelineMode.IsChecked != true &&
        _viewModel.Items.Any(entry => CanSelectPhotoForBatch(entry.Item, operation));

    private bool CanSelectPhotoForBatch(
        PhotoItem item,
        PhotoBatchSelectionOperation operation) => operation switch
        {
            PhotoBatchSelectionOperation.Save => CanSavePhotoForBatch(item),
            PhotoBatchSelectionOperation.Copy => CanCopyPhotoCore(item),
            PhotoBatchSelectionOperation.Move => CanMovePhotoCore(item),
            PhotoBatchSelectionOperation.Recycle => CanSelectPhotoForBatchRecycle(item),
            PhotoBatchSelectionOperation.Restore => CanPhotoRecycleItemCore(
                item,
                FileRecycleOperation.Restore),
            _ => false,
        };

    private bool CanSelectPhotoForBatchRecycle(PhotoItem item) =>
        CanPhotoRecycleItemCore(item, FileRecycleOperation.MoveToRecycle);

    private void HandlePhotoBatchSelectionChanged(SelectionChangedEventArgs args)
    {
        if (!IsSelectingPhotoBatch || _isSynchronizingPhotoBatchSelection)
        {
            return;
        }

        var rejected = false;
        var rejectedForLimit = false;
        foreach (var added in args.AddedItems.OfType<PhotoBrowserEntry>())
        {
            if (!CanSelectPhotoForBatch(added.Item, _photoBatchSelectionOperation) ||
                PhotoGrid.SelectedItems.Count > FileCopyMoveBatchViewModel.MaximumItemCount)
            {
                rejectedForLimit |= PhotoGrid.SelectedItems.Count >
                    FileCopyMoveBatchViewModel.MaximumItemCount;
                _isSynchronizingPhotoBatchSelection = true;
                PhotoGrid.SelectedItems.Remove(added);
                _isSynchronizingPhotoBatchSelection = false;
                rejected = true;
            }
        }
        ShowPhotoBatchSelectionMessage(
            rejected
                ? rejectedForLimit
                    ? SelectionLimitResource(_photoBatchSelectionOperation)
                    : SelectionInvalidResource(_photoBatchSelectionOperation)
                : SelectionCountResource(_photoBatchSelectionOperation),
            rejected ? InfoBarSeverity.Warning : InfoBarSeverity.Informational,
            rejected ? null : PhotoGrid.SelectedItems.Count);
    }

    private IReadOnlyList<PhotoItem> SelectedFolderPhotos() =>
        PhotoGrid.SelectedItems
            .OfType<PhotoBrowserEntry>()
            .Select(entry => entry.Item)
            .ToArray();

    private Task MoveMultiplePhotosToRecycleAsync(IReadOnlyList<PhotoItem> items) =>
        ShowPhotoBatchRecycleAsync(
            items,
            timelineMode: true,
            FileRecycleOperation.MoveToRecycle);

    private Task RestoreMultiplePhotosAsync(IReadOnlyList<PhotoItem> items) =>
        ShowPhotoBatchRecycleAsync(
            items,
            timelineMode: true,
            FileRecycleOperation.Restore);

    private async Task ShowPhotoBatchRecycleAsync(
        IReadOnlyList<PhotoItem> items,
        bool timelineMode,
        FileRecycleOperation operation)
    {
        if (_disposed || !_isPhotoPageActive ||
            _photoBatchRecycleDialog is not null ||
            _photoBatchRecycleModel is not null ||
            _isClosingPhotoBatchRecycle ||
            _photoRecycleRepository is not { } repository ||
            _viewModel.SelectedSpace is not { } sourceSpace ||
            timelineMode != (TimelineMode.IsChecked == true) ||
            items.Select(ToRecycleFileItem).Any(item => item is null) ||
            operation == FileRecycleOperation.MoveToRecycle &&
                !repository.Availability.CanMoveToRecycle ||
            operation == FileRecycleOperation.Restore &&
                !repository.Availability.CanRestore)
        {
            return;
        }

        var sources = items.Select(ToRecycleFileItem).OfType<FileItem>().ToArray();
        var sourceRoot = timelineMode ? sourceSpace.RootPath : _viewModel.CurrentPath;
        var sourceScope = timelineMode
            ? FileRecycleBatchSourceScope.DescendantsOfRoot
            : FileRecycleBatchSourceScope.CurrentFolder;
        var recycleLocations = operation == FileRecycleOperation.MoveToRecycle
            ? _photoRecycleLocations.ToArray()
            : [];
        var locationSource = operation == FileRecycleOperation.Restore
            ? FileLocationSource.Recycle
            : FileLocationSource.Shares;
        if (!PhotoBatchRecycleSourceIsCurrent(
                repository,
                sourceSpace,
                sourceRoot,
                items,
                recycleLocations,
                timelineMode,
                operation) ||
            FileRecycleBatchViewModel.Validate(
                _dataSource.ProfileId,
                sources,
                sourceRoot,
                locationSource,
                recycleLocations,
                sourceScope,
                operation) != FileRecycleBatchValidationStatus.Valid)
        {
            ShowPhotoBatchSelectionMessage(
                operation == FileRecycleOperation.Restore
                    ? "PhotoRestoreBatchSelectionInvalid"
                    : "PhotoRecycleBatchSelectionInvalid",
                InfoBarSeverity.Error,
                timelineMode: timelineMode);
            return;
        }

        var model = new FileRecycleBatchViewModel(
            repository,
            _dataSource.ProfileId,
            sources,
            recycleLocations,
            sourceRoot,
            sourceScope,
            operation,
            locationSource,
            _photoRecycleReviewBlocker);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            DefaultButton = ContentDialogButton.Primary,
        };
        _photoBatchRecycleModel = model;
        _photoBatchRecycleDialog = dialog;
        var localization = LocalizationService.Current;

        async Task RenderAsync()
        {
            if (_photoBatchRecycleModel != model || _photoBatchRecycleDialog != dialog)
            {
                return;
            }
            dialog.Title = localization.Get(operation == FileRecycleOperation.Restore
                ? "FileRestoreBatchTitle"
                : "FileRecycleBatchTitle");
            dialog.CloseButtonText = localization.Get(model.State is
                FileRecycleBatchState.Confirming or FileRecycleBatchState.Submitting
                    ? "FileRecycleCancelAction"
                    : "FileRecycleCloseAction");
            dialog.PrimaryButtonText = model.State == FileRecycleBatchState.Confirming
                ? localization.Format(operation == FileRecycleOperation.Restore
                    ? "FileRestoreBatchAction"
                    : "FileRecycleBatchMoveAction", sources.Length)
                : string.Empty;
            dialog.IsPrimaryButtonEnabled = model.CanSubmit;
            dialog.DefaultButton = model.CanSubmit
                ? ContentDialogButton.Primary
                : ContentDialogButton.Close;
            dialog.Content = FileRecycleBatchDialogContent.Build(
                model,
                localization,
                operation == FileRecycleOperation.Restore
                    ? "PhotoRestoreBatchConfirmMessage"
                    : "PhotoRecycleBatchConfirmMessage");
            await Task.CompletedTask;
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (!PhotoBatchRecycleSourceIsCurrent(
                    repository,
                    sourceSpace,
                    sourceRoot,
                    items,
                    recycleLocations,
                    timelineMode,
                    operation))
            {
                ShowPhotoBatchSelectionMessage(
                    operation == FileRecycleOperation.Restore
                        ? "PhotoRestoreBatchSourceChanged"
                        : "PhotoRecycleBatchSourceChanged",
                    InfoBarSeverity.Error,
                    timelineMode: timelineMode);
                return;
            }

            var deferral = args.GetDeferral();
            try
            {
                var submit = model.SubmitAsync();
                await RenderAsync();
                await submit;
                await RenderAsync();
            }
            finally
            {
                deferral.Complete();
            }
        };
        dialog.Closing += (sender, args) =>
        {
            if (_isClosingPhotoBatchRecycle || model.State != FileRecycleBatchState.Submitting)
            {
                return;
            }
            args.Cancel = true;
            model.Cancel();
            _ = RenderAsync();
        };

        await RenderAsync();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            model.Dispose();
            if (ReferenceEquals(_photoBatchRecycleModel, model))
            {
                _photoBatchRecycleModel = null;
            }
            if (ReferenceEquals(_photoBatchRecycleDialog, dialog))
            {
                _photoBatchRecycleDialog = null;
            }
            _isClosingPhotoBatchRecycle = false;
        }

        var completed = model.State == FileRecycleBatchState.Completed;
        var summary = model.Summary;
        if (timelineMode)
        {
            TimelineView.ExitBatchSelection();
        }
        else
        {
            ExitPhotoBatchSelection(closeStatus: false);
        }
        if (!completed || _disposed || !_isPhotoPageActive)
        {
            return;
        }
        if (summary.ConfirmedCount > 0 && repository.ProfileId == _dataSource.ProfileId)
        {
            await RefreshAfterPhotoRecycleAsync(
                sourceSpace,
                timelineMode ? sourceSpace.RootPath : sourceRoot,
                timelineMode);
        }
        if (timelineMode)
        {
            TimelineView.ShowRecycleBatchSummary(summary, operation);
        }
        else
        {
            ShowPhotoBatchSummary(summary, operation);
        }
        UpdateState();
    }

    private bool PhotoBatchRecycleSourceIsCurrent(
        IFileRecycleRepository repository,
        PhotoSpace sourceSpace,
        string sourceRoot,
        IReadOnlyList<PhotoItem> items,
        IReadOnlyList<FileRecycleLocation> recycleLocations,
        bool timelineMode,
        FileRecycleOperation operation)
    {
        if (_disposed || repository.ProfileId != _dataSource.ProfileId ||
            _viewModel.SelectedSpace?.Id != sourceSpace.Id ||
            timelineMode != (TimelineMode.IsChecked == true) ||
            !timelineMode && !string.Equals(_viewModel.CurrentPath, sourceRoot, StringComparison.Ordinal) ||
            timelineMode && !TimelineView.HasSelectedBatchItems(
                items,
                operation == FileRecycleOperation.Restore
                    ? PhotoBatchSelectionOperation.Restore
                    : PhotoBatchSelectionOperation.Recycle) ||
            !timelineMode &&
                (_photoBatchSelectionOperation !=
                    (operation == FileRecycleOperation.Restore
                        ? PhotoBatchSelectionOperation.Restore
                        : PhotoBatchSelectionOperation.Recycle) ||
                    !FolderSelectionMatches(items)))
        {
            return false;
        }

        foreach (var item in items)
        {
            if (!(operation == FileRecycleOperation.Restore
                    ? CanPhotoRecycleItemCore(item, FileRecycleOperation.Restore)
                    : CanSelectPhotoForBatchRecycle(item)))
            {
                return false;
            }
            if (operation == FileRecycleOperation.MoveToRecycle)
            {
                var frozenLocation = FileRecycleViewModel.FindRecycleLocation(
                    _dataSource.ProfileId,
                    item.Path,
                    recycleLocations);
                var currentLocation = FileRecycleViewModel.FindRecycleLocation(
                    _dataSource.ProfileId,
                    item.Path,
                    _photoRecycleLocations);
                if (frozenLocation is null || currentLocation is null ||
                    frozenLocation != currentLocation)
                {
                    return false;
                }
            }
        }
        return true;
    }

    private bool FolderSelectionMatches(IReadOnlyList<PhotoItem> items)
    {
        var selected = SelectedFolderPhotos();
        return selected.Count == items.Count &&
            selected.All(item => items.Any(candidate => SamePhotoItem(candidate, item)));
    }

    private void ExitPhotoBatchSelection(bool closeStatus = true)
    {
        if (!IsSelectingPhotoBatch)
        {
            return;
        }
        _isSynchronizingPhotoBatchSelection = true;
        PhotoGrid.SelectedItems.Clear();
        PhotoGrid.SelectionMode = ListViewSelectionMode.Single;
        _isSynchronizingPhotoBatchSelection = false;
        _photoBatchSelectionOperation = PhotoBatchSelectionOperation.None;
        if (closeStatus)
        {
            PhotoRecycleBatchStatus.IsOpen = false;
        }
        UpdateState();
    }

    private void ShowPhotoBatchSelectionMessage(
        string resourceKey,
        InfoBarSeverity severity,
        object? argument = null,
        bool timelineMode = false)
    {
        if (timelineMode)
        {
            TimelineView.ShowRecycleSelectionMessage(resourceKey, severity, argument);
            return;
        }
        PhotoRecycleBatchStatus.Severity = severity;
        PhotoRecycleBatchStatus.Message = argument is null
            ? LocalizationService.Current.Get(resourceKey)
            : LocalizationService.Current.Format(resourceKey, argument);
        PhotoRecycleBatchStatus.IsOpen = true;
    }

    private void ShowPhotoBatchSummary(
        FileRecycleBatchSummary summary,
        FileRecycleOperation operation)
    {
        PhotoRecycleBatchStatus.Severity = summary.NeedsReviewCount > 0 ||
            summary.FailedCount > 0 || summary.CancelledCount > 0 ||
            summary.NotStartedCount > 0
            ? InfoBarSeverity.Warning
            : InfoBarSeverity.Success;
        PhotoRecycleBatchStatus.Message = FileRecycleBatchDialogContent.FormatSummary(
            LocalizationService.Current,
            summary,
            operation);
        PhotoRecycleBatchStatus.IsOpen = true;
    }

    private void UpdatePhotoBatchControls()
    {
        var selectingSave = _photoBatchSelectionOperation == PhotoBatchSelectionOperation.Save;
        var selectingMove = _photoBatchSelectionOperation == PhotoBatchSelectionOperation.Move;
        var selectingCopy = _photoBatchSelectionOperation == PhotoBatchSelectionOperation.Copy;
        var selectingRecycle = _photoBatchSelectionOperation == PhotoBatchSelectionOperation.Recycle;
        var selectingRestore = _photoBatchSelectionOperation == PhotoBatchSelectionOperation.Restore;
        PhotoSaveMultipleButton.Visibility = IsSelectingPhotoBatch
            ? Visibility.Collapsed
            : Visibility.Visible;
        PhotoSaveMultipleButton.IsEnabled = CanEnterPhotoBatchSelection(
            PhotoBatchSelectionOperation.Save);
        PhotoSaveSelectedButton.Visibility = selectingSave
            ? Visibility.Visible
            : Visibility.Collapsed;
        PhotoSaveSelectedButton.IsEnabled = PhotoGrid.SelectedItems.Count is > 0 and <=
            BoundedFileDownloadBatch.MaximumFileCount && !_isChoosingPhotoBatchSaveTarget;
        PhotoCopyMultipleButton.Visibility = IsSelectingPhotoBatch
            ? Visibility.Collapsed
            : Visibility.Visible;
        PhotoCopyMultipleButton.IsEnabled = CanEnterPhotoBatchSelection(
            PhotoBatchSelectionOperation.Copy);
        PhotoMoveMultipleButton.Visibility = IsSelectingPhotoBatch
            ? Visibility.Collapsed
            : Visibility.Visible;
        PhotoMoveMultipleButton.IsEnabled = CanEnterPhotoBatchSelection(
            PhotoBatchSelectionOperation.Move);
        PhotoMoveMultipleToRecycleButton.Visibility = IsSelectingPhotoBatch
            ? Visibility.Collapsed
            : Visibility.Visible;
        PhotoMoveMultipleToRecycleButton.IsEnabled = CanEnterPhotoBatchSelection(
            PhotoBatchSelectionOperation.Recycle);
        PhotoRestoreMultipleButton.Visibility = IsSelectingPhotoBatch
            ? Visibility.Collapsed
            : Visibility.Visible;
        PhotoRestoreMultipleButton.IsEnabled = CanEnterPhotoBatchSelection(
            PhotoBatchSelectionOperation.Restore);
        PhotoMoveSelectedButton.Visibility = selectingMove
            ? Visibility.Visible
            : Visibility.Collapsed;
        PhotoCopySelectedButton.Visibility = selectingCopy
            ? Visibility.Visible
            : Visibility.Collapsed;
        PhotoMoveSelectedToRecycleButton.Visibility = selectingRecycle
            ? Visibility.Visible
            : Visibility.Collapsed;
        PhotoRestoreSelectedButton.Visibility = selectingRestore
            ? Visibility.Visible
            : Visibility.Collapsed;
        PhotoMoveSelectedButton.IsEnabled = PhotoGrid.SelectedItems.Count is > 0 and <=
            FileCopyMoveBatchViewModel.MaximumItemCount && _photoBatchCopyMoveDialog is null;
        PhotoCopySelectedButton.IsEnabled = PhotoMoveSelectedButton.IsEnabled;
        PhotoMoveSelectedToRecycleButton.IsEnabled = PhotoGrid.SelectedItems.Count is > 0 and <=
            FileRecycleBatchViewModel.MaximumItemCount;
        PhotoRestoreSelectedButton.IsEnabled = PhotoGrid.SelectedItems.Count is > 0 and <=
            FileRecycleBatchViewModel.MaximumItemCount;
        PhotoCancelRecycleSelectionButton.Visibility = IsSelectingPhotoBatch
            ? Visibility.Visible
            : Visibility.Collapsed;
        if (IsSelectingPhotoBatch)
        {
            BackButton.IsEnabled = false;
            UpButton.IsEnabled = false;
            RefreshButton.IsEnabled = false;
            OpenButton.IsEnabled = false;
            SaveButton.IsEnabled = false;
            PhotoShareLinkButton.IsEnabled = false;
            PhotoMoveButton.IsEnabled = false;
            PhotoMoveToRecycleButton.IsEnabled = false;
            PhotoRestoreFromRecycleButton.IsEnabled = false;
            FilterButton.IsEnabled = false;
            SpacePicker.IsEnabled = false;
            ImportButton.IsEnabled = false;
        }
    }

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
            PhotoBatchSelectionOperation.Restore => "PhotoRestoreBatchSelectionInvalid",
            PhotoBatchSelectionOperation.Copy => "PhotoCopyBatchSelectionInvalid",
            PhotoBatchSelectionOperation.Move => "PhotoMoveBatchSelectionInvalid",
            _ => "PhotoRecycleBatchSelectionInvalid",
        };

    private void ClosePhotoBatchRecycleDialog()
    {
        var dialog = _photoBatchRecycleDialog;
        var model = _photoBatchRecycleModel;
        _photoBatchRecycleDialog = null;
        _photoBatchRecycleModel = null;
        model?.Cancel();
        model?.Dispose();
        if (dialog is null)
        {
            return;
        }
        _isClosingPhotoBatchRecycle = true;
        dialog.Hide();
    }
}
