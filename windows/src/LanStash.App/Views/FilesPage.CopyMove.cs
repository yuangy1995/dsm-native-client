using LanStash.App.Features.Files.CopyMove;
using LanStash.Domain;
using Microsoft.UI.Xaml;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private readonly IFileCopyMoveRepository? _copyMoveRepository;
    private readonly IFileCopyMoveFolderSource? _copyMoveFolderSource;
    private readonly FileCopyMoveReviewBlocker _copyMoveReviewBlocker;

    private async void CopyFile_Click(object sender, RoutedEventArgs e) =>
        await ShowCopyMoveAsync(FileCopyMoveOperation.Copy);

    private async void MoveFile_Click(object sender, RoutedEventArgs e) =>
        await ShowCopyMoveAsync(FileCopyMoveOperation.Move);

    private bool CanCopyMove(FileCopyMoveOperation operation) =>
        !_disposed && !IsReadOnlyLocation() && _batchCopyMoveDialog is null && _fileOperationRecoveryDialog is null &&
        !_isClosingBatchCopyMove && !_viewModel.IsLoading && !_isSelectingItems &&
        _copyMoveRepository is { } repository && _copyMoveFolderSource is not null &&
        repository.ProfileId == _profileId &&
        (operation == FileCopyMoveOperation.Copy ? repository.Availability.CanCopy : repository.Availability.CanMove) &&
        _viewModel.SelectedItem?.Item is { } item &&
        FileCopyMoveViewModel.IsDestination(item.Path) &&
        (operation != FileCopyMoveOperation.Move || item.CanDelete);

    private async Task ShowCopyMoveAsync(FileCopyMoveOperation operation)
    {
        if (!CanCopyMove(operation)) return;
        var source = _viewModel.SelectedItem!.Item;
        var sourceParent = _viewModel.CurrentPath;
        CloseShareLinkDialog();
        CloseMutationDialog();
        await ClosePreviewAsync();
        if (!CanCopyMove(operation) ||
            !string.Equals(sourceParent, _viewModel.CurrentPath, StringComparison.Ordinal) ||
            !SameCopyMoveItem(source, _viewModel.SelectedItem?.Item)) return;

        // 单项与多项共用同一确认、同名策略及结果流程，保留选中项变更检查。
        await ShowBatchCopyMoveDialogAsync(operation, [source], requireSelectedItem: true);
    }

    private static bool SameCopyMoveItem(FileItem left, FileItem? right) => right is not null &&
        string.Equals(left.Path, right.Path, StringComparison.Ordinal) && left.Name == right.Name &&
        left.IsDirectory == right.IsDirectory && left.Size == right.Size &&
        left.ModifiedAt == right.ModifiedAt && left.CanDelete == right.CanDelete;

    private void UpdateCopyMoveControls()
    {
        CopyMoveRecoveryButton.IsEnabled = !_disposed && _fileOperationRecoveryDialog is null && _batchCopyMoveDialog is null &&
            _copyMoveRepository is { SupportsCopyMoveReview: true } repository && repository.ProfileId == _profileId;
        CopyFileButton.IsEnabled = CanCopyMove(FileCopyMoveOperation.Copy);
        MoveFileButton.IsEnabled = CanCopyMove(FileCopyMoveOperation.Move);
        var visible = IsReadOnlyLocation() ? Visibility.Collapsed : Visibility.Visible;
        CopyFileButton.Visibility = visible;
        MoveFileButton.Visibility = visible;
    }

    private void CloseCopyMoveDialog()
    {
        CloseFileOperationRecoveryDialog();
        CloseBatchCopyMoveDialog();
    }
}
