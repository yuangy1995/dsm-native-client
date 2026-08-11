using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Photos;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private FileCopyMoveBatchViewModel? _photoBatchCopyMoveModel;
    private ContentDialog? _photoBatchCopyMoveDialog;
    private bool _isClosingPhotoBatchCopyMove;

    private async void MoveMultiplePhotos_Click(object sender, RoutedEventArgs e)
    {
        await ClosePhotoViewerAsync();
        EnterPhotoBatchSelection(PhotoBatchSelectionOperation.Move);
    }

    private async void MoveSelectedPhotos_Click(object sender, RoutedEventArgs e) =>
        await ShowPhotoBatchMoveAsync(SelectedFolderPhotos(), timelineMode: false);

    private Task MoveMultiplePhotosAsync(IReadOnlyList<PhotoItem> items) =>
        ShowPhotoBatchMoveAsync(items, timelineMode: true);

    private async Task ShowPhotoBatchMoveAsync(
        IReadOnlyList<PhotoItem> items,
        bool timelineMode)
    {
        if (_disposed || !_isPhotoPageActive ||
            _photoBatchCopyMoveDialog is not null ||
            _photoBatchCopyMoveModel is not null ||
            _isClosingPhotoBatchCopyMove ||
            _photoCopyMoveRepository is not { } repository ||
            _photoCopyMoveFolderSource is not { } folders ||
            _viewModel.SelectedSpace is not { } sourceSpace ||
            timelineMode != (TimelineMode.IsChecked == true) ||
            items.Select(ToRecycleFileItem).Any(item => item is null))
        {
            return;
        }

        var sources = items.Select(ToRecycleFileItem).OfType<FileItem>().ToArray();
        var sourceRoot = timelineMode ? sourceSpace.RootPath : _viewModel.CurrentPath;
        var sourceScope = timelineMode
            ? FileCopyMoveBatchSourceScope.DescendantsOfRoot
            : FileCopyMoveBatchSourceScope.CurrentFolder;
        if (!PhotoBatchMoveSourceIsCurrent(
                repository,
                folders,
                sourceSpace,
                sourceRoot,
                items,
                timelineMode) ||
            FileCopyMoveBatchViewModel.Validate(
                sources,
                FileCopyMoveOperation.Move,
                sourceRoot,
                sourceScope) != FileCopyMoveBatchValidationStatus.Valid)
        {
            ShowPhotoBatchSelectionMessage(
                "PhotoMoveBatchSelectionInvalid",
                InfoBarSeverity.Error,
                timelineMode: timelineMode);
            return;
        }

        var model = new FileCopyMoveBatchViewModel(
            repository,
            folders,
            _dataSource.ProfileId,
            sources,
            FileCopyMoveOperation.Move,
            sourceRoot,
            sourceScope,
            _photoCopyMoveReviewBlocker);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            DefaultButton = ContentDialogButton.Primary,
        };
        _photoBatchCopyMoveModel = model;
        _photoBatchCopyMoveDialog = dialog;
        var localization = LocalizationService.Current;

        async Task RenderAsync()
        {
            if (_photoBatchCopyMoveModel != model || _photoBatchCopyMoveDialog != dialog)
            {
                return;
            }
            dialog.Title = localization.Get("FileCopyMoveBatchMoveTitle");
            dialog.CloseButtonText = localization.Get(
                model.State is FileCopyMoveBatchState.Submitting or
                    FileCopyMoveBatchState.ChoosingDestination or
                    FileCopyMoveBatchState.LoadingFolders
                    ? "FileCopyMove_Cancel_Button"
                    : "FileCopyMove_Close_Button");
            dialog.PrimaryButtonText = model.State == FileCopyMoveBatchState.ChoosingDestination
                ? localization.Format("FileCopyMoveBatchMoveButton", sources.Length)
                : string.Empty;
            dialog.IsPrimaryButtonEnabled = model.CanSubmit;
            dialog.DefaultButton = string.IsNullOrEmpty(dialog.PrimaryButtonText)
                ? ContentDialogButton.Close
                : ContentDialogButton.Primary;
            dialog.Content = FilesPage.BuildBatchCopyMoveContent(model, localization, RenderAsync);
            await Task.CompletedTask;
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (!PhotoBatchMoveSourceIsCurrent(
                    repository,
                    folders,
                    sourceSpace,
                    sourceRoot,
                    items,
                    timelineMode))
            {
                ShowPhotoBatchSelectionMessage(
                    "PhotoMoveBatchSourceChanged",
                    InfoBarSeverity.Error,
                    timelineMode: timelineMode);
                return;
            }

            var deferral = args.GetDeferral();
            try
            {
                await ClosePhotoViewerAsync(restoreBrowserFocus: false);
                if (!PhotoBatchMoveSourceIsCurrent(
                        repository,
                        folders,
                        sourceSpace,
                        sourceRoot,
                        items,
                        timelineMode))
                {
                    return;
                }
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
            if (_isClosingPhotoBatchCopyMove ||
                model.State != FileCopyMoveBatchState.Submitting)
            {
                return;
            }
            args.Cancel = true;
            model.Cancel();
            _ = RenderAsync();
        };

        await RenderAsync();
        var loaded = false;
        dialog.Loaded += async (_, _) =>
        {
            if (loaded)
            {
                return;
            }
            loaded = true;
            var load = model.LoadFoldersAsync(string.Empty);
            await RenderAsync();
            await load;
            await RenderAsync();
        };

        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            model.Dispose();
            if (ReferenceEquals(_photoBatchCopyMoveModel, model))
            {
                _photoBatchCopyMoveModel = null;
            }
            if (ReferenceEquals(_photoBatchCopyMoveDialog, dialog))
            {
                _photoBatchCopyMoveDialog = null;
            }
            _isClosingPhotoBatchCopyMove = false;
        }

        var completed = model.State == FileCopyMoveBatchState.Completed;
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
            await RefreshAfterPhotoMoveAsync(
                sourceSpace,
                timelineMode ? sourceSpace.RootPath : sourceRoot,
                timelineMode);
        }
        if (timelineMode)
        {
            TimelineView.ShowMoveBatchSummary(summary);
        }
        else
        {
            PhotoRecycleBatchStatus.Severity = summary.NeedsReviewCount > 0 ||
                summary.FailedCount > 0 || summary.CancelledCount > 0 ||
                summary.NotStartedCount > 0
                ? InfoBarSeverity.Warning
                : InfoBarSeverity.Success;
            PhotoRecycleBatchStatus.Message = FilesPage.FormatBatchCopyMoveSummary(
                localization,
                summary,
                FileCopyMoveOperation.Move);
            PhotoRecycleBatchStatus.IsOpen = true;
        }
        UpdateState();
    }

    private bool PhotoBatchMoveSourceIsCurrent(
        IFileCopyMoveRepository repository,
        IFileCopyMoveFolderSource folders,
        PhotoSpace sourceSpace,
        string sourceRoot,
        IReadOnlyList<PhotoItem> items,
        bool timelineMode) =>
        !_disposed && repository.ProfileId == _dataSource.ProfileId &&
        folders.ProfileId == _dataSource.ProfileId &&
        _viewModel.SelectedSpace?.Id == sourceSpace.Id &&
        timelineMode == (TimelineMode.IsChecked == true) &&
        (timelineMode
            ? TimelineView.HasSelectedBatchItems(items, PhotoBatchSelectionOperation.Move)
            : string.Equals(_viewModel.CurrentPath, sourceRoot, StringComparison.Ordinal) &&
                _photoBatchSelectionOperation == PhotoBatchSelectionOperation.Move &&
                FolderSelectionMatches(items)) &&
        items.All(CanMovePhotoCore);

    private void ClosePhotoBatchCopyMoveDialog()
    {
        var dialog = _photoBatchCopyMoveDialog;
        var model = _photoBatchCopyMoveModel;
        _photoBatchCopyMoveDialog = null;
        _photoBatchCopyMoveModel = null;
        model?.Cancel();
        model?.Dispose();
        if (dialog is null)
        {
            return;
        }
        _isClosingPhotoBatchCopyMove = true;
        dialog.Hide();
    }
}
