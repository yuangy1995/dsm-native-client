using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.Photos;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private FileRecycleBatchViewModel? _photoBatchRecycleModel;
    private ContentDialog? _photoBatchRecycleDialog;
    private bool _isClosingPhotoBatchRecycle;
    private bool _isSelectingPhotoRecycle;
    private bool _isSynchronizingPhotoRecycleSelection;

    private async void MoveMultiplePhotosToRecycle_Click(object sender, RoutedEventArgs e)
    {
        await ClosePhotoViewerAsync();
        EnterPhotoRecycleSelection();
    }

    private async void MoveSelectedPhotosToRecycle_Click(object sender, RoutedEventArgs e) =>
        await ShowPhotoBatchRecycleAsync(SelectedFolderPhotosForRecycle(), timelineMode: false);

    private void CancelPhotoRecycleSelection_Click(object sender, RoutedEventArgs e) =>
        ExitPhotoRecycleSelection();

    private void EnterPhotoRecycleSelection()
    {
        if (!CanEnterPhotoRecycleSelection())
        {
            return;
        }

        var selected = _viewModel.SelectedItem;
        _isSynchronizingPhotoRecycleSelection = true;
        PhotoGrid.SelectedItems.Clear();
        PhotoGrid.SelectionMode = ListViewSelectionMode.Multiple;
        if (selected is not null && CanSelectPhotoForBatchRecycle(selected.Item))
        {
            PhotoGrid.SelectedItems.Add(selected);
        }
        _isSynchronizingPhotoRecycleSelection = false;
        _isSelectingPhotoRecycle = true;
        ShowPhotoBatchSelectionMessage(
            "FileRecycleBatchSelectionCount",
            InfoBarSeverity.Informational,
            PhotoGrid.SelectedItems.Count);
        UpdateState();
    }

    private bool CanEnterPhotoRecycleSelection() =>
        !_disposed && !_viewModel.IsLoading && !_isSelectingPhotoRecycle &&
        _photoRecycleDialog is null && _photoBatchRecycleDialog is null &&
        !_isClosingPhotoRecycle && !_isClosingPhotoBatchRecycle &&
        TimelineMode.IsChecked != true &&
        _viewModel.Items.Any(entry => CanSelectPhotoForBatchRecycle(entry.Item));

    private bool CanSelectPhotoForBatchRecycle(PhotoItem item) =>
        CanPhotoRecycleItemCore(item, FileRecycleOperation.MoveToRecycle);

    private void HandlePhotoRecycleSelectionChanged(SelectionChangedEventArgs args)
    {
        if (!_isSelectingPhotoRecycle || _isSynchronizingPhotoRecycleSelection)
        {
            return;
        }

        var rejected = false;
        var rejectedForLimit = false;
        foreach (var added in args.AddedItems.OfType<PhotoBrowserEntry>())
        {
            if (!CanSelectPhotoForBatchRecycle(added.Item) ||
                PhotoGrid.SelectedItems.Count > FileRecycleBatchViewModel.MaximumItemCount)
            {
                rejectedForLimit |= PhotoGrid.SelectedItems.Count >
                    FileRecycleBatchViewModel.MaximumItemCount;
                _isSynchronizingPhotoRecycleSelection = true;
                PhotoGrid.SelectedItems.Remove(added);
                _isSynchronizingPhotoRecycleSelection = false;
                rejected = true;
            }
        }
        ShowPhotoBatchSelectionMessage(
            rejected
                ? rejectedForLimit
                    ? "FileRecycleBatchSelectionLimit"
                    : "PhotoRecycleBatchSelectionInvalid"
                : "FileRecycleBatchSelectionCount",
            rejected ? InfoBarSeverity.Warning : InfoBarSeverity.Informational,
            rejected ? null : PhotoGrid.SelectedItems.Count);
    }

    private IReadOnlyList<PhotoItem> SelectedFolderPhotosForRecycle() =>
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
            TimelineView.ExitRecycleSelection();
        }
        else
        {
            ExitPhotoRecycleSelection(closeStatus: false);
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
            timelineMode && !TimelineView.HasSelectedRecycleItems(items) ||
            !timelineMode && !FolderSelectionMatches(items))
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
        var selected = SelectedFolderPhotosForRecycle();
        return _isSelectingPhotoRecycle && selected.Count == items.Count &&
            selected.All(item => items.Any(candidate => SamePhotoItem(candidate, item)));
    }

    private void ExitPhotoRecycleSelection(bool closeStatus = true)
    {
        if (!_isSelectingPhotoRecycle)
        {
            return;
        }
        _isSynchronizingPhotoRecycleSelection = true;
        PhotoGrid.SelectedItems.Clear();
        PhotoGrid.SelectionMode = ListViewSelectionMode.Single;
        _isSynchronizingPhotoRecycleSelection = false;
        _isSelectingPhotoRecycle = false;
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

    private void UpdatePhotoBatchRecycleControls()
    {
        var canEnter = CanEnterPhotoRecycleSelection();
        PhotoMoveMultipleToRecycleButton.Visibility = _isSelectingPhotoRecycle
            ? Visibility.Collapsed
            : Visibility.Visible;
        PhotoMoveMultipleToRecycleButton.IsEnabled = canEnter;
        PhotoMoveSelectedToRecycleButton.Visibility = _isSelectingPhotoRecycle
            ? Visibility.Visible
            : Visibility.Collapsed;
        PhotoMoveSelectedToRecycleButton.IsEnabled = PhotoGrid.SelectedItems.Count is > 0 and <=
            FileRecycleBatchViewModel.MaximumItemCount;
        PhotoCancelRecycleSelectionButton.Visibility = _isSelectingPhotoRecycle
            ? Visibility.Visible
            : Visibility.Collapsed;
        if (_isSelectingPhotoRecycle)
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
