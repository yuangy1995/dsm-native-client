using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

public enum DownloadTaskDeleteNoticeKind
{
    None,
    InProgress,
    Success,
    NeedsReview,
    Cancelled,
    Conflict,
    Permission,
    Unsupported,
    Failure,
}

public sealed partial class DownloadStationViewModel
{
    private CancellationTokenSource? _deleteCancellation;
    private long _deleteGeneration;
    private bool _isDeletingTask;
    private DownloadTaskDeleteNoticeKind _deleteNoticeKind;
    private string _deleteNoticeTitle = string.Empty;
    private string _deleteNoticeMessage = string.Empty;

    public bool IsDeletingTask
    {
        get => _isDeletingTask;
        private set
        {
            if (SetProperty(ref _isDeletingTask, value))
            {
                RaiseDeleteProperties();
            }
        }
    }

    public bool CanDeleteSelectedTask =>
        SelectedTask is not null &&
        !IsDeletingTask &&
        !IsControllingTask &&
        _repository is { Availability.Status: DownloadStationAvailabilityStatus.Available };

    public DownloadTaskDeleteNoticeKind DeleteNoticeKind
    {
        get => _deleteNoticeKind;
        private set
        {
            if (SetProperty(ref _deleteNoticeKind, value))
            {
                RaiseDeleteProperties();
            }
        }
    }

    public bool HasDeleteNotice => DeleteNoticeKind != DownloadTaskDeleteNoticeKind.None;
    public bool IsDeleteNoticeSuccess => DeleteNoticeKind == DownloadTaskDeleteNoticeKind.Success;
    public bool IsDeleteNoticeWarning =>
        DeleteNoticeKind is DownloadTaskDeleteNoticeKind.NeedsReview or
            DownloadTaskDeleteNoticeKind.Conflict or
            DownloadTaskDeleteNoticeKind.Permission or
            DownloadTaskDeleteNoticeKind.Unsupported;

    public string DeleteNoticeTitle
    {
        get => _deleteNoticeTitle;
        private set => SetProperty(ref _deleteNoticeTitle, value);
    }

    public string DeleteNoticeMessage
    {
        get => _deleteNoticeMessage;
        private set => SetProperty(ref _deleteNoticeMessage, value);
    }

    public async Task DeleteSelectedTaskAsync()
    {
        ThrowIfDisposed();
        if (IsDeletingTask ||
            _repository is not { Availability.Status: DownloadStationAvailabilityStatus.Available } repository ||
            CurrentProfile is not { } profile ||
            SelectedTask is not { } selected)
        {
            return;
        }

        var request = BeginDelete();
        IsDeletingTask = true;
        SetDeleteNotice(
            DownloadTaskDeleteNoticeKind.InProgress,
            "DownloadStationDeleteInProgressTitle",
            "DownloadStationDeleteInProgressMessage");
        try
        {
            var outcome = await repository.DeleteTaskAsync(
                new DownloadTaskDeleteRequest(
                    repository.ProfileId,
                    selected.Task),
                request.Cancellation.Token);
            if (!IsCurrentDelete(request.Generation, repository))
            {
                return;
            }

            ApplyDeleteOutcome(profile, outcome);
            if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                await LoadFirstPageAsync(profile, preserveContentOnFailure: true);
            }
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrentDelete(request.Generation, repository))
            {
                SetDeleteNotice(
                    DownloadTaskDeleteNoticeKind.NeedsReview,
                    "DownloadStationDeleteReviewTitle",
                    "DownloadStationDeleteReviewMessage");
            }
        }
        finally
        {
            if (IsCurrentDelete(request.Generation, repository))
            {
                IsDeletingTask = false;
            }
        }
    }

    private (long Generation, CancellationTokenSource Cancellation) BeginDelete()
    {
        CancelDelete();
        var cancellation = _deleteCancellation = new CancellationTokenSource();
        return (_deleteGeneration, cancellation);
    }

    private void CancelDelete()
    {
        _deleteGeneration++;
        _deleteCancellation?.Cancel();
        _deleteCancellation?.Dispose();
        _deleteCancellation = null;
        IsDeletingTask = false;
    }

    private bool IsCurrentDelete(long generation, IDownloadStationRepository repository) =>
        !_disposed && generation == _deleteGeneration &&
        ReferenceEquals(repository, _repository) && ActiveProfileId == repository.ProfileId;

    private void ApplyDeleteOutcome(ProfileState profile, DownloadTaskDeleteOutcome outcome)
    {
        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess)
        {
            RemoveDeletedTask(profile, outcome.TaskId);
        }
        var (kind, titleKey, messageKey) = DeleteNoticeFor(outcome.Result);
        SetDeleteNotice(kind, titleKey, messageKey);
    }

    private void RemoveDeletedTask(ProfileState profile, string taskId)
    {
        profile.AllTasks = profile.AllTasks
            .Where(item => !string.Equals(item.Id, taskId, StringComparison.Ordinal))
            .ToArray();
        if (string.Equals(profile.SelectedTaskId, taskId, StringComparison.Ordinal))
        {
            profile.SelectedTaskId = null;
        }
        ApplyFilter(profile);
    }

    private static (DownloadTaskDeleteNoticeKind Kind, string TitleKey, string MessageKey)
        DeleteNoticeFor(MutationResult result)
    {
        return result.Status switch
        {
            MutationResultStatus.ConfirmedSuccess => (
                DownloadTaskDeleteNoticeKind.Success,
                "DownloadStationDeleteSuccessTitle",
                "DownloadStationDeleteSuccessMessage"),
            MutationResultStatus.CancelledBeforeSubmission => (
                DownloadTaskDeleteNoticeKind.Cancelled,
                "DownloadStationDeleteCancelledTitle",
                "DownloadStationDeleteCancelledMessage"),
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission or
                MutationResultStatus.PartialSuccess => (
                    DownloadTaskDeleteNoticeKind.NeedsReview,
                    "DownloadStationDeleteReviewTitle",
                    "DownloadStationDeleteReviewMessage"),
            MutationResultStatus.Unsupported => (
                DownloadTaskDeleteNoticeKind.Unsupported,
                "DownloadStationDeleteUnsupportedTitle",
                "DownloadStationDeleteUnsupportedMessage"),
            _ when result.ErrorCategory == MutationErrorCategory.Permission => (
                DownloadTaskDeleteNoticeKind.Permission,
                "DownloadStationDeletePermissionTitle",
                "DownloadStationDeletePermissionMessage"),
            _ when result.ErrorCategory == MutationErrorCategory.Conflict => (
                DownloadTaskDeleteNoticeKind.Conflict,
                "DownloadStationDeleteConflictTitle",
                "DownloadStationDeleteConflictMessage"),
            _ => (
                DownloadTaskDeleteNoticeKind.Failure,
                "DownloadStationDeleteFailureTitle",
                "DownloadStationDeleteFailureMessage"),
        };
    }

    private void SetDeleteNotice(
        DownloadTaskDeleteNoticeKind kind,
        string titleKey,
        string messageKey)
    {
        DeleteNoticeKind = kind;
        DeleteNoticeTitle = LocalizationService.Current.Get(titleKey);
        DeleteNoticeMessage = LocalizationService.Current.Get(messageKey);
    }

    private void ClearDeleteNotice()
    {
        DeleteNoticeKind = DownloadTaskDeleteNoticeKind.None;
        DeleteNoticeTitle = string.Empty;
        DeleteNoticeMessage = string.Empty;
    }

    private void RaiseDeleteProperties()
    {
        RaisePropertyChanged(nameof(CanPauseSelectedTask));
        RaisePropertyChanged(nameof(CanResumeSelectedTask));
        RaisePropertyChanged(nameof(CanDeleteSelectedTask));
        RaisePropertyChanged(nameof(HasDeleteNotice));
        RaisePropertyChanged(nameof(IsDeleteNoticeSuccess));
        RaisePropertyChanged(nameof(IsDeleteNoticeWarning));
    }
}
