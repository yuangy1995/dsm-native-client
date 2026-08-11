using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.Photos;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

internal enum PhotoBatchSelectionOperation
{
    None,
    Copy,
    Move,
    Recycle,
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
        await ShowPhotoBatchRecycleAsync(SelectedFolderPhotos(), timelineMode: false);

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
            PhotoBatchSelectionOperation.Copy => CanCopyPhotoCore(item),
            PhotoBatchSelectionOperation.Move => CanMovePhotoCore(item),
            PhotoBatchSelectionOperation.Recycle => CanSelectPhotoForBatchRecycle(item),
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
        ShowPhotoBatchRecycleAsync(items, timelineMode: true);

    private async Task ShowPhotoBatchRecycleAsync(
        IReadOnlyList<PhotoItem> items,
        bool timelineMode)
    {
        if (_disposed || !_isPhotoPageActive ||
            _photoBatchRecycleDialog is not null ||
            _photoBatchRecycleModel is not null ||
            _isClosingPhotoBatchRecycle ||
            _photoRecycleRepository is not { } repository ||
            _viewModel.SelectedSpace is not { } sourceSpace ||
            timelineMode != (TimelineMode.IsChecked == true) ||
            items.Select(ToRecycleFileItem).Any(item => item is null))
        {
            return;
        }

        var sources = items.Select(ToRecycleFileItem).OfType<FileItem>().ToArray();
        var sourceRoot = timelineMode ? sourceSpace.RootPath : _viewModel.CurrentPath;
        var sourceScope = timelineMode
            ? FileRecycleBatchSourceScope.DescendantsOfRoot
            : FileRecycleBatchSourceScope.CurrentFolder;
        var recycleLocations = _photoRecycleLocations.ToArray();
        if (!PhotoBatchRecycleSourceIsCurrent(
                repository,
                sourceSpace,
                sourceRoot,
                items,
                recycleLocations,
                timelineMode) ||
            FileRecycleBatchViewModel.Validate(
                _dataSource.ProfileId,
                sources,
                sourceRoot,
                FileLocationSource.Shares,
                recycleLocations,
                sourceScope) != FileRecycleBatchValidationStatus.Valid)
        {
            ShowPhotoBatchSelectionMessage(
                "PhotoRecycleBatchSelectionInvalid",
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
            dialog.Title = localization.Get("FileRecycleBatchTitle");
            dialog.CloseButtonText = localization.Get(model.State is
                FileRecycleBatchState.Confirming or FileRecycleBatchState.Submitting
                    ? "FileRecycleCancelAction"
                    : "FileRecycleCloseAction");
            dialog.PrimaryButtonText = model.State == FileRecycleBatchState.Confirming
                ? localization.Format("FileRecycleBatchMoveAction", sources.Length)
                : string.Empty;
            dialog.IsPrimaryButtonEnabled = model.CanSubmit;
            dialog.DefaultButton = model.CanSubmit
                ? ContentDialogButton.Primary
                : ContentDialogButton.Close;
            dialog.Content = FileRecycleBatchDialogContent.Build(
                model,
                localization,
                "PhotoRecycleBatchConfirmMessage");
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
                    timelineMode))
            {
                ShowPhotoBatchSelectionMessage(
                    "PhotoRecycleBatchSourceChanged",
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
            TimelineView.ShowRecycleBatchSummary(summary);
        }
        else
        {
            ShowPhotoBatchSummary(summary);
        }
        UpdateState();
    }

    private bool PhotoBatchRecycleSourceIsCurrent(
        IFileRecycleRepository repository,
        PhotoSpace sourceSpace,
        string sourceRoot,
        IReadOnlyList<PhotoItem> items,
        IReadOnlyList<FileRecycleLocation> recycleLocations,
        bool timelineMode)
    {
        if (_disposed || repository.ProfileId != _dataSource.ProfileId ||
            _viewModel.SelectedSpace?.Id != sourceSpace.Id ||
            timelineMode != (TimelineMode.IsChecked == true) ||
            !timelineMode && !string.Equals(_viewModel.CurrentPath, sourceRoot, StringComparison.Ordinal) ||
            timelineMode && !TimelineView.HasSelectedBatchItems(
                items,
                PhotoBatchSelectionOperation.Recycle) ||
            !timelineMode &&
                (_photoBatchSelectionOperation != PhotoBatchSelectionOperation.Recycle ||
                    !FolderSelectionMatches(items)))
        {
            return false;
        }

        foreach (var item in items)
        {
            if (!CanSelectPhotoForBatchRecycle(item))
            {
                return false;
            }
            var frozenLocation = FileRecycleViewModel.FindRecycleLocation(
                _dataSource.ProfileId,
                item.Path,
                recycleLocations);
            var currentLocation = FileRecycleViewModel.FindRecycleLocation(
                _dataSource.ProfileId,
                item.Path,
                _photoRecycleLocations);
            if (frozenLocation is null || currentLocation is null || frozenLocation != currentLocation)
            {
                return false;
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

    private void ShowPhotoBatchSummary(FileRecycleBatchSummary summary)
    {
        PhotoRecycleBatchStatus.Severity = summary.NeedsReviewCount > 0 ||
            summary.FailedCount > 0 || summary.CancelledCount > 0 ||
            summary.NotStartedCount > 0
            ? InfoBarSeverity.Warning
            : InfoBarSeverity.Success;
        PhotoRecycleBatchStatus.Message = FileRecycleBatchDialogContent.FormatSummary(
            LocalizationService.Current,
            summary);
        PhotoRecycleBatchStatus.IsOpen = true;
    }

    private void UpdatePhotoBatchControls()
    {
        var selectingMove = _photoBatchSelectionOperation == PhotoBatchSelectionOperation.Move;
        var selectingCopy = _photoBatchSelectionOperation == PhotoBatchSelectionOperation.Copy;
        var selectingRecycle = _photoBatchSelectionOperation == PhotoBatchSelectionOperation.Recycle;
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
        PhotoMoveSelectedButton.Visibility = selectingMove
            ? Visibility.Visible
            : Visibility.Collapsed;
        PhotoCopySelectedButton.Visibility = selectingCopy
            ? Visibility.Visible
            : Visibility.Collapsed;
        PhotoMoveSelectedToRecycleButton.Visibility = selectingRecycle
            ? Visibility.Visible
            : Visibility.Collapsed;
        PhotoMoveSelectedButton.IsEnabled = PhotoGrid.SelectedItems.Count is > 0 and <=
            FileCopyMoveBatchViewModel.MaximumItemCount && _photoBatchCopyMoveDialog is null;
        PhotoCopySelectedButton.IsEnabled = PhotoMoveSelectedButton.IsEnabled;
        PhotoMoveSelectedToRecycleButton.IsEnabled = PhotoGrid.SelectedItems.Count is > 0 and <=
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
            PhotoMoveButton.IsEnabled = false;
            PhotoMoveToRecycleButton.IsEnabled = false;
            PhotoRestoreFromRecycleButton.IsEnabled = false;
            FilterButton.IsEnabled = false;
            SpacePicker.IsEnabled = false;
            ImportButton.IsEnabled = false;
        }
    }

    private static string SelectionCountResource(PhotoBatchSelectionOperation operation) =>
        operation is PhotoBatchSelectionOperation.Copy or PhotoBatchSelectionOperation.Move
            ? "FileCopyMoveBatchSelectionCount"
            : "FileRecycleBatchSelectionCount";

    private static string SelectionLimitResource(PhotoBatchSelectionOperation operation) =>
        operation is PhotoBatchSelectionOperation.Copy or PhotoBatchSelectionOperation.Move
            ? "FileCopyMoveBatchSelectionLimit"
            : "FileRecycleBatchSelectionLimit";

    private static string SelectionInvalidResource(PhotoBatchSelectionOperation operation) =>
        operation switch
        {
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
