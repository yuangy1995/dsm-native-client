using LanStash.App.Features.Files.CopyMove;
using LanStash.App.Features.Files.Locations;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private ContentDialog? _archiveExtractionDialog;
    private CancellationTokenSource? _archiveExtractionCancellation;
    private bool _isArchiveExtractionSubmitting;
    private bool _isClosingArchiveExtraction;
    private long _archiveExtractionGeneration;

    private async void ExtractArchive_Click(object sender, RoutedEventArgs e) =>
        await ShowArchiveExtractionAsync();

    private void ExtractArchiveAccelerator_Invoked(
        KeyboardAccelerator sender,
        KeyboardAcceleratorInvokedEventArgs args)
    {
        if (!CanExtractArchive())
        {
            return;
        }
        args.Handled = true;
        _ = ShowArchiveExtractionAsync();
    }

    private async Task ShowArchiveExtractionAsync()
    {
        if (!CanExtractArchive() ||
            _archiveExtractionRepository is not { } repository ||
            _viewModel.SelectedItem?.Item is not { } source)
        {
            return;
        }

        if (!await ClosePreviewAsync()) return;
        var destinationFolder = _viewModel.CurrentPath;
        var extractionDestination = destinationFolder;
        if (!ArchiveExtractionSourceIsCurrent(repository, destinationFolder, source))
        {
            return;
        }

        var localization = LocalizationService.Current;
        var panel = new StackPanel { Spacing = 12, MinWidth = 400, MaxWidth = 480 };
        var notice = new InfoBar { IsOpen = false, IsClosable = false, Severity = InfoBarSeverity.Error };
        var passwordBox = new PasswordBox { Header = localization.Get("ArchivePasswordLabel") };
        var encodingBox = new ComboBox { Header = localization.Get("ArchiveEncodingLabel"), HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var (codepage, key) in new[] { ("", "ArchiveEncodingAuto"), ("chs", "ArchiveEncodingChs"),
            ("cht", "ArchiveEncodingCht"), ("enu", "ArchiveEncodingEnu"), ("jpn", "ArchiveEncodingJpn"), ("krn", "ArchiveEncodingKrn") })
            encodingBox.Items.Add(new ComboBoxItem { Content = localization.Get(key), Tag = codepage });
        encodingBox.SelectedIndex = 0;
        AutomationProperties.SetName(passwordBox, localization.Get("ArchivePasswordLabel"));
        AutomationProperties.SetName(encodingBox, localization.Get("ArchiveEncodingLabel"));
        panel.Children.Add(notice);
        panel.Children.Add(new TextBlock
        {
            Text = localization.Format("FileArchiveExtractionConfirmMessage", source.Name),
            TextWrapping = TextWrapping.WrapWholeWords,
        });
        panel.Children.Add(new TextBlock
        {
            Text = localization.Get("FileArchiveExtractionNoOverwriteNote"),
            TextWrapping = TextWrapping.WrapWholeWords,
            Opacity = 0.8,
        });
        var destinationLabel = new TextBlock { Text = extractionDestination, TextWrapping = TextWrapping.WrapWholeWords };
        AutomationProperties.SetName(destinationLabel, localization.Get("ArchiveDestinationLabel"));
        var chooseDestination = new Button { Name = "ChooseArchiveDestination", Content = localization.Get("ArchiveChooseDestination"),
            IsEnabled = _copyMoveFolderSource?.ProfileId == _profileId };
        var destinationBrowser = new StackPanel { Spacing = 8, Visibility = Visibility.Collapsed };
        panel.Children.Add(new TextBlock { Text = localization.Get("ArchiveDestinationLabel") });
        panel.Children.Add(destinationLabel); panel.Children.Add(chooseDestination); panel.Children.Add(destinationBrowser);
        panel.Children.Add(passwordBox);
        panel.Children.Add(encodingBox);
        var keepFolders = new CheckBox { Name = "KeepArchiveFolders", Content = localization.Get("ArchiveKeepFolders"), IsChecked = true };
        var createFolder = new CheckBox { Name = "CreateArchiveFolder", Content = localization.Get("ArchiveCreateFolder"), IsChecked = true };
        var overwrite = new CheckBox { Name = "OverwriteArchiveFiles", Content = localization.Get("ArchiveOverwriteFiles") };
        var overwriteConfirmation = new CheckBox { Name = "ConfirmArchiveOverwrite",
            Content = new TextBlock { Text = localization.Get("ArchiveOverwriteConfirm"), TextWrapping = TextWrapping.WrapWholeWords },
            Visibility = Visibility.Collapsed };
        panel.Children.Add(keepFolders); panel.Children.Add(createFolder); panel.Children.Add(overwrite); panel.Children.Add(overwriteConfirmation);

        var chooseItems = new CheckBox { Name = "ChooseArchiveItems", Content = localization.Get("ArchiveChooseItems") };
        var loadItems = new Button { Name = "LoadArchiveItems", Content = localization.Get("ArchiveLoadItems"), Visibility = Visibility.Collapsed };
        var itemsProgress = new ProgressRing { Width = 24, Height = 24, IsActive = false, Visibility = Visibility.Collapsed };
        var itemsList = new ListView { Name = "ArchiveItemsList", SelectionMode = ListViewSelectionMode.Multiple,
            Height = 200, Visibility = Visibility.Collapsed };
        AutomationProperties.SetName(itemsList, localization.Get("ArchiveItemsLabel"));
        var selectionStatus = new TextBlock { TextWrapping = TextWrapping.WrapWholeWords, Visibility = Visibility.Collapsed };
        panel.Children.Add(chooseItems); panel.Children.Add(loadItems); panel.Children.Add(itemsProgress);
        panel.Children.Add(itemsList); panel.Children.Add(selectionStatus);
        var isLoadingItems = false;
        string? previewCodepage = null;
        CancellationTokenSource? previewCancellation = null;
        CancellationTokenSource? destinationCancellation = null;
        var isChoosingDestination = false;

        var form = new ScrollViewer { Content = panel, MaxHeight = 480 };
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = localization.Get("FileArchiveExtractionTitle"),
            PrimaryButtonText = localization.Get("FileArchiveExtractionAction"),
            CloseButtonText = localization.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Primary,
            Content = form,
        };
        var generation = ++_archiveExtractionGeneration;
        _archiveExtractionDialog = dialog;
        void UpdateConfirmation()
        {
            overwriteConfirmation.Visibility = overwrite.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
            dialog.DefaultButton = overwrite.IsChecked == true ? ContentDialogButton.Close : ContentDialogButton.Primary;
            if (!_isArchiveExtractionSubmitting && ReferenceEquals(dialog.Content, form))
                dialog.IsPrimaryButtonEnabled = !isLoadingItems && !isChoosingDestination &&
                    (overwrite.IsChecked != true || overwriteConfirmation.IsChecked == true) &&
                    (chooseItems.IsChecked != true || itemsList.SelectedItems.Count > 0);
        }
        void ResetConfirmation() { overwriteConfirmation.IsChecked = false; UpdateConfirmation(); }
        keepFolders.Checked += (_, _) => ResetConfirmation(); keepFolders.Unchecked += (_, _) => ResetConfirmation();
        createFolder.Checked += (_, _) => ResetConfirmation(); createFolder.Unchecked += (_, _) => ResetConfirmation();
        overwrite.Checked += (_, _) => ResetConfirmation(); overwrite.Unchecked += (_, _) => ResetConfirmation();
        overwriteConfirmation.Checked += (_, _) => UpdateConfirmation(); overwriteConfirmation.Unchecked += (_, _) => UpdateConfirmation();
        passwordBox.PasswordChanged += (_, _) => ResetConfirmation(); encodingBox.SelectionChanged += (_, _) => ResetConfirmation();
        async Task BrowseDestinationAsync(string path, bool canWrite)
        {
            if (_copyMoveFolderSource is not { } folders || folders.ProfileId != _profileId) return;
            destinationCancellation?.Cancel();
            var cancellation = new CancellationTokenSource(); destinationCancellation = cancellation;
            isChoosingDestination = true; UpdateConfirmation();
            destinationBrowser.Visibility = Visibility.Visible; destinationBrowser.Children.Clear();
            destinationBrowser.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24 });
            try
            {
                var children = await folders.LoadFoldersAsync(path, cancellation.Token);
                if (cancellation.IsCancellationRequested || !CanPresentArchiveExtraction(dialog, generation)) return;
                destinationBrowser.Children.Clear();
                destinationBrowser.Children.Add(new TextBlock { Text = path.Length == 0 ? localization.Get("FileLocationsSharesLabel.Text") : path,
                    TextWrapping = TextWrapping.WrapWholeWords });
                var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                var up = new Button { Content = new SymbolIcon(Symbol.Up), IsEnabled = path.Length > 0 };
                AutomationProperties.SetName(up, localization.Get("FileBrowserUp.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name"));
                up.Click += async (_, _) => await BrowseDestinationAsync(path.LastIndexOf('/') > 0 ? path[..path.LastIndexOf('/')] : string.Empty, false);
                var use = new Button { Name = "UseArchiveDestination", Content = localization.Get("ArchiveUseDestination"),
                    IsEnabled = canWrite && path.Length > 0 && !folders.IsReadOnlyPath(path) };
                use.Click += (_, _) =>
                {
                    extractionDestination = path; destinationLabel.Text = path;
                    isChoosingDestination = false; destinationBrowser.Visibility = Visibility.Collapsed; ResetConfirmation();
                };
                var cancel = new Button { Content = localization.Get("ActionCancel") };
                cancel.Click += (_, _) => { isChoosingDestination = false; destinationBrowser.Visibility = Visibility.Collapsed; UpdateConfirmation(); };
                actions.Children.Add(up); actions.Children.Add(use); actions.Children.Add(cancel); destinationBrowser.Children.Add(actions);
                var list = new ListView { Name = "ArchiveDestinationFolders", Height = 160, SelectionMode = ListViewSelectionMode.Single };
                AutomationProperties.SetName(list, localization.Get("ArchiveDestinationLabel"));
                foreach (var folder in children) list.Items.Add(new ListViewItem { Content = folder.Name, Tag = folder });
                list.SelectionChanged += async (_, _) =>
                {
                    if (list.SelectedItem is ListViewItem { Tag: FileCopyMoveFolder folder })
                        await BrowseDestinationAsync(folder.Path, folder.CanWrite);
                };
                destinationBrowser.Children.Add(list);
            }
            catch (OperationCanceledException) { }
            catch (Exception)
            {
                if (CanPresentArchiveExtraction(dialog, generation))
                { destinationBrowser.Children.Clear(); destinationBrowser.Visibility = Visibility.Collapsed; notice.Message = localization.Get("ArchiveDestinationFailed"); notice.IsOpen = true; isChoosingDestination = false; UpdateConfirmation(); }
            }
            finally
            {
                if (ReferenceEquals(destinationCancellation, cancellation)) destinationCancellation = null;
                cancellation.Dispose();
            }
        }
        chooseDestination.Click += async (_, _) => await BrowseDestinationAsync(string.Empty, false);
        void InvalidatePreview()
        {
            previewCodepage = null;
            previewCancellation?.Cancel();
            itemsList.Items.Clear();
            itemsList.Visibility = Visibility.Collapsed;
            selectionStatus.Visibility = Visibility.Collapsed;
            ResetConfirmation();
        }
        passwordBox.PasswordChanged += (_, _) => InvalidatePreview();
        encodingBox.SelectionChanged += (_, _) => InvalidatePreview();
        chooseItems.Checked += (_, _) => { loadItems.Visibility = Visibility.Visible; ResetConfirmation(); };
        chooseItems.Unchecked += (_, _) =>
        {
            InvalidatePreview(); loadItems.Visibility = Visibility.Collapsed;
        };
        itemsList.SelectionChanged += (_, _) =>
        {
            selectionStatus.Text = localization.Format("ArchiveSelectedCount", itemsList.SelectedItems.Count);
            ResetConfirmation();
        };
        loadItems.Click += async (_, _) =>
        {
            if (isLoadingItems || _isArchiveExtractionSubmitting ||
                !ArchiveExtractionSourceIsCurrent(repository, destinationFolder, source)) return;
            var cancellation = new CancellationTokenSource();
            previewCancellation = cancellation;
            _archiveExtractionCancellation = cancellation;
            isLoadingItems = true; loadItems.IsEnabled = false;
            itemsProgress.IsActive = true; itemsProgress.Visibility = Visibility.Visible;
            itemsList.Items.Clear(); notice.IsOpen = false;
            UpdateConfirmation();
            try
            {
                var encoding = (string)((ComboBoxItem)encodingBox.SelectedItem).Tag;
                var preview = await repository.PreviewAsync(new FileArchiveExtractionRequest(_profileId,
                    new FileArchiveExtractionSource(source), destinationFolder)
                    { Options = new(string.IsNullOrEmpty(passwordBox.Password) ? null : passwordBox.Password,
                        encoding.Length == 0 ? null : encoding) }, cancellation.Token);
                if (!CanPresentArchiveExtraction(dialog, generation) || cancellation.IsCancellationRequested ||
                    !ArchiveExtractionSourceIsCurrent(repository, destinationFolder, source)) return;
                if (preview.Items.Any(item => item.Id is null)) throw new NotSupportedException();
                previewCodepage = preview.Codepage;
                foreach (var item in preview.Items)
                    itemsList.Items.Add(new ListViewItem { Content = item.RelativePath, Tag = item });
                itemsList.Visibility = Visibility.Visible;
                selectionStatus.Text = localization.Get(preview.Items.Count == 0 ? "ArchiveContentsEmpty" : "ArchiveSelectItemsHint");
                selectionStatus.Visibility = Visibility.Visible;
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                if (CanPresentArchiveExtraction(dialog, generation))
                {
                    notice.Message = localization.Get(error is DsmException { Code: 1403 }
                        ? "ArchivePasswordIncorrect" : "ArchivePreviewFailed");
                    notice.IsOpen = true;
                }
            }
            finally
            {
                if (ReferenceEquals(_archiveExtractionCancellation, cancellation)) _archiveExtractionCancellation = null;
                if (ReferenceEquals(previewCancellation, cancellation)) previewCancellation = null;
                cancellation.Dispose(); isLoadingItems = false; loadItems.IsEnabled = true;
                itemsProgress.IsActive = false; itemsProgress.Visibility = Visibility.Collapsed;
                UpdateConfirmation();
            }
        };
        FileArchiveExtractionOutcome? outcome = null;
        CancellationTokenSource? operationCancellation = null;

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (_isArchiveExtractionSubmitting || isLoadingItems || isChoosingDestination)
            {
                return;
            }
            if (chooseItems.IsChecked == true && itemsList.SelectedItems.Count == 0)
            { notice.Message = localization.Get("ArchiveSelectItemsHint"); notice.IsOpen = true; return; }
            if (overwrite.IsChecked == true && overwriteConfirmation.IsChecked != true)
            { notice.Message = localization.Get("ArchiveOverwriteConfirm"); notice.IsOpen = true; return; }
            if (!ArchiveExtractionSourceIsCurrent(repository, destinationFolder, source))
            {
                dialog.Content = BuildArchiveExtractionMessage(
                    localization.Get("FileArchiveExtractionSourceChanged"),
                    InfoBarSeverity.Error);
                dialog.PrimaryButtonText = string.Empty;
                dialog.CloseButtonText = localization.Get("FileRecycleCloseAction");
                return;
            }

            var deferral = args.GetDeferral();
            notice.IsOpen = false;
            var codepage = (string)((ComboBoxItem)encodingBox.SelectedItem).Tag;
            var options = new FileArchiveExtractionOptions(string.IsNullOrEmpty(passwordBox.Password) ? null : passwordBox.Password,
                chooseItems.IsChecked == true ? previewCodepage : codepage.Length == 0 ? null : codepage)
            { KeepDirectoryStructure = keepFolders.IsChecked == true, CreateSubfolder = createFolder.IsChecked == true, Overwrite = overwrite.IsChecked == true,
                SelectedItems = chooseItems.IsChecked == true
                    ? itemsList.SelectedItems.Cast<ListViewItem>().Select(item => (FileArchiveExtractionListedItem)item.Tag).ToArray() : null };
            var confirmedOverwrite = overwriteConfirmation.IsChecked == true;
            _isArchiveExtractionSubmitting = true;
            passwordBox.Password = string.Empty;
            operationCancellation = new CancellationTokenSource();
            _archiveExtractionCancellation = operationCancellation;
            dialog.PrimaryButtonText = string.Empty;
            var progress = new ProgressRing { IsActive = true, Width = 32, Height = 32 };
            AutomationProperties.SetName(
                progress,
                localization.Get("FileArchiveExtractionProgressAutomationName"));
            dialog.Content = new StackPanel
            {
                Spacing = 12,
                Children =
                {
                    progress,
                    new TextBlock
                    {
                        Text = localization.Get("FileArchiveExtractionWorking"),
                        TextWrapping = TextWrapping.WrapWholeWords,
                    },
                },
            };
            try
            {
                outcome = await repository.ExtractAsync(
                    new FileArchiveExtractionRequest(
                        _profileId,
                        new FileArchiveExtractionSource(source),
                        extractionDestination) { Options = options, OverwriteConfirmed = confirmedOverwrite },
                    operationCancellation.Token);
                if (CanPresentArchiveExtraction(dialog, generation))
                {
                    if (!outcome.Result.Submitted && outcome.Result.DiagnosticTag == "file.archive-extraction.password-required")
                    {
                        notice.Message = localization.Get("ArchivePasswordIncorrect"); notice.IsOpen = true;
                        dialog.Content = form;
                        dialog.PrimaryButtonText = localization.Get("FileArchiveExtractionAction");
                        passwordBox.Focus(FocusState.Programmatic);
                    }
                    else
                    {
                        dialog.Content = BuildArchiveExtractionResult(outcome.Result, localization);
                        dialog.CloseButtonText = localization.Get("FileRecycleCloseAction");
                    }
                }
            }
            catch (DsmException)
            {
                if (CanPresentArchiveExtraction(dialog, generation))
                {
                    dialog.Content = BuildArchiveExtractionMessage(
                        localization.Get("FileArchiveExtractionAuthenticationError"),
                        InfoBarSeverity.Error);
                    dialog.CloseButtonText = localization.Get("FileRecycleCloseAction");
                }
            }
            catch (Exception)
            {
                if (CanPresentArchiveExtraction(dialog, generation))
                {
                    dialog.Content = BuildArchiveExtractionMessage(
                        localization.Get("FileArchiveExtractionFailed"),
                        InfoBarSeverity.Error);
                    dialog.CloseButtonText = localization.Get("FileRecycleCloseAction");
                }
            }
            finally
            {
                var completedCancellation = operationCancellation!;
                completedCancellation.Dispose();
                operationCancellation = null;
                if (_archiveExtractionGeneration == generation &&
                    ReferenceEquals(_archiveExtractionCancellation, completedCancellation))
                {
                    _archiveExtractionCancellation = null;
                    _isArchiveExtractionSubmitting = false;
                    UpdateConfirmation();
                }
                deferral.Complete();
            }
        };
        dialog.Closing += (_, args) =>
        {
            if (_isClosingArchiveExtraction || !_isArchiveExtractionSubmitting)
            {
                return;
            }
            args.Cancel = true;
            _archiveExtractionCancellation?.Cancel();
        };

        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            passwordBox.Password = string.Empty;
            operationCancellation?.Cancel();
            previewCancellation?.Cancel();
            destinationCancellation?.Cancel();
            if (_archiveExtractionGeneration == generation &&
                ReferenceEquals(_archiveExtractionDialog, dialog))
            {
                _archiveExtractionDialog = null;
                _isArchiveExtractionSubmitting = false;
                _isClosingArchiveExtraction = false;
            }
        }

        if (!_disposed && _archiveExtractionGeneration == generation &&
            outcome?.Result.RequiresRefresh == true &&
            repository.ProfileId == _profileId &&
            string.Equals(_viewModel.CurrentPath, destinationFolder, StringComparison.Ordinal))
        {
            await RunAsync(_viewModel.RefreshAsync);
        }
    }

    private bool CanExtractArchive() =>
        !_disposed && !_viewModel.IsLoading && !_isSelectingItems &&
        _archiveExtractionDialog is null && !_isClosingArchiveExtraction &&
        _archiveExtractionRepository?.Availability.IsAvailable == true &&
        _locationsViewModel.SelectedSource is not
            (FileLocationSource.Remote or FileLocationSource.Recycle) &&
        _viewModel.SelectedItem?.Item is { } source &&
        IsSupportedArchiveExtractionSource(source, _viewModel.CurrentPath);

    private bool ArchiveExtractionSourceIsCurrent(
        IFileArchiveExtractionRepository repository,
        string destinationFolder,
        FileItem source) =>
        !_disposed && repository.ProfileId == _profileId &&
        string.Equals(destinationFolder, _viewModel.CurrentPath, StringComparison.Ordinal) &&
        _viewModel.SelectedItem?.Item == source &&
        IsSupportedArchiveExtractionSource(source, destinationFolder);

    private static bool IsSupportedArchiveExtractionSource(FileItem item, string parent) =>
        !item.IsDirectory && item.Size > 0 &&
        !string.IsNullOrWhiteSpace(parent) &&
        item.Path.StartsWith(parent + "/", StringComparison.Ordinal) &&
        !item.Path[(parent.Length + 1)..].Contains('/') &&
        !item.Path.Split('/').Any(segment =>
            segment.Equals("#recycle", StringComparison.OrdinalIgnoreCase)) &&
        FileArchiveExtractionOptions.IsSupportedArchive(item.Name);

    private static FrameworkElement BuildArchiveExtractionResult(
        MutationResult result,
        LocalizationService localization)
    {
        if (result.Status == MutationResultStatus.PartialSuccess)
        {
            var message = result.Counts.Unknown > 0
                ? localization.Format("FileArchiveExtractionPartialNeedsReview",
                    result.Counts.Succeeded, result.Counts.Unknown)
                : localization.Format("FileArchiveExtractionPartialFailed",
                    result.Counts.Succeeded, result.Counts.Failed);
            return BuildArchiveExtractionMessage(message, InfoBarSeverity.Warning);
        }
        var key = result.Status switch
        {
            MutationResultStatus.ConfirmedSuccess => "FileArchiveExtractionSuccess",
            MutationResultStatus.CancelledBeforeSubmission => "FileArchiveExtractionCancelled",
            MutationResultStatus.PermissionDenied => "FileArchiveExtractionPermissionDenied",
            MutationResultStatus.Unsupported => "FileArchiveExtractionUnsupported",
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission =>
                    "FileArchiveExtractionNeedsReview",
            _ => "FileArchiveExtractionFailed",
        };
        var severity = result.Status switch
        {
            MutationResultStatus.ConfirmedSuccess => InfoBarSeverity.Success,
            MutationResultStatus.CancelledBeforeSubmission => InfoBarSeverity.Informational,
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission =>
                    InfoBarSeverity.Warning,
            _ => InfoBarSeverity.Error,
        };
        return BuildArchiveExtractionMessage(localization.Get(key), severity);
    }

    private static InfoBar BuildArchiveExtractionMessage(
        string message,
        InfoBarSeverity severity) => new()
        {
            IsOpen = true,
            IsClosable = false,
            Message = message,
            Severity = severity,
        };

    private bool CanPresentArchiveExtraction(ContentDialog dialog, long generation) =>
        !_disposed && !_isClosingArchiveExtraction &&
        _archiveExtractionGeneration == generation &&
        ReferenceEquals(_archiveExtractionDialog, dialog);

    private void UpdateArchiveExtractionControls()
    {
        ExtractArchiveButton.Visibility = _isSelectingItems
            ? Visibility.Collapsed
            : Visibility.Visible;
        ExtractArchiveButton.IsEnabled = CanExtractArchive();
    }

    private void CloseArchiveExtractionDialog()
    {
        var dialog = _archiveExtractionDialog;
        _archiveExtractionGeneration++;
        _archiveExtractionDialog = null;
        _archiveExtractionCancellation?.Cancel();
        _isArchiveExtractionSubmitting = false;
        if (dialog is null)
        {
            return;
        }
        _isClosingArchiveExtraction = true;
        try
        {
            dialog.Hide();
        }
        finally
        {
            _isClosingArchiveExtraction = false;
        }
    }
}
