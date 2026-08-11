using LanStash.App.Features.Transfers;
using LanStash.App.Localization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class FilesPage
{
    private Guid? _folderUploadBatchId;

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

        var targetPath = _viewModel.CurrentPath;
        _isChoosingUpload = true;
        UpdateState();
        try
        {
            var result = await _transfers.PickFolderUploadPlanAsync();
            if (result is null)
            {
                return;
            }
            await ConfirmAndStartFolderUploadAsync(targetPath, result);
        }
        catch (ObjectDisposedException)
        {
        }
        catch
        {
            ShowFolderUploadMessage("FolderUploadSourceUnavailableMessage", InfoBarSeverity.Error);
        }
        finally
        {
            _isChoosingUpload = false;
            UpdateState();
        }
    }

    private async Task UploadFolderFromPathAsync(string targetPath, string sourcePath)
    {
        if (_folderUploadBatchId is not null)
        {
            ShowFolderUploadMessage("FolderUploadBusyMessage", InfoBarSeverity.Warning);
            return;
        }
        var result = await _transfers.PlanFolderUploadAsync(sourcePath);
        await ConfirmAndStartFolderUploadAsync(targetPath, result);
    }

    private async Task ConfirmAndStartFolderUploadAsync(
        string targetPath,
        FolderUploadPlanResult result)
    {
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
            Title = localization.Get("FolderUploadConfirmTitle"),
            PrimaryButtonText = localization.Get("FolderUploadConfirmAction"),
            CloseButtonText = localization.Get("ActionCancel"),
            DefaultButton = ContentDialogButton.Primary,
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
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return;
        }
        if (_disposed || IsReadOnlyLocation() ||
            !string.Equals(targetPath, _viewModel.CurrentPath, StringComparison.Ordinal))
        {
            ShowFolderUploadMessage("FolderUploadTargetChangedMessage", InfoBarSeverity.Warning);
            return;
        }

        var start = _transfers.StartFolderUpload(
            _profileId.ToString(),
            targetPath,
            result.Plan);
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
            FolderUploadPlanStatus.TooManyFiles => "FolderUploadTooManyFilesMessage",
            FolderUploadPlanStatus.TooManyDirectories => "FolderUploadTooManyDirectoriesMessage",
            FolderUploadPlanStatus.TooDeep => "FolderUploadTooDeepMessage",
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
