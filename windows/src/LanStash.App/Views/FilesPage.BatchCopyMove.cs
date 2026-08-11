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
            _copyMoveRepository is not { } repository ||
            _copyMoveFolderSource is not { } folders)
        {
            return;
        }

        var sources = _viewModel.Items
            .Where(item => _batchSelection.Contains(item.Path))
            .Select(item => item.Item)
            .ToArray();
        if (FileCopyMoveBatchViewModel.Validate(sources, operation) !=
            FileCopyMoveBatchValidationStatus.Valid)
        {
            ShowBatchSelectionMessage(
                "FileCopyMoveBatchSelectionInvalid",
                InfoBarSeverity.Error);
            return;
        }

        var sourceParent = _viewModel.CurrentPath;
        var model = new FileCopyMoveBatchViewModel(
            repository,
            folders,
            _profileId,
            sources,
            operation,
            _copyMoveReviewBlocker);
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            DefaultButton = ContentDialogButton.Primary,
        };
        _batchCopyMoveModel = model;
        _batchCopyMoveDialog = dialog;
        var localization = LocalizationService.Current;

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
            dialog.IsPrimaryButtonEnabled = model.CanSubmit;
            dialog.DefaultButton = string.IsNullOrEmpty(dialog.PrimaryButtonText)
                ? ContentDialogButton.Close
                : ContentDialogButton.Primary;
            dialog.Content = BuildBatchCopyMoveContent(model, localization, RenderAsync);
            await Task.CompletedTask;
        }

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (_disposed || repository.ProfileId != _profileId ||
                folders.ProfileId != _profileId || IsReadOnlyLocation() ||
                !string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal) ||
                sources.Any(source => !_viewModel.Items.Any(item =>
                    SameCopyMoveItem(source, item.Item))))
            {
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
        }
    }

    internal static FrameworkElement BuildBatchCopyMoveContent(
        FileCopyMoveBatchViewModel model,
        LocalizationService localization,
        Func<Task> render)
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

        if (model.State is FileCopyMoveBatchState.ChoosingDestination or
            FileCopyMoveBatchState.LoadingFolders)
        {
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
            AutomationProperties.SetName(
                up,
                localization.Get(
                    "FileBrowserUp.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
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
                Text = localization.Format(
                    model.Operation == FileCopyMoveOperation.Copy
                        ? "FileCopyMoveBatchCopying"
                        : "FileCopyMoveBatchMoving",
                    Math.Min(model.ProcessedCount + 1, model.Sources.Count),
                    model.Sources.Count),
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
        return panel;
    }

    private void ShowBatchCopyMoveSummary(
        FileCopyMoveBatchSummary summary,
        FileCopyMoveOperation operation)
    {
        FileCopyMoveBatchStatus.ActionButton = null;
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
        summary.NotStartedCount);

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
        var validSelection = _batchSelection.Count is > 0 and <=
            FileCopyMoveBatchViewModel.MaximumItemCount;
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
