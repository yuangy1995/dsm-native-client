using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly IFileRecycleRepository? _recycleRepository;
    private readonly FileRecycleReviewBlocker _recycleReviewBlocker;
    private FileRecycleViewModel? _recycleModel;
    private ContentDialog? _recycleDialog;
    private bool _isClosingRecycle;
    private long _recycleSourceRevision;

    private async void MoveToRecycle_Click(object sender, RoutedEventArgs e) =>
        await ShowRecycleAsync(FileRecycleOperation.MoveToRecycle);

    private async void RestoreFromRecycle_Click(object sender, RoutedEventArgs e) =>
        await ShowRecycleAsync(FileRecycleOperation.Restore);

    private bool CanMoveToRecycle() =>
        !_disposed && _recycleDialog is null && !_isClosingRecycle &&
        !_viewModel.IsLoading &&
        _recycleRepository is { Availability: { CanMoveToRecycle: true }, ProfileId: var profile } &&
        profile == _profileId &&
        FileRecycleViewModel.CanMoveToRecycle(
            _profileId,
            _viewModel.SelectedItem?.Item,
            _viewModel.CurrentPath,
            _locationsViewModel.SelectedSource,
            _locationsViewModel.Recycle.Items);

    private bool CanRestoreFromRecycle() =>
        !_disposed && _recycleDialog is null && !_isClosingRecycle &&
        !_viewModel.IsLoading &&
        _recycleRepository is { Availability: { CanRestore: true }, ProfileId: var profile } &&
        profile == _profileId &&
        FileRecycleViewModel.CanRestore(
            _profileId,
            _viewModel.SelectedItem?.Item,
            _viewModel.CurrentPath,
            _locationsViewModel.SelectedSource);

    private async Task ShowRecycleAsync(FileRecycleOperation operation)
    {
        if (operation == FileRecycleOperation.MoveToRecycle && !CanMoveToRecycle() ||
            operation == FileRecycleOperation.Restore && !CanRestoreFromRecycle())
        {
            return;
        }

        var repository = _recycleRepository!;
        var source = _viewModel.SelectedItem!.Item;
        var sourceParent = _viewModel.CurrentPath;
        var sourceLocation = operation == FileRecycleOperation.MoveToRecycle
            ? FileRecycleViewModel.FindRecycleLocation(_profileId, source.Path, _locationsViewModel.Recycle.Items)
            : null;
        var revision = Interlocked.Increment(ref _recycleSourceRevision);

        CloseShareLinkDialog();
        CloseMutationDialog();
        CloseCopyMoveDialog();
        await ClosePreviewAsync();

        if (_disposed ||
            repository.ProfileId != _profileId ||
            !string.Equals(sourceParent, _viewModel.CurrentPath, StringComparison.Ordinal) ||
            !SameRecycleItem(source, _viewModel.SelectedItem?.Item) ||
            (operation == FileRecycleOperation.MoveToRecycle && !CanMoveToRecycle()) ||
            (operation == FileRecycleOperation.Restore && !CanRestoreFromRecycle()))
        {
            return;
        }

        var model = new FileRecycleViewModel(
            repository,
            _profileId,
            source,
            operation,
            revision,
            sourceLocation,
            _recycleReviewBlocker);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Primary };
        _recycleModel = model;
        _recycleDialog = dialog;
        var localization = LocalizationService.Current;

        async Task RenderAsync()
        {
            if (_recycleModel != model || _recycleDialog != dialog)
            {
                return;
            }

            dialog.Title = localization.Get(RecycleTitleKey(
                operation, model.Source.IsDirectory));
            dialog.CloseButtonText = localization.Get(model.State is
                FileRecyclePresentationState.Confirming or
                FileRecyclePresentationState.Submitting
                    ? "FileRecycleCancelAction"
                    : "FileRecycleCloseAction");
            dialog.PrimaryButtonText = model.State switch
            {
                FileRecyclePresentationState.Confirming => localization.Get(operation == FileRecycleOperation.MoveToRecycle
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
                repository.ProfileId != _profileId ||
                model.SourceRevision != _recycleSourceRevision ||
                !string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal) ||
                !SameRecycleItem(source, _viewModel.SelectedItem?.Item) ||
                operation == FileRecycleOperation.MoveToRecycle && !CanMoveToRecycle() ||
                operation == FileRecycleOperation.Restore && !CanRestoreFromRecycle())
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
            if (_isClosingRecycle || model.State != FileRecyclePresentationState.Submitting)
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
            if (ReferenceEquals(_recycleModel, model))
            {
                _recycleModel = null;
            }
            if (ReferenceEquals(_recycleDialog, dialog))
            {
                _recycleDialog = null;
            }
            _isClosingRecycle = false;
        }

        if (confirmed &&
            !_disposed &&
            repository.ProfileId == _profileId &&
            string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal))
        {
            await RunAsync(_viewModel.RefreshAsync);
        }
        if (!_disposed)
        {
            UpdateState();
        }
    }

    private static bool SameRecycleItem(FileItem left, FileItem? right) => right is not null &&
        string.Equals(left.Path, right.Path, StringComparison.Ordinal) &&
        left.IsDirectory == right.IsDirectory &&
        left.Size == right.Size &&
        left.ModifiedAt == right.ModifiedAt &&
        left.CanDelete == right.CanDelete;

    private static string RecycleTitleKey(FileRecycleOperation operation, bool isDirectory) =>
        (operation, isDirectory) switch
        {
            (FileRecycleOperation.MoveToRecycle, true) => "FileRecycleMoveFolderTitle",
            (FileRecycleOperation.Restore, true) => "FileRecycleRestoreFolderTitle",
            (FileRecycleOperation.MoveToRecycle, false) => "FileRecycleMoveTitle",
            _ => "FileRecycleRestoreTitle",
        };

    private void UpdateRecycleControls()
    {
        MoveToRecycleButton.IsEnabled = CanMoveToRecycle();
        MoveToRecycleButton.Visibility = CanMoveToRecycle()
            ? Visibility.Visible
            : Visibility.Collapsed;
        RestoreFromRecycleButton.IsEnabled = CanRestoreFromRecycle();
        RestoreFromRecycleButton.Visibility = CanRestoreFromRecycle()
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void CloseRecycleDialog()
    {
        var dialog = _recycleDialog;
        var model = _recycleModel;
        _recycleDialog = null;
        _recycleModel = null;
        model?.Cancel();
        model?.Dispose();
        if (dialog is null)
        {
            return;
        }
        _isClosingRecycle = true;
        dialog.Hide();
    }
}
