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
    private static readonly HashSet<string> SupportedArchiveExtensions =
        new(StringComparer.OrdinalIgnoreCase) { ".zip", ".7z" };

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

        await ClosePreviewAsync();
        var destinationFolder = _viewModel.CurrentPath;
        if (!ArchiveExtractionSourceIsCurrent(repository, destinationFolder, source))
        {
            return;
        }

        var localization = LocalizationService.Current;
        var panel = new StackPanel { Spacing = 12, MaxWidth = 460 };
        panel.Children.Add(new TextBlock
        {
            Text = localization.Format("FileArchiveExtractionConfirmMessage", source.Name),
            TextWrapping = TextWrapping.WrapWholeWords,
        });
        panel.Children.Add(new TextBlock
        {
            Text = localization.Get("FileArchiveExtractionNoOverwriteNote"),
            TextWrapping = TextWrapping.WrapWholeWords,
            Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources[
                "TextFillColorSecondaryBrush"],
        });

        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            Title = localization.Get("FileArchiveExtractionTitle"),
            PrimaryButtonText = localization.Get("FileArchiveExtractionAction"),
            CloseButtonText = localization.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Primary,
            Content = panel,
        };
        var generation = ++_archiveExtractionGeneration;
        _archiveExtractionDialog = dialog;
        FileArchiveExtractionOutcome? outcome = null;
        CancellationTokenSource? operationCancellation = null;

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (_isArchiveExtractionSubmitting)
            {
                return;
            }
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
            _isArchiveExtractionSubmitting = true;
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
                        destinationFolder),
                    operationCancellation.Token);
                if (CanPresentArchiveExtraction(dialog, generation))
                {
                    dialog.Content = BuildArchiveExtractionResult(outcome.Result, localization);
                    dialog.CloseButtonText = localization.Get("FileRecycleCloseAction");
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
            operationCancellation?.Cancel();
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
        SupportedArchiveExtensions.Contains(Path.GetExtension(item.Name));

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
