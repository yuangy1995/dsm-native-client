using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Photos.Timeline;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private IFileCopyMoveRepository? _photoCopyMoveRepository;
    private IFileCopyMoveFolderSource? _photoCopyMoveFolderSource;
    private FileCopyMoveReviewBlocker _photoCopyMoveReviewBlocker = FileCopyMoveReviewBlocker.Current;
    private FileCopyMoveViewModel? _photoCopyMoveModel;
    private ContentDialog? _photoCopyMoveDialog;
    private bool _isClosingPhotoCopyMove;
    private long _photoCopyMoveSourceRevision;

    private void InitializePhotoCopyMove(
        IFileCopyMoveRepository? repository,
        IFileCopyMoveFolderSource? folderSource,
        FileCopyMoveReviewBlocker? blocker)
    {
        if (repository is not null && repository.ProfileId != _dataSource.ProfileId)
        {
            throw new ArgumentException(
                "The copy/move repository must match the active photo profile.",
                nameof(repository));
        }
        if (folderSource is not null && folderSource.ProfileId != _dataSource.ProfileId)
        {
            throw new ArgumentException(
                "The copy/move folder source must match the active photo profile.",
                nameof(folderSource));
        }

        _photoCopyMoveRepository = repository;
        _photoCopyMoveFolderSource = folderSource;
        _photoCopyMoveReviewBlocker = blocker ?? FileCopyMoveReviewBlocker.Current;
    }

    private async void MovePhoto_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.SelectedItem is { } entry)
        {
            await ShowPhotoMoveAsync(entry.Item);
        }
    }

    private bool CanMoveSelectedPhoto() =>
        _viewModel.SelectedItem is { } entry && CanMovePhoto(entry.Item);

    private bool CanMovePhoto(PhotoItem item) =>
        _photoCopyMoveDialog is null &&
        _photoBatchCopyMoveDialog is null &&
        _photoRecycleDialog is null &&
        _photoBatchRecycleDialog is null &&
        !IsSelectingPhotoBatch &&
        !_isClosingPhotoCopyMove &&
        CanMovePhotoCore(item);

    private bool CanMovePhotoCore(PhotoItem item) =>
        !_disposed &&
        _photoCopyMoveRepository is { } repository &&
        _photoCopyMoveFolderSource is { } folders &&
        repository.ProfileId == _dataSource.ProfileId &&
        folders.ProfileId == _dataSource.ProfileId &&
        repository.Availability.CanMove &&
        _viewModel.ActiveProfileId == _dataSource.ProfileId &&
        _viewModel.SelectedSpace is { } space &&
        PhotoTimelineViewModel.ContainsCanonicalPath(space.RootPath, item.Path) &&
        !HasRecyclePathSegment(item.Path) &&
        ToRecycleFileItem(item) is not null &&
        ParentPath(item.Path) is not null;

    private bool CanCopyPhotoCore(PhotoItem item) =>
        !_disposed &&
        _photoCopyMoveRepository is { } repository &&
        _photoCopyMoveFolderSource is { } folders &&
        repository.ProfileId == _dataSource.ProfileId &&
        folders.ProfileId == _dataSource.ProfileId &&
        repository.Availability.CanCopy &&
        _viewModel.ActiveProfileId == _dataSource.ProfileId &&
        _viewModel.SelectedSpace is { } space &&
        PhotoTimelineViewModel.ContainsCanonicalPath(space.RootPath, item.Path) &&
        !HasRecyclePathSegment(item.Path) &&
        ToRecycleFileItem(item) is not null &&
        ParentPath(item.Path) is not null;

    private Task MovePhotoAsync(PhotoItem item) => ShowPhotoMoveAsync(item);

    private async Task ShowPhotoMoveAsync(PhotoItem item)
    {
        if (!CanMovePhoto(item) ||
            _photoCopyMoveRepository is not { } repository ||
            _photoCopyMoveFolderSource is not { } folders ||
            ToRecycleFileItem(item) is not { } source ||
            ParentPath(item.Path) is not { } sourceParent ||
            _viewModel.SelectedSpace is not { } sourceSpace)
        {
            return;
        }

        var timelineMode = TimelineMode.IsChecked == true;
        var revision = Interlocked.Increment(ref _photoCopyMoveSourceRevision);
        if (!CanMovePhotoCore(item) || !IsCurrentPhotoCopyMoveSelection(item, timelineMode))
        {
            return;
        }

        var model = new FileCopyMoveViewModel(
            repository,
            folders,
            _dataSource.ProfileId,
            source,
            FileCopyMoveOperation.Move,
            revision,
            _photoCopyMoveReviewBlocker);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            DefaultButton = ContentDialogButton.Primary,
        };
        var localization = LocalizationService.Current;
        _photoCopyMoveModel = model;
        _photoCopyMoveDialog = dialog;

        async Task RenderAsync()
        {
            if (_photoCopyMoveModel != model || _photoCopyMoveDialog != dialog)
            {
                return;
            }

            dialog.Title = localization.Get(FileCopyMoveDialogContent.TitleKey(
                model.Source.IsDirectory,
                FileCopyMoveOperation.Move));
            dialog.CloseButtonText = localization.Get(model.State is
                FileCopyMovePresentationState.ChoosingDestination or
                FileCopyMovePresentationState.LoadingFolders or
                FileCopyMovePresentationState.Submitting
                    ? "FileCopyMove_Cancel_Button"
                    : "FileCopyMove_Close_Button");
            dialog.PrimaryButtonText = model.State switch
            {
                FileCopyMovePresentationState.ChoosingDestination =>
                    localization.Get("FileCopyMove_Move_Button"),
                FileCopyMovePresentationState.CancelledBeforeSubmission =>
                    localization.Get("FileCopyMove_ChooseDestination_Button"),
                _ => string.Empty,
            };
            dialog.IsPrimaryButtonEnabled = model.CanSubmit ||
                model.State == FileCopyMovePresentationState.CancelledBeforeSubmission;
            dialog.DefaultButton = string.IsNullOrEmpty(dialog.PrimaryButtonText)
                ? ContentDialogButton.Close
                : ContentDialogButton.Primary;
            dialog.Content = FileCopyMoveDialogContent.Build(model, localization, RenderAsync);
            await Task.CompletedTask;
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (!IsCurrentPhotoMoveRequest(
                    repository,
                    folders,
                    model,
                    item,
                    sourceSpace,
                    sourceParent,
                    timelineMode))
            {
                return;
            }
            if (model.State == FileCopyMovePresentationState.CancelledBeforeSubmission)
            {
                model.ReturnToForm();
                await RenderAsync();
                return;
            }

            var deferral = args.GetDeferral();
            try
            {
                await ClosePhotoViewerAsync(restoreBrowserFocus: false);
                if (!IsCurrentPhotoMoveRequest(
                        repository,
                        folders,
                        model,
                        item,
                        sourceSpace,
                        sourceParent,
                        timelineMode))
                {
                    return;
                }

                var operation = model.SubmitAsync();
                await RenderAsync();
                await operation;
                args.Cancel = model.State != FileCopyMovePresentationState.ConfirmedSuccess;
                if (args.Cancel)
                {
                    await RenderAsync();
                }
            }
            finally
            {
                deferral.Complete();
            }
        };
        dialog.Closing += (sender, args) =>
        {
            if (_isClosingPhotoCopyMove ||
                model.State != FileCopyMovePresentationState.Submitting)
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
            if (loaded) return;
            loaded = true;
            var load = model.LoadFoldersAsync(string.Empty);
            await RenderAsync();
            await load;
            await RenderAsync();
        };

        var confirmed = false;
        try
        {
            await dialog.ShowAsync();
            confirmed = model.State == FileCopyMovePresentationState.ConfirmedSuccess;
        }
        finally
        {
            model.Dispose();
            if (ReferenceEquals(_photoCopyMoveModel, model)) _photoCopyMoveModel = null;
            if (ReferenceEquals(_photoCopyMoveDialog, dialog)) _photoCopyMoveDialog = null;
            _isClosingPhotoCopyMove = false;
        }

        if (confirmed && !_disposed && repository.ProfileId == _dataSource.ProfileId)
        {
            await RefreshAfterPhotoMoveAsync(sourceSpace, sourceParent, timelineMode);
        }
        if (!_disposed)
        {
            UpdateState();
        }
    }

    private bool IsCurrentPhotoMoveRequest(
        IFileCopyMoveRepository repository,
        IFileCopyMoveFolderSource folders,
        FileCopyMoveViewModel model,
        PhotoItem item,
        PhotoSpace sourceSpace,
        string sourceParent,
        bool timelineMode) =>
        !_disposed &&
        repository.ProfileId == _dataSource.ProfileId &&
        folders.ProfileId == _dataSource.ProfileId &&
        model.SourceRevision == _photoCopyMoveSourceRevision &&
        _viewModel.SelectedSpace?.Id == sourceSpace.Id &&
        string.Equals(ParentPath(item.Path), sourceParent, StringComparison.Ordinal) &&
        CanMovePhotoCore(item) &&
        IsCurrentPhotoCopyMoveSelection(item, timelineMode);

    private async Task RefreshAfterPhotoMoveAsync(
        PhotoSpace sourceSpace,
        string sourceParent,
        bool timelineMode)
    {
        if (_viewModel.SelectedSpace?.Id != sourceSpace.Id)
        {
            return;
        }
        if (timelineMode && TimelineMode.IsChecked == true)
        {
            await TimelineView.RefreshAsync();
        }
        else if (TimelineMode.IsChecked != true &&
            string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal))
        {
            await RunLocationChangeAsync(_viewModel.RefreshAsync);
        }
    }

    private bool IsCurrentPhotoCopyMoveSelection(PhotoItem item, bool timelineMode) =>
        timelineMode
            ? TimelineMode.IsChecked == true && TimelineView.HasSelectedItem(item)
            : TimelineMode.IsChecked != true &&
                _viewModel.SelectedItem is { } entry &&
                SamePhotoItem(entry.Item, item);

    private void UpdatePhotoCopyMoveControls()
    {
        var canMove = CanMoveSelectedPhoto();
        PhotoMoveButton.IsEnabled = canMove;
        PhotoMoveButton.Visibility = canMove ? Visibility.Visible : Visibility.Collapsed;
        TimelineView.RefreshActionState();
    }

    private void ClosePhotoCopyMoveDialog()
    {
        var dialog = _photoCopyMoveDialog;
        var model = _photoCopyMoveModel;
        _photoCopyMoveDialog = null;
        _photoCopyMoveModel = null;
        model?.Cancel();
        model?.Dispose();
        if (dialog is null)
        {
            return;
        }
        _isClosingPhotoCopyMove = true;
        dialog.Hide();
    }
}
