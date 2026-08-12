using LanStash.App.Features.Files.Locations;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private ContentDialog? _archiveCompressionDialog;
    private CancellationTokenSource? _archiveCompressionCancellation;
    private bool _isArchiveCompressionSubmitting;
    private bool _isClosingArchiveCompression;

    private async void CreateArchive_Click(object sender, RoutedEventArgs e)
    {
        await ClosePreviewAsync();
        EnterArchiveCompressionSelectionMode();
    }

    private async void CreateArchiveSelected_Click(object sender, RoutedEventArgs e) =>
        await ShowArchiveCompressionAsync();

    private void EnterArchiveCompressionSelectionMode()
    {
        if (!CanEnterArchiveCompression())
        {
            return;
        }

        var selected = _viewModel.SelectedItem;
        _batchSelectionOperation = FileBatchSelectionOperation.Compress;
        _batchSelection.Clear();
        FileList.SelectionMode = ListViewSelectionMode.Multiple;
        FileGrid.SelectionMode = ListViewSelectionMode.Multiple;
        FileList.SelectedItems.Clear();
        FileGrid.SelectedItems.Clear();
        if (selected is not null && CanSelectForArchiveCompression(selected.Item))
        {
            _batchSelection.Add(selected.Path);
            ApplyDownloadSelection(VisibleFilesControl());
        }
        AnnounceBatchSelection();
        UpdateState();
    }

    private bool CanEnterArchiveCompression() =>
        !_disposed && !_viewModel.IsLoading && !_isSelectingItems &&
        _archiveCompressionDialog is null && !_isClosingArchiveCompression &&
        _archiveCompressionRepository?.Availability.IsAvailable == true &&
        _locationsViewModel.SelectedSource is not
            (FileLocationSource.Remote or FileLocationSource.Recycle) &&
        _viewModel.Items.Any(item => CanSelectForArchiveCompression(item.Item));

    private bool CanSelectForArchiveCompression(FileItem item) =>
        _locationsViewModel.SelectedSource is not
            (FileLocationSource.Remote or FileLocationSource.Recycle) &&
        !string.IsNullOrWhiteSpace(_viewModel.CurrentPath) &&
        item.Path.StartsWith(_viewModel.CurrentPath + "/", StringComparison.Ordinal) &&
        !item.Path[(_viewModel.CurrentPath.Length + 1)..].Contains('/') &&
        !item.Path.Split('/').Any(segment =>
            segment.Equals("#recycle", StringComparison.OrdinalIgnoreCase));

    private async Task ShowArchiveCompressionAsync()
    {
        if (!_isSelectingArchiveCompression ||
            _archiveCompressionRepository is not { } repository)
        {
            return;
        }

        var sources = _viewModel.Items
            .Where(item => _batchSelection.Contains(item.Path))
            .Select(item => item.Item)
            .ToArray();
        if (sources.Length is < 1 or > 20 ||
            sources.Any(item => !CanSelectForArchiveCompression(item)))
        {
            ShowBatchSelectionMessage(
                "FileArchiveCompressionSelectionInvalid",
                InfoBarSeverity.Error);
            return;
        }

        var sourceParent = _viewModel.CurrentPath;
        var localization = LocalizationService.Current;
        var nameBox = new TextBox
        {
            Header = localization.Get("FileArchiveCompressionNameLabel"),
            Text = sources.Length == 1
                ? Path.GetFileNameWithoutExtension(sources[0].Name)
                : localization.Get("FileArchiveCompressionDefaultName"),
            MinWidth = 320,
            MaxLength = 255,
        };
        AutomationProperties.SetName(
            nameBox,
            localization.Get("FileArchiveCompressionNameAutomationName"));
        var panel = new StackPanel { Spacing = 12, MaxWidth = 460 };
        panel.Children.Add(new TextBlock
        {
            Text = localization.Format("FileArchiveCompressionConfirmMessage", sources.Length),
            TextWrapping = TextWrapping.WrapWholeWords,
        });
        panel.Children.Add(nameBox);
        panel.Children.Add(new TextBlock
        {
            Text = localization.Get("FileArchiveCompressionFormatNote"),
            TextWrapping = TextWrapping.WrapWholeWords,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[
                "TextFillColorSecondaryBrush"],
        });

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = localization.Get("FileArchiveCompressionTitle"),
            PrimaryButtonText = localization.Get("FileArchiveCompressionCreateAction"),
            CloseButtonText = localization.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Primary,
            Content = panel,
        };
        _archiveCompressionDialog = dialog;
        FileArchiveCompressionOutcome? outcome = null;

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (_isArchiveCompressionSubmitting)
            {
                return;
            }
            if (!ValidArchiveName(nameBox.Text) ||
                !ArchiveCompressionSourcesAreCurrent(repository, sourceParent, sources))
            {
                ShowBatchSelectionMessage(
                    ValidArchiveName(nameBox.Text)
                        ? "FileArchiveCompressionSourceChanged"
                        : "FileArchiveCompressionNameInvalid",
                    InfoBarSeverity.Error);
                return;
            }

            var deferral = args.GetDeferral();
            _isArchiveCompressionSubmitting = true;
            _archiveCompressionCancellation = new CancellationTokenSource();
            dialog.PrimaryButtonText = string.Empty;
            dialog.CloseButtonText = localization.Get("ActionCancel");
            var progress = new ProgressRing { IsActive = true, Width = 32, Height = 32 };
            AutomationProperties.SetName(
                progress,
                localization.Get("FileArchiveCompressionProgressAutomationName"));
            dialog.Content = new StackPanel
            {
                Spacing = 12,
                Children =
                {
                    progress,
                    new TextBlock
                    {
                        Text = localization.Get("FileArchiveCompressionWorking"),
                        TextWrapping = TextWrapping.WrapWholeWords,
                    },
                },
            };
            try
            {
                outcome = await repository.CompressAsync(
                    new FileArchiveCompressionRequest(
                        _profileId,
                        sources.Select(item => new FileArchiveCompressionSource(item)).ToArray(),
                        nameBox.Text),
                    _archiveCompressionCancellation.Token);
                dialog.Content = BuildArchiveCompressionResult(outcome.Result, localization);
                dialog.CloseButtonText = localization.Get("FileRecycleCloseAction");
            }
            catch (DsmException)
            {
                dialog.Content = BuildArchiveCompressionMessage(
                    localization.Get("FileArchiveCompressionAuthenticationError"),
                    InfoBarSeverity.Error);
                dialog.CloseButtonText = localization.Get("FileRecycleCloseAction");
            }
            catch (Exception)
            {
                dialog.Content = BuildArchiveCompressionMessage(
                    localization.Get("FileArchiveCompressionFailed"),
                    InfoBarSeverity.Error);
                dialog.CloseButtonText = localization.Get("FileRecycleCloseAction");
            }
            finally
            {
                _archiveCompressionCancellation?.Dispose();
                _archiveCompressionCancellation = null;
                _isArchiveCompressionSubmitting = false;
                deferral.Complete();
            }
        };
        dialog.Closing += (_, args) =>
        {
            if (_isClosingArchiveCompression || !_isArchiveCompressionSubmitting)
            {
                return;
            }
            args.Cancel = true;
            _archiveCompressionCancellation?.Cancel();
        };

        try
        {
            await dialog.ShowAsync();
        }
        finally
        {
            _archiveCompressionCancellation?.Cancel();
            _archiveCompressionCancellation?.Dispose();
            _archiveCompressionCancellation = null;
            _archiveCompressionDialog = null;
            _isArchiveCompressionSubmitting = false;
            _isClosingArchiveCompression = false;
        }

        ExitDownloadSelectionMode();
        if (!_disposed && outcome?.Result.RequiresRefresh == true &&
            repository.ProfileId == _profileId &&
            string.Equals(_viewModel.CurrentPath, sourceParent, StringComparison.Ordinal))
        {
            await RunAsync(_viewModel.RefreshAsync);
        }
    }

    private bool ArchiveCompressionSourcesAreCurrent(
        IFileArchiveCompressionRepository repository,
        string parent,
        IReadOnlyList<FileItem> sources) =>
        !_disposed && repository.ProfileId == _profileId &&
        string.Equals(parent, _viewModel.CurrentPath, StringComparison.Ordinal) &&
        sources.All(source => _viewModel.Items.Any(current =>
            current.Item == source && CanSelectForArchiveCompression(current.Item)));

    private static bool ValidArchiveName(string value)
    {
        var name = value.Trim();
        while (name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
        {
            name = name[..^4];
        }
        return name.Length > 0 && name is not ("." or "..") &&
            name.IndexOfAny(['/', '\\', '\r', '\n', '\0']) < 0;
    }

    private static FrameworkElement BuildArchiveCompressionResult(
        MutationResult result,
        LocalizationService localization)
    {
        var key = result.Status switch
        {
            MutationResultStatus.ConfirmedSuccess => "FileArchiveCompressionSuccess",
            MutationResultStatus.CancelledBeforeSubmission => "FileArchiveCompressionCancelled",
            MutationResultStatus.PermissionDenied => "FileArchiveCompressionPermissionDenied",
            MutationResultStatus.Unsupported => "FileArchiveCompressionUnsupported",
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission =>
                    "FileArchiveCompressionNeedsReview",
            _ => "FileArchiveCompressionFailed",
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
        return BuildArchiveCompressionMessage(localization.Get(key), severity);
    }

    private static InfoBar BuildArchiveCompressionMessage(
        string message,
        InfoBarSeverity severity) => new()
        {
            IsOpen = true,
            IsClosable = false,
            Message = message,
            Severity = severity,
        };

    private void UpdateArchiveCompressionControls()
    {
        CreateArchiveButton.Visibility = _isSelectingItems
            ? Visibility.Collapsed
            : Visibility.Visible;
        CreateArchiveButton.IsEnabled = CanEnterArchiveCompression();
    }

    private void CloseArchiveCompressionDialog()
    {
        var dialog = _archiveCompressionDialog;
        _archiveCompressionDialog = null;
        _archiveCompressionCancellation?.Cancel();
        if (dialog is null)
        {
            return;
        }
        _isClosingArchiveCompression = true;
        dialog.Hide();
    }
}
