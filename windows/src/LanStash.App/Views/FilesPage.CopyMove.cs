using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly IFileCopyMoveRepository? _copyMoveRepository;
    private readonly IFileCopyMoveFolderSource? _copyMoveFolderSource;
    private readonly FileCopyMoveReviewBlocker _copyMoveReviewBlocker;
    private FileCopyMoveViewModel? _copyMoveModel;
    private ContentDialog? _copyMoveDialog;
    private bool _isClosingCopyMove;
    private long _copyMoveSourceRevision;

    private async void CopyFile_Click(object sender, RoutedEventArgs e) =>
        await ShowCopyMoveAsync(FileCopyMoveOperation.Copy);

    private async void MoveFile_Click(object sender, RoutedEventArgs e) =>
        await ShowCopyMoveAsync(FileCopyMoveOperation.Move);

    private bool CanCopyMove(FileCopyMoveOperation operation) =>
        !_disposed && !IsReadOnlyLocation() && _copyMoveDialog is null &&
        !_isClosingCopyMove && !_viewModel.IsLoading &&
        _copyMoveRepository is { } repository && _copyMoveFolderSource is not null &&
        repository.ProfileId == _profileId &&
        (operation == FileCopyMoveOperation.Copy ? repository.Availability.CanCopy : repository.Availability.CanMove) &&
        _viewModel.SelectedItem?.Item is { } item &&
        FileCopyMoveViewModel.IsDestination(item.Path) &&
        (operation != FileCopyMoveOperation.Move || item.CanDelete);

    private async Task ShowCopyMoveAsync(FileCopyMoveOperation operation)
    {
        if (!CanCopyMove(operation)) return;
        var repository = _copyMoveRepository!;
        var folders = _copyMoveFolderSource!;
        var source = _viewModel.SelectedItem!.Item;
        var sourceParent = _viewModel.CurrentPath;
        var revision = Interlocked.Increment(ref _copyMoveSourceRevision);

        CloseShareLinkDialog();
        CloseMutationDialog();
        await ClosePreviewAsync();
        if (_disposed || !CanCopyMove(operation) || repository.ProfileId != _profileId ||
            !string.Equals(sourceParent, _viewModel.CurrentPath, StringComparison.Ordinal) ||
            !SameCopyMoveItem(source, _viewModel.SelectedItem?.Item)) return;

        var model = new FileCopyMoveViewModel(repository, folders, _profileId, source,
            operation, revision, _copyMoveReviewBlocker);
        var dialog = new ContentDialog { XamlRoot = XamlRoot, DefaultButton = ContentDialogButton.Primary };
        _copyMoveModel = model;
        _copyMoveDialog = dialog;
        var localization = LocalizationService.Current;

        async Task RenderAsync()
        {
            if (_copyMoveModel != model || _copyMoveDialog != dialog) return;
            dialog.Title = localization.Get(FileCopyMoveDialogContent.TitleKey(model.Source.IsDirectory, operation));
            dialog.CloseButtonText = localization.Get(model.State is
                FileCopyMovePresentationState.ChoosingDestination or
                FileCopyMovePresentationState.LoadingFolders or
                FileCopyMovePresentationState.Submitting
                    ? "FileCopyMove_Cancel_Button"
                    : "FileCopyMove_Close_Button");
            dialog.PrimaryButtonText = model.State switch
            {
                FileCopyMovePresentationState.ChoosingDestination => localization.Get(operation == FileCopyMoveOperation.Copy ? "FileCopyMove_Copy_Button" : "FileCopyMove_Move_Button"),
                FileCopyMovePresentationState.CancelledBeforeSubmission => localization.Get("FileCopyMove_ChooseDestination_Button"),
                _ => string.Empty,
            };
            dialog.IsPrimaryButtonEnabled = model.CanSubmit ||
                model.State == FileCopyMovePresentationState.CancelledBeforeSubmission;
            dialog.DefaultButton = string.IsNullOrEmpty(dialog.PrimaryButtonText) ? ContentDialogButton.Close : ContentDialogButton.Primary;
            dialog.Content = FileCopyMoveDialogContent.Build(model, localization, RenderAsync);
            await Task.CompletedTask;
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (_disposed || repository.ProfileId != _profileId || folders.ProfileId != _profileId ||
                model.SourceRevision != _copyMoveSourceRevision || IsReadOnlyLocation() ||
                !string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal) ||
                !SameCopyMoveItem(source, _viewModel.SelectedItem?.Item)) return;
            if (model.State == FileCopyMovePresentationState.CancelledBeforeSubmission)
            {
                model.ReturnToForm(); await RenderAsync(); return;
            }
            var deferral = args.GetDeferral();
            try
            {
                var operationTask = model.SubmitAsync();
                await RenderAsync();
                await operationTask;
                args.Cancel = model.State != FileCopyMovePresentationState.ConfirmedSuccess;
                if (args.Cancel) await RenderAsync();
            }
            finally { deferral.Complete(); }
        };
        dialog.Closing += (sender, args) =>
        {
            if (_isClosingCopyMove || model.State != FileCopyMovePresentationState.Submitting) return;
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
            if (ReferenceEquals(_copyMoveModel, model)) _copyMoveModel = null;
            if (ReferenceEquals(_copyMoveDialog, dialog)) _copyMoveDialog = null;
            _isClosingCopyMove = false;
        }
        if (confirmed && !_disposed && repository.ProfileId == _profileId &&
            string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal))
            await RunAsync(_viewModel.RefreshAsync);
        if (!_disposed) UpdateState();
    }

    private static bool SameCopyMoveItem(FileItem left, FileItem? right) => right is not null &&
        string.Equals(left.Path, right.Path, StringComparison.Ordinal) && left.IsDirectory == right.IsDirectory &&
        left.Size == right.Size && left.ModifiedAt == right.ModifiedAt && left.CanDelete == right.CanDelete;

    private void UpdateCopyMoveControls()
    {
        CopyFileButton.IsEnabled = CanCopyMove(FileCopyMoveOperation.Copy);
        MoveFileButton.IsEnabled = CanCopyMove(FileCopyMoveOperation.Move);
        var visible = IsReadOnlyLocation() ? Visibility.Collapsed : Visibility.Visible;
        CopyFileButton.Visibility = visible;
        MoveFileButton.Visibility = visible;
    }

    private void CloseCopyMoveDialog()
    {
        var dialog = _copyMoveDialog;
        var model = _copyMoveModel;
        _copyMoveDialog = null; _copyMoveModel = null;
        model?.Cancel(); model?.Dispose();
        if (dialog is null) return;
        _isClosingCopyMove = true;
        dialog.Hide();
    }
}
