using LanStash.App.Features.Files;
using LanStash.App.Features.Files.Locations;
using LanStash.App.Features.Files.Recycle;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private FileRecycleBatchViewModel? _batchRecycleModel;
    private ContentDialog? _batchRecycleDialog;
    private bool _isClosingBatchRecycle;

    private async void MoveMultipleToRecycle_Click(object sender, RoutedEventArgs e)
    {
        await ClosePreviewAsync();
        EnterBatchRecycleSelectionMode(FileRecycleOperation.MoveToRecycle);
    }

    private async void MoveSelectedToRecycle_Click(object sender, RoutedEventArgs e) =>
        await ShowBatchRecycleAsync(FileRecycleOperation.MoveToRecycle);

    private async void RestoreMultipleItems_Click(object sender, RoutedEventArgs e)
    {
        await ClosePreviewAsync();
        EnterBatchRecycleSelectionMode(FileRecycleOperation.Restore);
    }

    private async void RestoreSelectedItems_Click(object sender, RoutedEventArgs e) =>
        await ShowBatchRecycleAsync(FileRecycleOperation.Restore);

    private void EnterBatchRecycleSelectionMode(FileRecycleOperation operation)
    {
        if (!CanEnterBatchRecycle(operation))
        {
            return;
        }

        var selected = _viewModel.SelectedItem;
        _batchSelectionOperation = operation == FileRecycleOperation.Restore
            ? FileBatchSelectionOperation.Restore
            : FileBatchSelectionOperation.Recycle;
        _batchSelection.Clear();
        FileList.SelectionMode = ListViewSelectionMode.Multiple;
        FileGrid.SelectionMode = ListViewSelectionMode.Multiple;
        FileList.SelectedItems.Clear();
        FileGrid.SelectedItems.Clear();
        if (selected is not null && (operation == FileRecycleOperation.Restore
                ? CanSelectForBatchRestore(selected.Item)
                : CanSelectForBatchRecycle(selected.Item)))
        {
            _batchSelection.Add(selected.Path);
            ApplyDownloadSelection(VisibleFilesControl());
        }
        AnnounceBatchSelection();
        UpdateState();
    }

    private bool CanEnterBatchRecycle(FileRecycleOperation operation) =>
        !_disposed && !_viewModel.IsLoading && !_isSelectingItems &&
        _downloadBatchId is null && _folderUploadBatchId is null &&
        _recycleDialog is null && !_isClosingRecycle &&
        _batchRecycleDialog is null && !_isClosingBatchRecycle &&
        _recycleRepository is
        {
            Availability: var availability,
            ProfileId: var repositoryProfile,
        } &&
        repositoryProfile == _profileId &&
        (operation == FileRecycleOperation.Restore
            ? availability.CanRestore &&
                _viewModel.Items.Any(item => CanSelectForBatchRestore(item.Item))
            : availability.CanMoveToRecycle &&
                _viewModel.Items.Any(item => CanSelectForBatchRecycle(item.Item)));

    private bool CanSelectForBatchRecycle(FileItem item) =>
        FileRecycleViewModel.CanMoveToRecycle(
            _profileId,
            item,
            _viewModel.CurrentPath,
            _locationsViewModel.SelectedSource,
            _locationsViewModel.Recycle.Items);

    private bool CanSelectForBatchRestore(FileItem item) =>
        FileRecycleViewModel.CanRestore(
            _profileId,
            item,
            _viewModel.CurrentPath,
            _locationsViewModel.SelectedSource);

    private async Task ShowBatchRecycleAsync(FileRecycleOperation operation)
    {
        if (_fileOperationRecoveryDialog is not null || !_isSelectingRecycle ||
            _isSelectingRestore != (operation == FileRecycleOperation.Restore) ||
            _recycleRepository is not { } repository)
        {
            return;
        }

        var sources = _viewModel.Items
            .Where(item => _batchSelection.Contains(item.Path))
            .Select(item => item.Item)
            .ToArray();
        var sourceParent = _viewModel.CurrentPath;
        var recycleLocations = operation == FileRecycleOperation.MoveToRecycle
            ? _locationsViewModel.Recycle.Items.ToArray()
            : [];
        if (!BatchRecycleSourceIsCurrent(repository, sourceParent, sources, recycleLocations, operation) ||
            FileRecycleBatchViewModel.Validate(
                _profileId,
                sources,
                sourceParent,
                _locationsViewModel.SelectedSource,
                recycleLocations,
                FileRecycleBatchSourceScope.CurrentFolder,
                operation) != FileRecycleBatchValidationStatus.Valid)
        {
            ShowBatchSelectionMessage(
                operation == FileRecycleOperation.Restore
                    ? "FileRestoreBatchSelectionInvalid"
                    : "FileRecycleBatchSelectionInvalid",
                InfoBarSeverity.Error);
            return;
        }

        var model = new FileRecycleBatchViewModel(
            repository,
            _profileId,
            sources,
            recycleLocations,
            sourceParent,
            FileRecycleBatchSourceScope.CurrentFolder,
            operation,
            _locationsViewModel.SelectedSource,
            _recycleReviewBlocker);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            DefaultButton = ContentDialogButton.Close,
        };
        _batchRecycleModel = model;
        _batchRecycleDialog = dialog;
        var localization = LocalizationService.Current;

        async Task RenderAsync()
        {
            if (_batchRecycleModel != model || _batchRecycleDialog != dialog)
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
            dialog.DefaultButton = ContentDialogButton.Close;
            dialog.Content = FileRecycleBatchDialogContent.Build(
                model,
                localization,
                operation == FileRecycleOperation.Restore
                    ? "FileRestoreBatchConfirmMessage"
                    : "FileRecycleBatchConfirmMessage");
            await Task.CompletedTask;
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (!BatchRecycleSourceIsCurrent(
                    repository,
                    sourceParent,
                    sources,
                    recycleLocations,
                    operation))
            {
                ShowBatchSelectionMessage(
                    operation == FileRecycleOperation.Restore
                        ? "FileRestoreBatchSourceChanged"
                        : "FileRecycleBatchSourceChanged",
                    InfoBarSeverity.Error);
                dialog.IsPrimaryButtonEnabled = false;
                dialog.Content = new TextBlock
                {
                    Text = localization.Get(operation == FileRecycleOperation.Restore
                        ? "FileRestoreBatchSourceChanged" : "FileRecycleBatchSourceChanged"),
                    TextWrapping = TextWrapping.WrapWholeWords,
                };
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
            if (_isClosingBatchRecycle || model.State != FileRecycleBatchState.Submitting)
            {
                return;
            }
            args.Cancel = true;
            model.Cancel();
            _ = RenderAsync();
        };

        var progressQueued = false;
        void ProgressChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
        {
            if (args.PropertyName != nameof(FileRecycleBatchViewModel.ProcessedCount) || progressQueued) return;
            progressQueued = true;
            if (!DispatcherQueue.TryEnqueue(() =>
            {
                progressQueued = false;
                if (_batchRecycleModel == model && model.State == FileRecycleBatchState.Submitting &&
                    dialog.Content is StackPanel panel)
                    FileRecycleBatchDialogContent.UpdateProgress(panel, model, localization);
            })) progressQueued = false;
        }
        model.PropertyChanged += ProgressChanged;
        await RenderAsync();
        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            model.PropertyChanged -= ProgressChanged;
            model.Dispose();
            if (ReferenceEquals(_batchRecycleModel, model))
            {
                _batchRecycleModel = null;
            }
            if (ReferenceEquals(_batchRecycleDialog, dialog))
            {
                _batchRecycleDialog = null;
            }
            _isClosingBatchRecycle = false;
        }

        var completed = model.State == FileRecycleBatchState.Completed;
        var summary = model.Summary;
        ExitDownloadSelectionMode();
        if (!completed || _disposed)
        {
            return;
        }
        ShowBatchRecycleSummary(summary, operation);
        if (summary.ConfirmedCount > 0 &&
            repository.ProfileId == _profileId &&
            string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal))
        {
            await RunAsync(_viewModel.RefreshAsync);
        }
        UpdateState();
    }

    private bool BatchRecycleSourceIsCurrent(
        IFileRecycleRepository repository,
        string sourceParent,
        IReadOnlyList<FileItem> sources,
        IReadOnlyList<FileRecycleLocation> recycleLocations,
        FileRecycleOperation operation)
    {
        if (_disposed || _viewModel.IsLoading || repository.ProfileId != _profileId ||
            !_isSelectingRecycle || _isSelectingRestore != (operation == FileRecycleOperation.Restore) ||
            _isSynchronizingDownloadSelection || sources.Count == 0 ||
            !string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal) ||
            operation == FileRecycleOperation.MoveToRecycle &&
                _locationsViewModel.SelectedSource is
                    FileLocationSource.Remote or FileLocationSource.Recycle ||
            operation == FileRecycleOperation.Restore &&
                _locationsViewModel.SelectedSource != FileLocationSource.Recycle)
        {
            return false;
        }
        var visible = VisibleFilesControl().SelectedItems;
        var selected = visible.OfType<FileBrowserEntry>().Select(item => item.Path).ToHashSet(StringComparer.Ordinal);
        if (_batchSelection.Count != sources.Count || visible.Count != sources.Count || selected.Count != sources.Count ||
            sources.Any(item => !_batchSelection.Contains(item.Path) || !selected.Contains(item.Path))) return false;
        var currentItems = new Dictionary<string, FileItem>(StringComparer.Ordinal);
        foreach (var item in _viewModel.Items)
            if (!currentItems.TryAdd(item.Path, item.Item)) return false;
        foreach (var source in sources)
        {
            if (!currentItems.TryGetValue(source.Path, out var current) ||
                source.Name != current.Name || !SameRecycleItem(source, current) ||
                !(operation == FileRecycleOperation.Restore
                    ? CanSelectForBatchRestore(current)
                    : CanSelectForBatchRecycle(current)))
            {
                return false;
            }
            if (operation == FileRecycleOperation.MoveToRecycle)
            {
                var frozenLocation = FileRecycleViewModel.FindRecycleLocation(
                    _profileId, source.Path, recycleLocations);
                var currentLocation = FileRecycleViewModel.FindRecycleLocation(
                    _profileId, source.Path, _locationsViewModel.Recycle.Items);
                if (frozenLocation is null || currentLocation is null ||
                    frozenLocation != currentLocation)
                {
                    return false;
                }
            }
        }
        return true;
    }

    private void ShowBatchRecycleSummary(
        FileRecycleBatchSummary summary,
        FileRecycleOperation operation)
    {
        FileRecycleBatchStatus.ActionButton = null;
        if (summary.NeedsReviewCount > 0 && _recycleRepository?.SupportsRecycleReview == true)
        {
            var review = new Button { Content = LocalizationService.Current.Get("FileOperationReviewNow") };
            review.Click += async (_, _) => await ShowFileOperationRecoveryAsync(recycle: true);
            FileRecycleBatchStatus.ActionButton = review;
        }
        FileRecycleBatchStatus.Severity = summary.NeedsReviewCount > 0 ||
            summary.FailedCount > 0 || summary.CancelledCount > 0 ||
            summary.NotStartedCount > 0
            ? InfoBarSeverity.Warning
            : InfoBarSeverity.Success;
        FileRecycleBatchStatus.Message = FileRecycleBatchDialogContent.FormatSummary(
            LocalizationService.Current,
            summary,
            operation);
        FileRecycleBatchStatus.IsOpen = true;
    }

    private void UpdateBatchRecycleControls()
    {
        RecycleRecoveryButton.IsEnabled = !_disposed && _fileOperationRecoveryDialog is null && _batchRecycleDialog is null &&
            _batchCopyMoveDialog is null && _recycleRepository is { SupportsRecycleReview: true } repository && repository.ProfileId == _profileId;
        MoveMultipleToRecycleButton.Visibility = _isSelectingItems
            ? Visibility.Collapsed
            : Visibility.Visible;
        MoveMultipleToRecycleButton.IsEnabled = CanEnterBatchRecycle(
            FileRecycleOperation.MoveToRecycle);
        RestoreMultipleItemsButton.Visibility = _isSelectingItems
            ? Visibility.Collapsed
            : Visibility.Visible;
        RestoreMultipleItemsButton.IsEnabled = CanEnterBatchRecycle(
            FileRecycleOperation.Restore);
    }

    private void CloseBatchRecycleDialog()
    {
        var dialog = _batchRecycleDialog;
        var model = _batchRecycleModel;
        _batchRecycleDialog = null;
        _batchRecycleModel = null;
        model?.Cancel();
        model?.Dispose();
        if (dialog is null)
        {
            return;
        }
        _isClosingBatchRecycle = true;
        dialog.Hide();
    }
}
