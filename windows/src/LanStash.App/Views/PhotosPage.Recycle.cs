using System.Text.Json;
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
    private enum PhotoRecycleLocationsState { Idle, Loading, Ready, Unavailable, Failed }

    private IFileLocationsRepository? _photoLocationsRepository;
    private IFileRecycleRepository? _photoRecycleRepository;
    private FileRecycleReviewBlocker _photoRecycleReviewBlocker = FileRecycleReviewBlocker.Current;
    private FileRecycleViewModel? _photoRecycleModel;
    private ContentDialog? _photoRecycleDialog;
    private bool _isClosingPhotoRecycle;
    private long _photoRecycleSourceRevision;
    private IReadOnlyList<FileRecycleLocation> _photoRecycleLocations = [];
    private PhotoRecycleLocationsState _photoRecycleLocationsState;
    private CancellationTokenSource? _photoRecycleLocationsCancellation;
    private long _photoRecycleLocationsGeneration;

    private void InitializePhotoRecycle(
        IFileLocationsRepository? locationsRepository,
        IFileRecycleRepository? repository,
        FileRecycleReviewBlocker? blocker)
    {
        if (locationsRepository is not null && locationsRepository.ProfileId != _dataSource.ProfileId)
        {
            throw new ArgumentException(
                "The locations repository must match the active photo profile.",
                nameof(locationsRepository));
        }
        if (repository is not null && repository.ProfileId != _dataSource.ProfileId)
        {
            throw new ArgumentException(
                "The recycle repository must match the active photo profile.",
                nameof(repository));
        }

        _photoLocationsRepository = locationsRepository;
        _photoRecycleRepository = repository;
        _photoRecycleReviewBlocker = blocker ?? FileRecycleReviewBlocker.Current;
        _photoRecycleLocationsState = locationsRepository?.Availability.RecycleBins == true
            ? PhotoRecycleLocationsState.Idle
            : PhotoRecycleLocationsState.Unavailable;
    }

    private async void MovePhotoToRecycle_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.SelectedItem is { } entry)
        {
            await ShowPhotoRecycleAsync(entry.Item, FileRecycleOperation.MoveToRecycle);
        }
    }

    private async void RestorePhotoFromRecycle_Click(object sender, RoutedEventArgs e)
    {
        if (_viewModel.SelectedItem is { } entry)
        {
            await ShowPhotoRecycleAsync(entry.Item, FileRecycleOperation.Restore);
        }
    }

    private bool CanMoveSelectedPhotoToRecycle() =>
        _viewModel.SelectedItem is { } entry && CanMovePhotoToRecycle(entry.Item);

    private bool CanMovePhotoToRecycle(PhotoItem item) =>
        CanOpenPhotoRecycleDialog(item, FileRecycleOperation.MoveToRecycle);

    private Task MovePhotoToRecycleAsync(PhotoItem item) =>
        ShowPhotoRecycleAsync(item, FileRecycleOperation.MoveToRecycle);

    private bool CanRestoreSelectedPhoto() =>
        _viewModel.SelectedItem is { } entry &&
        CanOpenPhotoRecycleDialog(entry.Item, FileRecycleOperation.Restore);

    private bool CanRestorePhotoItem(PhotoItem item) =>
        CanOpenPhotoRecycleDialog(item, FileRecycleOperation.Restore);

    private bool CanOpenPhotoRecycleDialog(PhotoItem item, FileRecycleOperation operation) =>
        _photoRecycleDialog is null &&
        _photoBatchRecycleDialog is null &&
        _photoBatchCopyMoveDialog is null &&
        !IsSelectingPhotoBatch &&
        _photoCopyMoveDialog is null &&
        !_isClosingPhotoRecycle &&
        CanPhotoRecycleItemCore(item, operation);

    private bool CanPhotoRecycleItemCore(PhotoItem item, FileRecycleOperation operation)
    {
        if (_disposed ||
            _photoSaveBatchId is not null || _isChoosingPhotoBatchSaveTarget ||
            _photoRecycleRepository is not { ProfileId: var profileId } repository ||
            profileId != _dataSource.ProfileId ||
            _viewModel.ActiveProfileId != _dataSource.ProfileId ||
            _viewModel.SelectedSpace is not { } space ||
            !PhotoTimelineViewModel.ContainsCanonicalPath(space.RootPath, item.Path) ||
            ToRecycleFileItem(item) is not { } source ||
            ParentPath(item.Path) is not { } sourceParent)
        {
            return false;
        }

        return operation == FileRecycleOperation.MoveToRecycle
            ? repository.Availability.CanMoveToRecycle &&
                _photoRecycleLocationsState == PhotoRecycleLocationsState.Ready &&
                !HasRecyclePathSegment(source.Path) &&
                FileRecycleViewModel.CanMoveToRecycle(
                    _dataSource.ProfileId,
                    source,
                    sourceParent,
                    FileLocationSource.Shares,
                    _photoRecycleLocations)
            : repository.Availability.CanRestore &&
                FileRecycleViewModel.CanRestore(
                    _dataSource.ProfileId,
                    source,
                    sourceParent,
                    FileLocationSource.Recycle);
    }

    private async Task RestorePhotoItemAsync(PhotoItem item)
        => await ShowPhotoRecycleAsync(item, FileRecycleOperation.Restore);

    private async Task ShowPhotoRecycleAsync(
        PhotoItem item,
        FileRecycleOperation operation)
    {
        if (!CanOpenPhotoRecycleDialog(item, operation) ||
            _photoRecycleRepository is not { } repository ||
            ToRecycleFileItem(item) is not { } source ||
            ParentPath(item.Path) is not { } sourceParent ||
            _viewModel.SelectedSpace is not { } sourceSpace)
        {
            return;
        }

        var timelineMode = TimelineMode.IsChecked == true;
        var revision = Interlocked.Increment(ref _photoRecycleSourceRevision);
        var recycleLocation = operation == FileRecycleOperation.MoveToRecycle
            ? FileRecycleViewModel.FindRecycleLocation(
                _dataSource.ProfileId,
                source.Path,
                _photoRecycleLocations)
            : null;
        if (!CanPhotoRecycleItemCore(item, operation) ||
            !IsCurrentPhotoRecycleSelection(item, timelineMode))
        {
            return;
        }
        var model = new FileRecycleViewModel(
            repository,
            _dataSource.ProfileId,
            source,
            operation,
            revision,
            recycleLocation,
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

            dialog.Title = localization.Get(operation == FileRecycleOperation.MoveToRecycle
                ? "FileRecycleMoveTitle"
                : "FileRecycleRestoreTitle");
            dialog.CloseButtonText = localization.Get(model.State is
                FileRecyclePresentationState.Confirming or
                FileRecyclePresentationState.Submitting
                    ? "FileRecycleCancelAction"
                    : "FileRecycleCloseAction");
            dialog.PrimaryButtonText = model.State switch
            {
                FileRecyclePresentationState.Confirming => localization.Get(
                    operation == FileRecycleOperation.MoveToRecycle
                        ? "FileRecycleMoveAction"
                        : "FileRecycleRestoreAction"),
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
                !CanPhotoRecycleItemCore(item, operation) ||
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
                await ClosePhotoViewerAsync(restoreBrowserFocus: false);
                if (_disposed ||
                    repository.ProfileId != _dataSource.ProfileId ||
                    model.SourceRevision != _photoRecycleSourceRevision ||
                    !CanPhotoRecycleItemCore(item, operation) ||
                    !IsCurrentPhotoRecycleSelection(item, timelineMode))
                {
                    return;
                }
                var operationTask = model.SubmitAsync();
                await RenderAsync();
                await operationTask;
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
            await ClosePhotoViewerAsync(restoreBrowserFocus: true);
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

    private async Task ActivatePhotoRecycleLocationsAsync()
    {
        if (_photoRecycleLocationsState is PhotoRecycleLocationsState.Ready or
            PhotoRecycleLocationsState.Loading or PhotoRecycleLocationsState.Unavailable)
        {
            UpdatePhotoRecycleControls();
            return;
        }
        await LoadPhotoRecycleLocationsAsync();
    }

    private async void PhotoRecycleLocationsRetry_Click(object sender, RoutedEventArgs e) =>
        await LoadPhotoRecycleLocationsAsync();

    private async Task LoadPhotoRecycleLocationsAsync()
    {
        if (_disposed ||
            _photoLocationsRepository is not { } repository ||
            !repository.Availability.RecycleBins ||
            repository.ProfileId != _dataSource.ProfileId)
        {
            _photoRecycleLocationsState = PhotoRecycleLocationsState.Unavailable;
            UpdatePhotoRecycleControls();
            return;
        }

        var generation = Interlocked.Increment(ref _photoRecycleLocationsGeneration);
        _photoRecycleLocationsCancellation?.Cancel();
        _photoRecycleLocationsCancellation?.Dispose();
        var request = new CancellationTokenSource();
        _photoRecycleLocationsCancellation = request;
        _photoRecycleLocationsState = PhotoRecycleLocationsState.Loading;
        UpdatePhotoRecycleControls();
        try
        {
            var snapshot = await repository.LoadSnapshotAsync(request.Token);
            request.Token.ThrowIfCancellationRequested();
            if (!IsCurrentPhotoRecycleLocationsRequest(repository, generation))
            {
                return;
            }
            if (snapshot.ProfileId != _dataSource.ProfileId ||
                snapshot.RecycleBins.Items.Any(item => item.ProfileId != _dataSource.ProfileId))
            {
                throw new InvalidDataException("photo.recycle.locations.profile-mismatch");
            }

            _photoRecycleLocations = snapshot.RecycleBins.Status == FileLocationSectionStatus.Available
                ? snapshot.RecycleBins.Items.ToArray()
                : [];
            _photoRecycleLocationsState = snapshot.RecycleBins.Status switch
            {
                FileLocationSectionStatus.Available => PhotoRecycleLocationsState.Ready,
                FileLocationSectionStatus.Unavailable => PhotoRecycleLocationsState.Unavailable,
                _ => PhotoRecycleLocationsState.Failed,
            };
        }
        catch (OperationCanceledException)
        {
            if (IsCurrentPhotoRecycleLocationsRequest(repository, generation))
            {
                _photoRecycleLocationsState = PhotoRecycleLocationsState.Idle;
            }
        }
        catch (Exception error) when (error is DsmException or InvalidDataException or IOException or JsonException)
        {
            if (IsCurrentPhotoRecycleLocationsRequest(repository, generation))
            {
                _photoRecycleLocations = [];
                _photoRecycleLocationsState = PhotoRecycleLocationsState.Failed;
            }
        }
        finally
        {
            if (ReferenceEquals(_photoRecycleLocationsCancellation, request))
            {
                _photoRecycleLocationsCancellation = null;
            }
            request.Dispose();
            if (!_disposed)
            {
                UpdatePhotoRecycleControls();
            }
        }
    }

    private bool IsCurrentPhotoRecycleLocationsRequest(
        IFileLocationsRepository repository,
        long generation) =>
        !_disposed &&
        ReferenceEquals(_photoLocationsRepository, repository) &&
        repository.ProfileId == _dataSource.ProfileId &&
        generation == _photoRecycleLocationsGeneration;

    private void UpdatePhotoRecycleControls()
    {
        var canMove = !IsSelectingPhotoBatch && CanMoveSelectedPhotoToRecycle();
        PhotoMoveToRecycleButton.IsEnabled = canMove;
        PhotoMoveToRecycleButton.Visibility = canMove
            ? Visibility.Visible
            : Visibility.Collapsed;
        var canRestore = !IsSelectingPhotoBatch && CanRestoreSelectedPhoto();
        PhotoRestoreFromRecycleButton.IsEnabled = canRestore;
        PhotoRestoreFromRecycleButton.Visibility = canRestore
            ? Visibility.Visible
            : Visibility.Collapsed;

        var localization = LocalizationService.Current;
        PhotoRecycleLocationsStatus.IsOpen =
            _photoRecycleLocationsState == PhotoRecycleLocationsState.Failed;
        PhotoRecycleLocationsStatus.Message = localization.Get(
            "PhotoRecycleLocationsFailureMessage");
        PhotoRecycleLocationsRetryButton.Content = localization.Get(
            "PhotoRecycleLocationsRetry");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            PhotoRecycleLocationsRetryButton,
            localization.Get("PhotoRecycleLocationsRetryAutomationName"));
        TimelineView.RefreshActionState();
    }

    private void DeactivatePhotoRecycleLocations()
    {
        Interlocked.Increment(ref _photoRecycleLocationsGeneration);
        _photoRecycleLocationsCancellation?.Cancel();
        _photoRecycleLocationsCancellation?.Dispose();
        _photoRecycleLocationsCancellation = null;
        _photoRecycleLocations = [];
        _photoRecycleLocationsState = _photoLocationsRepository?.Availability.RecycleBins == true
            ? PhotoRecycleLocationsState.Idle
            : PhotoRecycleLocationsState.Unavailable;
    }

    private void DisposePhotoRecycleLocations()
    {
        DeactivatePhotoRecycleLocations();
        _photoRecycleLocations = [];
        _photoLocationsRepository = null;
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

    private static bool HasRecyclePathSegment(string path) =>
        path.Split('/', StringSplitOptions.RemoveEmptyEntries)
            .Any(segment => string.Equals(
                segment,
                "#recycle",
                StringComparison.OrdinalIgnoreCase));

    private static bool SamePhotoItem(PhotoItem left, PhotoItem right) =>
        left.ProfileId == right.ProfileId &&
        string.Equals(left.Path, right.Path, StringComparison.Ordinal) &&
        string.Equals(left.Name, right.Name, StringComparison.Ordinal) &&
        left.Kind == right.Kind &&
        left.SizeBytes == right.SizeBytes &&
        left.ModifiedAt == right.ModifiedAt;
}
