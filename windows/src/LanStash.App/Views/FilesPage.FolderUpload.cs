using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private Guid? _folderUploadBatchId;
    private CancellationTokenSource? _folderUploadPreparation;
    private ContentDialog? _folderUploadDialog;

    private async void UploadFolder_Click(object sender, RoutedEventArgs e) =>
        await UploadFolderToCurrentFolderAsync();

    private bool CanUploadFolder() =>
        !_disposed &&
        !_viewModel.IsLoading &&
        !_isChoosingUpload &&
        _downloadBatchId is null &&
        _folderUploadBatchId is null &&
        !IsReadOnlyLocation() &&
        _mutationRepository?.FileMutationAvailability.CanCreateFolder == true &&
        !string.IsNullOrWhiteSpace(_viewModel.CurrentPath);

    private async Task UploadFolderToCurrentFolderAsync()
    {
        if (!CanUploadFolder())
        {
            return;
        }

        await PrepareFolderUploadAsync(_viewModel.CurrentPath, sourcePath: null);
    }

    private async Task PrepareFolderUploadAsync(string targetPath, string? sourcePath)
    {
        if (_disposed || _folderUploadPreparation is not null) return;
        using var cancellation = new CancellationTokenSource();
        _folderUploadPreparation = cancellation;
        var token = cancellation.Token;
        _isChoosingUpload = true;
        UpdateState();
        ShowFolderUploadPreparing(cancellation);
        try
        {
            var result = sourcePath is null
                ? await _transfers.PickFolderUploadPlanAsync(token)
                : await _transfers.PlanFolderUploadAsync(sourcePath, token);
            token.ThrowIfCancellationRequested();
            if (result is null)
            {
                ShowFolderUploadMessage("FolderUploadPreparationCancelledMessage", InfoBarSeverity.Informational);
                return;
            }
            await ConfirmAndStartFolderUploadAsync(targetPath, result, token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            if (!_disposed) ShowFolderUploadMessage("FolderUploadPreparationCancelledMessage", InfoBarSeverity.Informational);
        }
        catch (ObjectDisposedException)
        {
        }
        catch
        {
            if (!_disposed) ShowFolderUploadMessage("FolderUploadSourceUnavailableMessage", InfoBarSeverity.Error);
        }
        finally
        {
            _isChoosingUpload = false;
            _folderUploadPreparation = null;
            _folderUploadDialog = null;
            if (!_disposed)
            {
                if (_folderUploadBatchId is null) FileUploadDropStatus.ActionButton = null;
                UpdateState();
            }
        }
    }

    private async Task UploadFolderFromPathAsync(string targetPath, string sourcePath)
    {
        if (_folderUploadBatchId is not null)
        {
            ShowFolderUploadMessage("FolderUploadBusyMessage", InfoBarSeverity.Warning);
            return;
        }
        await PrepareFolderUploadAsync(targetPath, sourcePath);
    }

    private async Task ConfirmAndStartFolderUploadAsync(
        string targetPath,
        FolderUploadPlanResult result,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (result.Status != FolderUploadPlanStatus.Valid || result.Plan is null)
        {
            ShowFolderUploadPlanError(result.Status);
            return;
        }
        if (_disposed || IsReadOnlyLocation() ||
            !string.Equals(targetPath, _viewModel.CurrentPath, StringComparison.Ordinal))
        {
            ShowFolderUploadMessage("FolderUploadTargetChangedMessage", InfoBarSeverity.Warning);
            return;
        }

        var localization = LocalizationService.Current;
        var dialog = new ContentDialog
        {
            XamlRoot = XamlRoot,
            RequestedTheme = ActualTheme,
            Title = localization.Get("FolderUploadConfirmTitle"),
            PrimaryButtonText = localization.Get("FolderUploadConfirmAction"),
            CloseButtonText = localization.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Close,
            Content = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    new TextBlock
                    {
                        Text = localization.Format(
                            "FolderUploadConfirmMessage",
                            result.Plan.RootName,
                            result.Plan.Files.Count,
                            result.Plan.Directories.Count),
                        TextWrapping = TextWrapping.WrapWholeWords,
                    },
                    new TextBlock
                    {
                        Text = localization.Get("FolderUploadPartialNotice"),
                        TextWrapping = TextWrapping.WrapWholeWords,
                    },
                },
            },
        };
        FileUploadDropStatus.IsOpen = false;
        _folderUploadDialog = dialog;
        var confirmation = await dialog.ShowAsync();
        _folderUploadDialog = null;
        cancellationToken.ThrowIfCancellationRequested();
        if (confirmation != ContentDialogResult.Primary)
        {
            return;
        }
        if (_disposed || IsReadOnlyLocation() ||
            !string.Equals(targetPath, _viewModel.CurrentPath, StringComparison.Ordinal))
        {
            ShowFolderUploadMessage("FolderUploadTargetChangedMessage", InfoBarSeverity.Warning);
            return;
        }

        ShowFolderUploadPreparing(_folderUploadPreparation!);
        var start = await _transfers.StartFolderUploadAsync(
            _profileId.ToString(),
            targetPath,
            result.Plan,
            cancellationToken,
            targetIsCurrent: () => !_disposed && !_viewModel.IsLoading && !IsReadOnlyLocation() &&
                string.Equals(targetPath, _viewModel.CurrentPath, StringComparison.Ordinal));
        if (_disposed) return;
        switch (start.Status)
        {
            case FolderUploadBatchStartStatus.Started:
                _folderUploadBatchId = start.BatchId;
                ShowFolderUploadStarted(result.Plan);
                break;
            case FolderUploadBatchStartStatus.Unsupported:
                ShowFolderUploadMessage("FolderUploadUnsupportedMessage", InfoBarSeverity.Warning);
                break;
            case FolderUploadBatchStartStatus.Busy:
                ShowFolderUploadMessage("FolderUploadBusyMessage", InfoBarSeverity.Warning);
                break;
            case FolderUploadBatchStartStatus.NeedsReview:
                ShowFolderUploadMessage("FolderUploadNeedsReviewMessage", InfoBarSeverity.Warning);
                UploadNeedsReview.IsOpen = true;
                break;
            default:
                ShowFolderUploadMessage("FolderUploadSourceChangedMessage", InfoBarSeverity.Warning);
                break;
        }
    }

    private void ShowFolderUploadPreparing(CancellationTokenSource cancellation)
    {
        var cancel = new Button { Content = LocalizationService.Current.Get("ActionCancel"), MinHeight = 44 };
        AutomationProperties.SetName(cancel, LocalizationService.Current.Get("FolderUploadCancelAutomationName"));
        cancel.Click += (_, _) =>
        {
            cancel.IsEnabled = false;
            if (ReferenceEquals(_folderUploadPreparation, cancellation)) CancelFolderUploadPreparation();
        };
        FileUploadDropStatus.ActionButton = cancel;
        FileUploadDropStatus.Severity = InfoBarSeverity.Informational;
        FileUploadDropStatus.Message = LocalizationService.Current.Get("FolderUploadPreparingMessage");
        FileUploadDropStatus.IsOpen = true;
    }

    private void CancelFolderUploadPreparation()
    {
        _folderUploadPreparation?.Cancel();
        _folderUploadDialog?.Hide();
    }

    private void ShowFolderUploadStarted(FolderUploadPlan plan)
    {
        var localization = LocalizationService.Current;
        var cancel = new Button
        {
            Content = localization.Get("ActionCancel"),
            MinHeight = 44,
        };
        AutomationProperties.SetName(cancel, localization.Get("FolderUploadCancelAutomationName"));
        cancel.Click += (_, _) =>
        {
            if (_folderUploadBatchId is not { } batchId)
            {
                return;
            }
            cancel.IsEnabled = false;
            _transfers.CancelFolderUpload(batchId);
            ShowFolderUploadMessage("FolderUploadCancellingMessage", InfoBarSeverity.Informational);
        };
        FileUploadDropStatus.ActionButton = cancel;
        FileUploadDropStatus.Severity = InfoBarSeverity.Informational;
        FileUploadDropStatus.Message = localization.Format(
            "FolderUploadStartedMessage",
            plan.Files.Count,
            plan.Directories.Count);
        FileUploadDropStatus.IsOpen = true;
    }

    private void Transfers_FolderUploadBatchFinished(FolderUploadBatchFinished finished)
    {
        if (!string.Equals(finished.ProfileId, _profileId.ToString(), StringComparison.Ordinal))
        {
            return;
        }
        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_disposed)
            {
                return;
            }
            if (_folderUploadBatchId == finished.BatchId)
            {
                _folderUploadBatchId = null;
                FileUploadDropStatus.ActionButton = null;
                UpdateState();
            }
            if (!string.Equals(
                    _viewModel.CurrentPath,
                    finished.FolderPath,
                    StringComparison.Ordinal))
            {
                return;
            }

            ShowFolderUploadSummary(finished);
            UploadNeedsReview.IsOpen = finished.Summary.NeedsReviewCount > 0;
            if (finished.Summary.ConfirmedCount > 0)
            {
                await RunAsync(_viewModel.RefreshAsync);
            }
        });
    }

    private void ShowFolderUploadSummary(FolderUploadBatchFinished finished)
    {
        var summary = finished.Summary;
        FileUploadDropStatus.Severity =
            summary.NeedsReviewCount > 0 || summary.FailedCount > 0 ||
                summary.CancelledCount > 0 || summary.NotStartedCount > 0
                ? InfoBarSeverity.Warning
                : InfoBarSeverity.Success;
        FileUploadDropStatus.Message = LocalizationService.Current.Format(
            "FolderUploadSummaryMessage",
            finished.DirectoryCount,
            finished.FileCount,
            summary.ConfirmedCount,
            summary.NeedsReviewCount,
            summary.FailedCount,
            summary.CancelledCount,
            summary.NotStartedCount);
        FileUploadDropStatus.IsOpen = true;
    }

    private void ShowFolderUploadPlanError(FolderUploadPlanStatus status) =>
        ShowFolderUploadMessage(status switch
        {
            FolderUploadPlanStatus.ReparsePoint => "FolderUploadReparsePointMessage",
            FolderUploadPlanStatus.InvalidName => "FolderUploadInvalidNameMessage",
            FolderUploadPlanStatus.DuplicateTarget => "FolderUploadDuplicateMessage",
            _ => "FolderUploadSourceUnavailableMessage",
        }, InfoBarSeverity.Error);

    private void ShowFolderUploadMessage(string resourceKey, InfoBarSeverity severity)
    {
        FileUploadDropStatus.ActionButton = null;
        FileUploadDropStatus.Severity = severity;
        FileUploadDropStatus.Message = LocalizationService.Current.Get(resourceKey);
        FileUploadDropStatus.IsOpen = true;
    }
}
