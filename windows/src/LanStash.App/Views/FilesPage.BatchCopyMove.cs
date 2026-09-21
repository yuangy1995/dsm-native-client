using LanStash.App.Features.Files;
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
    private FileCopyMoveBatchViewModel? _batchCopyMoveModel;
    private ContentDialog? _batchCopyMoveDialog;
    private bool _isClosingBatchCopyMove;

    private async void CopyMultiple_Click(object sender, RoutedEventArgs e)
    {
        await ClosePreviewAsync();
        EnterCopyMoveSelectionMode(FileCopyMoveOperation.Copy);
    }

    private async void MoveMultiple_Click(object sender, RoutedEventArgs e)
    {
        await ClosePreviewAsync();
        EnterCopyMoveSelectionMode(FileCopyMoveOperation.Move);
    }

    private async void CopySelectedItems_Click(object sender, RoutedEventArgs e) =>
        await ShowBatchCopyMoveAsync(FileCopyMoveOperation.Copy);

    private async void MoveSelectedItems_Click(object sender, RoutedEventArgs e) =>
        await ShowBatchCopyMoveAsync(FileCopyMoveOperation.Move);

    private void EnterCopyMoveSelectionMode(FileCopyMoveOperation operation)
    {
        if (!CanEnterBatchCopyMove(operation))
        {
            return;
        }

        var selected = _viewModel.SelectedItem;
        _batchSelectionOperation = operation == FileCopyMoveOperation.Copy
            ? FileBatchSelectionOperation.Copy
            : FileBatchSelectionOperation.Move;
        _batchSelection.Clear();
        FileList.SelectionMode = ListViewSelectionMode.Multiple;
        FileGrid.SelectionMode = ListViewSelectionMode.Multiple;
        FileList.SelectedItems.Clear();
        FileGrid.SelectedItems.Clear();
        if (selected is { } &&
            FileCopyMoveViewModel.IsDestination(selected.Path) &&
            (operation != FileCopyMoveOperation.Move || selected.Item.CanDelete))
        {
            _batchSelection.Add(selected.Path);
            ApplyDownloadSelection(VisibleFilesControl());
        }
        AnnounceBatchSelection();
        UpdateState();
    }

    private bool CanEnterBatchCopyMove(FileCopyMoveOperation operation) =>
        !_disposed && !_viewModel.IsLoading && !IsReadOnlyLocation() &&
        !_isSelectingItems && _downloadBatchId is null && _folderUploadBatchId is null &&
        _batchCopyMoveDialog is null && !_isClosingBatchCopyMove &&
        _copyMoveRepository is { } repository && _copyMoveFolderSource is not null &&
        repository.ProfileId == _profileId &&
        (operation == FileCopyMoveOperation.Copy
            ? repository.Availability.CanCopy
            : repository.Availability.CanMove) &&
        _viewModel.Items.Any(item =>
            FileCopyMoveViewModel.IsDestination(item.Path) &&
            (operation != FileCopyMoveOperation.Move || item.Item.CanDelete));

    private async Task ShowBatchCopyMoveAsync(FileCopyMoveOperation operation)
    {
        if (!_isSelectingCopyMove ||
            _batchSelectionOperation != (operation == FileCopyMoveOperation.Copy
                ? FileBatchSelectionOperation.Copy
                : FileBatchSelectionOperation.Move) ||
            _copyMoveRepository is null ||
            _copyMoveFolderSource is null)
        {
            return;
        }

        var sources = _viewModel.Items
            .Where(item => _batchSelection.Contains(item.Path))
            .Select(item => item.Item)
            .ToArray();
        if (sources.Length != _batchSelection.Count || !BatchCopyMoveSourcesAreCurrent(sources, requireSelection: true))
        {
            ShowBatchSelectionMessage("FileCopyMoveBatchSelectionInvalid", InfoBarSeverity.Error);
            return;
        }
        await ShowBatchCopyMoveDialogAsync(operation, sources);
    }

    private async Task ShowBatchCopyMoveDialogAsync(FileCopyMoveOperation operation, IReadOnlyList<FileItem> selectedSources,
        string? initialDestination = null, bool requireVisibleSources = true, bool offerUndo = false,
        bool allowConflictChoices = true, bool requireSelectedItem = false)
    {
        if (_disposed || IsReadOnlyLocation() || _batchCopyMoveDialog is not null || _fileOperationRecoveryDialog is not null || _isClosingBatchCopyMove || XamlRoot is null ||
            _copyMoveRepository is not { } repository || _copyMoveFolderSource is not { } folders) return;
        var sources = selectedSources.ToArray();
        if (FileCopyMoveBatchViewModel.Validate(sources, operation) !=
            FileCopyMoveBatchValidationStatus.Valid)
        {
            ShowBatchSelectionMessage(
                "FileCopyMoveBatchSelectionInvalid",
                InfoBarSeverity.Error);
            return;
        }

        var sourceParent = _viewModel.CurrentPath;
        var selectionOperation = _batchSelectionOperation;
        var requireSelection = requireVisibleSources && _isSelectingCopyMove;
        var model = new FileCopyMoveBatchViewModel(
            repository,
            folders,
            _profileId,
            sources,
            operation,
            _copyMoveReviewBlocker);
        if (allowConflictChoices) model.SetConflictPolicy(FileCopyMoveConflictPolicy.Skip);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            DefaultButton = ContentDialogButton.Close,
        };
        _batchCopyMoveModel = model;
        _batchCopyMoveDialog = dialog;
        var localization = LocalizationService.Current;
        var progressQueued = false;
        void ProgressChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
        {
            if (args.PropertyName != nameof(FileCopyMoveBatchViewModel.ProcessedCount) || progressQueued) return;
            progressQueued = true;
            if (!DispatcherQueue.TryEnqueue(() =>
            {
                progressQueued = false;
                if (_disposed || _batchCopyMoveModel != model || model.State != FileCopyMoveBatchState.Submitting || dialog.Content is not StackPanel panel) return;
                var progress = panel.Children.OfType<TextBlock>().FirstOrDefault(item => item.Name == "BatchCopyMoveProgress");
                if (progress is not null) progress.Text = FormatBatchCopyMoveProgress(model, localization);
            })) progressQueued = false;
        }
        model.PropertyChanged += ProgressChanged;

        async Task RenderAsync()
        {
            if (_batchCopyMoveModel != model || _batchCopyMoveDialog != dialog)
            {
                return;
            }
            dialog.Title = localization.Get(operation == FileCopyMoveOperation.Copy
                ? "FileCopyMoveBatchCopyTitle"
                : "FileCopyMoveBatchMoveTitle");
            dialog.CloseButtonText = localization.Get(
                model.State is FileCopyMoveBatchState.Submitting or
                    FileCopyMoveBatchState.ChoosingDestination or
                    FileCopyMoveBatchState.LoadingFolders
                    ? "FileCopyMove_Cancel_Button"
                    : "FileCopyMove_Close_Button");
            dialog.PrimaryButtonText = model.State == FileCopyMoveBatchState.ChoosingDestination
                ? localization.Format(
                    operation == FileCopyMoveOperation.Copy
                        ? "FileCopyMoveBatchCopyButton"
                        : "FileCopyMoveBatchMoveButton",
                    sources.Length)
                : string.Empty;
            if (model.State == FileCopyMoveBatchState.ChoosingDestination && model.ConflictPolicy == FileCopyMoveConflictPolicy.Overwrite)
                dialog.PrimaryButtonText = localization.Format(operation == FileCopyMoveOperation.Copy
                    ? "FileCopyMoveCopyOverwriteAction" : "FileCopyMoveMoveOverwriteAction", sources.Length);
            dialog.IsPrimaryButtonEnabled = model.CanSubmit;
            dialog.DefaultButton = ContentDialogButton.Close;
            dialog.Content = BuildBatchCopyMoveContent(model, localization, RenderAsync, allowConflictChoices);
            await Task.CompletedTask;
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (_disposed || repository.ProfileId != _profileId ||
                folders.ProfileId != _profileId || IsReadOnlyLocation() ||
                !string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal) ||
                requireSelection && _batchSelectionOperation != selectionOperation ||
                requireSelectedItem && !SameCopyMoveItem(sources[0], _viewModel.SelectedItem?.Item) ||
                requireVisibleSources && !BatchCopyMoveSourcesAreCurrent(sources, requireSelection))
            {
                dialog.Content = new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Error,
                    Message = localization.Get("FileCopyMoveBatchSelectionInvalid") };
                dialog.PrimaryButtonText = string.Empty; dialog.DefaultButton = ContentDialogButton.Close;
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
            if (_isClosingBatchCopyMove || model.State != FileCopyMoveBatchState.Submitting)
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
            var load = model.LoadFoldersAsync(initialDestination is null ? string.Empty : MutationParent(initialDestination));
            await RenderAsync();
            await load;
            if (initialDestination is not null && model.Folders.FirstOrDefault(folder => folder.Path == initialDestination && folder.CanWrite) is { } destination)
                await model.LoadFoldersAsync(destination.Path, destination.CanWrite);
            await RenderAsync();
        };

        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            model.PropertyChanged -= ProgressChanged;
            model.Dispose();
            if (ReferenceEquals(_batchCopyMoveModel, model))
            {
                _batchCopyMoveModel = null;
            }
            if (ReferenceEquals(_batchCopyMoveDialog, dialog))
            {
                _batchCopyMoveDialog = null;
            }
            _isClosingBatchCopyMove = false;
        }

        var completed = model.State == FileCopyMoveBatchState.Completed;
        var summary = model.Summary;
        var confirmedItems = model.ConfirmedItems;
        ExitDownloadSelectionMode();
        if (!completed)
        {
            return;
        }
        ShowBatchCopyMoveSummary(summary, operation);
        if (summary.ConfirmedCount > 0 && !_disposed &&
            repository.ProfileId == _profileId &&
            string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal))
        {
            await RunAsync(_viewModel.RefreshAsync);
        }
        if (!_disposed)
        {
            UpdateState();
            if (offerUndo && model.ConflictPolicy != FileCopyMoveConflictPolicy.Overwrite && summary.ConfirmedCount == sources.Length && summary.NeedsReviewCount == 0 && confirmedItems.Count == sources.Length && confirmedItems.All(item => item.CanDelete))
                ShowDragMoveUndo(confirmedItems, MutationParent(sources[0].Path), model.DestinationPath);
        }
    }

    private bool BatchCopyMoveSourcesAreCurrent(IReadOnlyList<FileItem> sources, bool requireSelection)
    {
        var current = new Dictionary<string, FileItem>(StringComparer.Ordinal);
        foreach (var item in _viewModel.Items)
            if (!current.TryAdd(item.Path, item.Item)) return false;
        if (sources.Any(source => !current.TryGetValue(source.Path, out var item) || source.Name != item.Name || !SameCopyMoveItem(source, item))) return false;
        if (!requireSelection) return true;
        var visible = VisibleFilesControl().SelectedItems;
        var selected = visible.OfType<FileBrowserEntry>().Select(item => item.Path).ToHashSet(StringComparer.Ordinal);
        return !_isSynchronizingDownloadSelection && _batchSelection.Count == sources.Count && visible.Count == sources.Count && selected.Count == sources.Count &&
            sources.All(source => _batchSelection.Contains(source.Path) && selected.Contains(source.Path));
    }

    private static string FormatBatchCopyMoveProgress(FileCopyMoveBatchViewModel model, LocalizationService localization) =>
        localization.Format(model.Operation == FileCopyMoveOperation.Copy ? "FileCopyMoveBatchCopying" : "FileCopyMoveBatchMoving",
            Math.Min(model.ProcessedCount + 1, model.Sources.Count), model.Sources.Count);

    internal static FrameworkElement BuildBatchCopyMoveContent(
        FileCopyMoveBatchViewModel model,
        LocalizationService localization,
        Func<Task> render, bool allowConflictChoices = false)
    {
        var panel = new StackPanel
        {
            Width = 480,
            MaxWidth = 480,
            Spacing = 12,
        };
        var selected = new TextBlock
        {
            Text = localization.Format(
                "FileCopyMoveBatchSelectedSummary",
                model.Sources.Count),
            TextWrapping = TextWrapping.WrapWholeWords,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        };
        AutomationProperties.SetHeadingLevel(selected, AutomationHeadingLevel.Level2);
        panel.Children.Add(selected);
        panel.Children.Add(new ScrollViewer { MaxHeight = 100, Content = new TextBlock
            { Text = string.Join(Environment.NewLine, model.Sources.Select(source => source.Name)), TextWrapping = TextWrapping.Wrap } });

        if (model.State is FileCopyMoveBatchState.ChoosingDestination or
            FileCopyMoveBatchState.LoadingFolders)
        {
            if (allowConflictChoices)
            {
                var replace = new CheckBox
                {
                    Name = "CopyMoveOverwriteChoice", Content = localization.Get("FileCopyMoveOverwriteChoice"),
                    IsChecked = model.ConflictPolicy == FileCopyMoveConflictPolicy.Overwrite,
                    IsEnabled = model.State == FileCopyMoveBatchState.ChoosingDestination,
                };
                replace.Click += async (_, _) =>
                {
                    model.SetConflictPolicy(replace.IsChecked == true ? FileCopyMoveConflictPolicy.Overwrite : FileCopyMoveConflictPolicy.Skip);
                    await render();
                };
                panel.Children.Add(replace);
                panel.Children.Add(new TextBlock
                {
                    Text = localization.Get(model.ConflictPolicy == FileCopyMoveConflictPolicy.Overwrite
                        ? "FileCopyMoveOverwriteWarning" : "FileCopyMoveSkipHint"), TextWrapping = TextWrapping.Wrap,
                });
            }
            var hint = new TextBlock
            {
                Text = localization.Get("FileCopyMoveBatchDestinationHint"),
                TextWrapping = TextWrapping.WrapWholeWords,
            };
            panel.Children.Add(hint);
            var path = new TextBlock
            {
                Text = string.IsNullOrEmpty(model.DestinationPath)
                    ? localization.Get("FileCopyMove_Destination_Placeholder")
                    : model.DestinationPath,
                TextWrapping = TextWrapping.WrapWholeWords,
            };
            AutomationProperties.SetName(
                path,
                localization.Get("FileCopyMove_Destination_Label"));
            panel.Children.Add(path);
            var up = new Button
            {
                Content = new SymbolIcon(Symbol.Up),
                MinWidth = 48,
                MinHeight = 48,
                IsEnabled = FileCopyMoveViewModel.IsDestination(model.DestinationPath),
            };
            var upLabel = localization.Get("FileBrowserUp.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name");
            AutomationProperties.SetName(up, upLabel);
            up.Click += async (_, _) =>
            {
                var separator = model.DestinationPath.LastIndexOf('/');
                var parent = separator > 0
                    ? model.DestinationPath[..separator]
                    : string.Empty;
                var load = model.LoadFoldersAsync(
                    parent,
                    model.IsKnownWritableFolder(parent));
                await render();
                await load;
                await render();
            };
            panel.Children.Add(up);
            if (model.State == FileCopyMoveBatchState.LoadingFolders)
            {
                panel.Children.Add(new ProgressRing
                {
                    IsActive = true,
                    Width = 40,
                    Height = 40,
                });
            }
            else
            {
                var list = new ListView
                {
                    ItemsSource = model.Folders,
                    IsItemClickEnabled = true,
                    SelectionMode = ListViewSelectionMode.None,
                    MaxHeight = 320,
                    ItemTemplate = FileCopyMoveDialogContent.BuildFolderTemplate(),
                };
                AutomationProperties.SetName(
                    list,
                    localization.Get("FileCopyMove_A11y_DestinationTree"));
                list.ItemClick += async (_, args) =>
                {
                    if (args.ClickedItem is not FileCopyMoveFolder folder)
                    {
                        return;
                    }
                    var load = model.LoadFoldersAsync(folder.Path, folder.CanWrite);
                    await render();
                    await load;
                    await render();
                };
                panel.Children.Add(list);
            }
            return panel;
        }

        if (model.State == FileCopyMoveBatchState.Submitting)
        {
            panel.Children.Add(new ProgressRing
            {
                IsActive = true,
                Width = 40,
                Height = 40,
            });
            var progress = new TextBlock
            {
                Name = "BatchCopyMoveProgress",
                Text = FormatBatchCopyMoveProgress(model, localization),
                TextWrapping = TextWrapping.WrapWholeWords,
            };
            AutomationProperties.SetLiveSetting(progress, AutomationLiveSetting.Polite);
            panel.Children.Add(progress);
            return panel;
        }

        var summary = model.Summary;
        var message = new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Severity = summary.NeedsReviewCount > 0 || summary.FailedCount > 0 ||
                summary.CancelledCount > 0 || summary.NotStartedCount > 0
                ? InfoBarSeverity.Warning
                : model.State == FileCopyMoveBatchState.Completed
                    ? InfoBarSeverity.Success
                    : InfoBarSeverity.Error,
            Message = model.State == FileCopyMoveBatchState.Completed
                ? FormatBatchCopyMoveSummary(localization, summary, model.Operation)
                : localization.Get("FileCopyMoveBatchInvalidDestination"),
        };
        AutomationProperties.SetName(
            message,
            localization.Get("FileCopyMove_A11y_Status"));
        AutomationProperties.SetLiveSetting(message, AutomationLiveSetting.Assertive);
        panel.Children.Add(message);
        if (summary.NeedsReviewCount > 0)
            panel.Children.Add(new TextBlock { Text = localization.Get("FileCopyMoveBatchReviewHint"), TextWrapping = TextWrapping.Wrap });
        if (model.RequiresSignIn)
            panel.Children.Add(new TextBlock { Name = "BatchCopyMoveSignIn", Text = localization.Get("FileCopyMoveBatchSignIn"), TextWrapping = TextWrapping.Wrap });
        return panel;
    }

    private void ShowBatchCopyMoveSummary(
        FileCopyMoveBatchSummary summary,
        FileCopyMoveOperation operation)
    {
        FileCopyMoveBatchStatus.ActionButton = null;
        if (summary.NeedsReviewCount > 0 && _copyMoveRepository?.SupportsCopyMoveReview == true)
        {
            var review = new Button { Content = LocalizationService.Current.Get("FileOperationReviewNow") };
            review.Click += async (_, _) => await ShowCopyMoveRecoveryAsync();
            FileCopyMoveBatchStatus.ActionButton = review;
        }
        FileCopyMoveBatchStatus.Severity = summary.NeedsReviewCount > 0 ||
            summary.FailedCount > 0 || summary.CancelledCount > 0 ||
            summary.NotStartedCount > 0
            ? InfoBarSeverity.Warning
            : InfoBarSeverity.Success;
        FileCopyMoveBatchStatus.Message = FormatBatchCopyMoveSummary(
            LocalizationService.Current,
            summary,
            operation);
        FileCopyMoveBatchStatus.IsOpen = true;
    }

    internal static string FormatBatchCopyMoveSummary(
        LocalizationService localization,
        FileCopyMoveBatchSummary summary,
        FileCopyMoveOperation operation) => localization.Format(
        operation == FileCopyMoveOperation.Copy
            ? "FileCopyMoveBatchCopySummary"
            : "FileCopyMoveBatchMoveSummary",
        summary.SelectedCount,
        summary.ConfirmedCount,
        summary.NeedsReviewCount,
        summary.FailedCount,
        summary.CancelledCount,
        summary.NotStartedCount,
        summary.SkippedCount);

    private void UpdateBatchCopyMoveControls()
    {
        CopyMultipleButton.Visibility = IsReadOnlyLocation() || _isSelectingItems
            ? Visibility.Collapsed
            : Visibility.Visible;
        MoveMultipleButton.Visibility = CopyMultipleButton.Visibility;
        CopyMultipleButton.IsEnabled = CanEnterBatchCopyMove(FileCopyMoveOperation.Copy);
        MoveMultipleButton.IsEnabled = CanEnterBatchCopyMove(FileCopyMoveOperation.Move);
        CopySelectedItemsButton.Visibility =
            _batchSelectionOperation == FileBatchSelectionOperation.Copy
                ? Visibility.Visible
                : Visibility.Collapsed;
        MoveSelectedItemsButton.Visibility =
            _batchSelectionOperation == FileBatchSelectionOperation.Move
                ? Visibility.Visible
                : Visibility.Collapsed;
        var validSelection = _batchSelection.Count > 0;
        CopySelectedItemsButton.IsEnabled = validSelection && _batchCopyMoveDialog is null;
        MoveSelectedItemsButton.IsEnabled = validSelection && _batchCopyMoveDialog is null;
    }

    private void CloseBatchCopyMoveDialog()
    {
        var dialog = _batchCopyMoveDialog;
        var model = _batchCopyMoveModel;
        _batchCopyMoveDialog = null;
        _batchCopyMoveModel = null;
        model?.Cancel();
        model?.Dispose();
        if (dialog is null)
        {
            return;
        }
        _isClosingBatchCopyMove = true;
        dialog.Hide();
    }
}
