using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Features.Photos.Timeline;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class PhotosPage
{
    private IFileRecycleRepository? _photoRecycleRepository;
    private FileRecycleReviewBlocker _photoRecycleReviewBlocker = FileRecycleReviewBlocker.Current;
    private FileRecycleViewModel? _photoRecycleModel;
    private ContentDialog? _photoRecycleDialog;
    private bool _isClosingPhotoRecycle;
    private long _photoRecycleSourceRevision;

    private void InitializePhotoRecycle(
        IFileRecycleRepository? repository,
        FileRecycleReviewBlocker? blocker)
    {
        if (repository is not null && repository.ProfileId != _dataSource.ProfileId)
        {
            throw new ArgumentException(
                "The recycle repository must match the active photo profile.",
                nameof(repository));
        }

        _photoRecycleRepository = repository;
        _photoRecycleReviewBlocker = blocker ?? FileRecycleReviewBlocker.Current;
    }

    private async void RestorePhotoFromRecycle_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.SelectedItem is { } entry)
        {
            await RestorePhotoItemAsync(entry.Item);
        }
    }

    private bool CanRestoreSelectedPhoto() =>
        _viewModel.SelectedItem is { } entry && CanOpenPhotoRecycleDialog(entry.Item);

    private bool CanRestorePhotoItem(PhotoItem item) =>
        CanOpenPhotoRecycleDialog(item);

    private bool CanOpenPhotoRecycleDialog(PhotoItem item) =>
        _photoRecycleDialog is null &&
        !_isClosingPhotoRecycle &&
        CanRestorePhotoItemCore(item);

    private bool CanRestorePhotoItemCore(PhotoItem item)
    {
        if (_disposed ||
            _photoRecycleRepository is not { Availability: { CanRestore: true }, ProfileId: var profileId } ||
            profileId != _dataSource.ProfileId ||
            _viewModel.ActiveProfileId != _dataSource.ProfileId ||
            _viewModel.SelectedSpace is not { } space ||
            !PhotoTimelineViewModel.ContainsCanonicalPath(space.RootPath, item.Path) ||
            ToRecycleFileItem(item) is not { } source ||
            ParentPath(item.Path) is not { } sourceParent)
        {
            return false;
        }

        return FileRecycleViewModel.CanRestore(
            _dataSource.ProfileId,
            source,
            sourceParent,
            FileLocationSource.Recycle);
    }

    private async Task RestorePhotoItemAsync(PhotoItem item)
    {
        if (!CanOpenPhotoRecycleDialog(item) ||
            _photoRecycleRepository is not { } repository ||
            ToRecycleFileItem(item) is not { } source ||
            ParentPath(item.Path) is not { } sourceParent ||
            _viewModel.SelectedSpace is not { } sourceSpace)
        {
            return;
        }

        var timelineMode = TimelineMode.IsChecked == true;
        var revision = Interlocked.Increment(ref _photoRecycleSourceRevision);
        var model = new FileRecycleViewModel(
            repository,
            _dataSource.ProfileId,
            source,
            FileRecycleOperation.Restore,
            revision,
            null,
            _photoRecycleReviewBlocker);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Primary };
        var localization = LocalizationService.Current;
        _photoRecycleModel = model;
        _photoRecycleDialog = dialog;

        async Task RenderAsync()
        {
            if (_photoRecycleModel != model || _photoRecycleDialog != dialog)
            {
                return;
            }

            dialog.Title = localization.Get("FileRecycleRestoreTitle");
            dialog.CloseButtonText = localization.Get(model.State is
                FileRecyclePresentationState.Confirming or
                FileRecyclePresentationState.Submitting
                    ? "FileRecycleCancelAction"
                    : "FileRecycleCloseAction");
            dialog.PrimaryButtonText = model.State switch
            {
                FileRecyclePresentationState.Confirming => localization.Get("FileRecycleRestoreAction"),
                FileRecyclePresentationState.CancelledBeforeSubmission =>
                    localization.Get("FileRecycleReturnToConfirmAction"),
                _ => string.Empty,
            };
            dialog.IsPrimaryButtonEnabled = model.CanSubmit ||
                model.State == FileRecyclePresentationState.CancelledBeforeSubmission;
            dialog.DefaultButton = string.IsNullOrEmpty(dialog.PrimaryButtonText)
                ? ContentDialogButton.Close
                : ContentDialogButton.Primary;
            dialog.Content = FileRecycleDialogContent.Build(model, localization);
            await Task.CompletedTask;
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (_disposed ||
                repository.ProfileId != _dataSource.ProfileId ||
                model.SourceRevision != _photoRecycleSourceRevision ||
                !CanRestorePhotoItemCore(item) ||
                !IsCurrentPhotoRecycleSelection(item, timelineMode))
            {
                return;
            }
            if (model.State == FileRecyclePresentationState.CancelledBeforeSubmission)
            {
                model.ReturnToConfirm();
                await RenderAsync();
                return;
            }

            var deferral = args.GetDeferral();
            try
            {
                var operation = model.SubmitAsync();
                await RenderAsync();
                await operation;
                args.Cancel = model.State != FileRecyclePresentationState.ConfirmedSuccess;
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
            if (_isClosingPhotoRecycle || model.State != FileRecyclePresentationState.Submitting)
            {
                return;
            }
            args.Cancel = true;
            model.Cancel();
            _ = RenderAsync();
        };

        await RenderAsync();
        var confirmed = false;
        try
        {
            await dialog.ShowAsync();
            confirmed = model.State == FileRecyclePresentationState.ConfirmedSuccess;
        }
        finally
        {
            model.Dispose();
            if (ReferenceEquals(_photoRecycleModel, model))
            {
                _photoRecycleModel = null;
            }
            if (ReferenceEquals(_photoRecycleDialog, dialog))
            {
                _photoRecycleDialog = null;
            }
            _isClosingPhotoRecycle = false;
        }

        if (confirmed && !_disposed && repository.ProfileId == _dataSource.ProfileId)
        {
            await RefreshAfterPhotoRecycleAsync(sourceSpace, sourceParent, timelineMode);
        }
        if (!_disposed)
        {
            UpdateState();
        }
    }

    private async Task RefreshAfterPhotoRecycleAsync(
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

    private bool IsCurrentPhotoRecycleSelection(PhotoItem item, bool timelineMode) =>
        timelineMode
            ? TimelineMode.IsChecked == true && TimelineView.HasSelectedItem(item)
            : TimelineMode.IsChecked != true &&
                _viewModel.SelectedItem is { } entry &&
                SamePhotoItem(entry.Item, item);

    private void UpdatePhotoRecycleControls()
    {
        var canRestore = CanRestoreSelectedPhoto();
        PhotoRestoreFromRecycleButton.IsEnabled = canRestore;
        PhotoRestoreFromRecycleButton.Visibility = canRestore
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void ClosePhotoRecycleDialog()
    {
        var dialog = _photoRecycleDialog;
        var model = _photoRecycleModel;
        _photoRecycleDialog = null;
        _photoRecycleModel = null;
        model?.Cancel();
        model?.Dispose();
        if (dialog is null)
        {
            return;
        }
        _isClosingPhotoRecycle = true;
        dialog.Hide();
    }

    private static FileItem? ToRecycleFileItem(PhotoItem item)
    {
        if (item.Kind is not (PhotoItemKind.Image or PhotoItemKind.Video) || item.SizeBytes is not >= 0)
        {
            return null;
        }

        return new FileItem(
            item.Path,
            item.Name,
            IsDirectory: false,
            item.SizeBytes.Value,
            item.ModifiedAt,
            Owner: null,
            CanWrite: false,
            CanDelete: true);
    }

    private static string? ParentPath(string path)
    {
        var index = path.LastIndexOf('/');
        return index > 0 ? path[..index] : null;
    }

    private static bool SamePhotoItem(PhotoItem left, PhotoItem right) =>
        left.ProfileId == right.ProfileId &&
        string.Equals(left.Path, right.Path, StringComparison.Ordinal) &&
        string.Equals(left.Name, right.Name, StringComparison.Ordinal) &&
        left.Kind == right.Kind &&
        left.SizeBytes == right.SizeBytes &&
        left.ModifiedAt == right.ModifiedAt;
}
