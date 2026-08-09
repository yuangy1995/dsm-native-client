using LanStash.App.Localization;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

public enum DownloadTaskCreateNoticeKind
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
    private CancellationTokenSource? _createCancellation;
    private long _createGeneration;
    private bool _isCreatingTask;
    private DownloadTaskCreateNoticeKind _createNoticeKind;
    private string _createNoticeTitle = string.Empty;
    private string _createNoticeMessage = string.Empty;

    public bool IsCreatingTask
    {
        get => _isCreatingTask;
        private set
        {
            if (SetProperty(ref _isCreatingTask, value))
            {
                RaiseCreateProperties();
            }
        }
    }

    public bool CanCreateTask =>
        !IsCreatingTask &&
        _repository is { Availability.Status: DownloadStationAvailabilityStatus.Available };

    public DownloadTaskCreateNoticeKind CreateNoticeKind
    {
        get => _createNoticeKind;
        private set
        {
            if (SetProperty(ref _createNoticeKind, value))
            {
                RaiseCreateProperties();
            }
        }
    }

    public bool HasCreateNotice => CreateNoticeKind != DownloadTaskCreateNoticeKind.None;
    public bool IsCreateNoticeSuccess => CreateNoticeKind == DownloadTaskCreateNoticeKind.Success;
    public bool IsCreateNoticeWarning =>
        CreateNoticeKind is DownloadTaskCreateNoticeKind.NeedsReview or
            DownloadTaskCreateNoticeKind.Conflict or
            DownloadTaskCreateNoticeKind.Permission or
            DownloadTaskCreateNoticeKind.Unsupported;

    public string CreateNoticeTitle
    {
        get => _createNoticeTitle;
        private set => SetProperty(ref _createNoticeTitle, value);
    }

    public string CreateNoticeMessage
    {
        get => _createNoticeMessage;
        private set => SetProperty(ref _createNoticeMessage, value);
    }

    public string CreateDestinationText => CurrentProfile is { } profile &&
        DestinationForCreate(profile) is { } destination
            ? destination
            : LocalizationService.Current.Get("DownloadStationCreateDefaultDestination");

    public async Task CreateTaskAsync(string? uri)
    {
        ThrowIfDisposed();
        var trimmedUri = uri?.Trim() ?? string.Empty;
        if (trimmedUri.Length == 0 ||
            _repository is not { Availability.Status: DownloadStationAvailabilityStatus.Available } repository ||
            CurrentProfile is not { } profile)
        {
            return;
        }

        var request = BeginCreate();
        IsCreatingTask = true;
        SetCreateNotice(
            DownloadTaskCreateNoticeKind.InProgress,
            "DownloadStationCreateInProgressTitle",
            "DownloadStationCreateInProgressMessage");
        try
        {
            var outcome = await repository.CreateTaskAsync(
                new DownloadTaskCreateRequest(
                    repository.ProfileId,
                    trimmedUri,
                    DestinationForCreate(profile)),
                request.Cancellation.Token);
            if (!IsCurrentCreate(request.Generation, repository))
            {
                return;
            }

            ApplyCreateOutcome(profile, outcome);
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
            if (IsCurrentCreate(request.Generation, repository))
            {
                SetCreateNotice(
                    DownloadTaskCreateNoticeKind.NeedsReview,
                    "DownloadStationCreateReviewTitle",
                    "DownloadStationCreateReviewMessage");
            }
        }
        finally
        {
            if (IsCurrentCreate(request.Generation, repository))
            {
                IsCreatingTask = false;
            }
        }
    }

    public async Task CreateTaskFromFileAsync(string? filePath)
    {
        ThrowIfDisposed();
        if (string.IsNullOrWhiteSpace(filePath) ||
            _repository is not { Availability.Status: DownloadStationAvailabilityStatus.Available } repository ||
            CurrentProfile is not { } profile)
        {
            return;
        }

        var request = BeginCreate();
        IsCreatingTask = true;
        SetCreateNotice(
            DownloadTaskCreateNoticeKind.InProgress,
            "DownloadStationCreateInProgressTitle",
            "DownloadStationCreateInProgressMessage");
        try
        {
            var fileInfo = new FileInfo(filePath);
            await using var stream = fileInfo.OpenRead();
            var outcome = await repository.CreateTaskFromFileAsync(
                new DownloadTaskFileCreateRequest(
                    repository.ProfileId,
                    stream,
                    fileInfo.Length,
                    fileInfo.Name,
                    DestinationForCreate(profile)),
                request.Cancellation.Token);
            if (!IsCurrentCreate(request.Generation, repository))
            {
                return;
            }

            ApplyCreateOutcome(profile, outcome);
            if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                await LoadFirstPageAsync(profile, preserveContentOnFailure: true);
            }
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch (ArgumentException)
        {
            if (IsCurrentCreate(request.Generation, repository))
            {
                SetCreateNotice(
                    DownloadTaskCreateNoticeKind.Unsupported,
                    "DownloadStationCreateUnsupportedTitle",
                    "DownloadStationCreateUnsupportedMessage");
            }
        }
        catch (IOException)
        {
            if (IsCurrentCreate(request.Generation, repository))
            {
                SetCreateNotice(
                    DownloadTaskCreateNoticeKind.Failure,
                    "DownloadStationCreateFailureTitle",
                    "DownloadStationCreateFailureMessage");
            }
        }
        catch (UnauthorizedAccessException)
        {
            if (IsCurrentCreate(request.Generation, repository))
            {
                SetCreateNotice(
                    DownloadTaskCreateNoticeKind.Failure,
                    "DownloadStationCreateFailureTitle",
                    "DownloadStationCreateFailureMessage");
            }
        }
        catch
        {
            if (IsCurrentCreate(request.Generation, repository))
            {
                SetCreateNotice(
                    DownloadTaskCreateNoticeKind.NeedsReview,
                    "DownloadStationCreateReviewTitle",
                    "DownloadStationCreateReviewMessage");
            }
        }
        finally
        {
            if (IsCurrentCreate(request.Generation, repository))
            {
                IsCreatingTask = false;
            }
        }
    }

    private (long Generation, CancellationTokenSource Cancellation) BeginCreate()
    {
        CancelCreate();
        var cancellation = _createCancellation = new CancellationTokenSource();
        return (_createGeneration, cancellation);
    }

    private void CancelCreate()
    {
        _createGeneration++;
        _createCancellation?.Cancel();
        _createCancellation?.Dispose();
        _createCancellation = null;
        IsCreatingTask = false;
    }

    private bool IsCurrentCreate(long generation, IDownloadStationRepository repository) =>
        !_disposed && generation == _createGeneration &&
        ReferenceEquals(repository, _repository) && ActiveProfileId == repository.ProfileId;

    private string? DestinationForCreate(ProfileState profile)
    {
        var destination = profile.DefaultDestination.Status == DownloadStationSectionStatus.Available
            ? profile.DefaultDestination.Value?.Trim()
            : null;
        return string.IsNullOrWhiteSpace(destination) ? null : destination;
    }

    private void ApplyCreateOutcome(ProfileState profile, DownloadTaskCreateOutcome outcome)
    {
        if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess &&
            outcome.Task is { } task)
        {
            UpsertCreatedTask(profile, task);
        }
        var (kind, titleKey, messageKey) = CreateNoticeFor(outcome.Result, outcome.Task);
        SetCreateNotice(kind, titleKey, messageKey);
    }

    private void UpsertCreatedTask(ProfileState profile, DownloadTask task)
    {
        var existing = profile.AllTasks
            .Where(item => !string.Equals(item.Id, task.Id, StringComparison.Ordinal))
            .ToArray();
        profile.AllTasks = new[] { new DownloadTaskItem(task) }
            .Concat(existing)
            .ToArray();
        ApplyFilter(profile);
    }

    private static (DownloadTaskCreateNoticeKind Kind, string TitleKey, string MessageKey)
        CreateNoticeFor(MutationResult result, DownloadTask? task)
    {
        return result.Status switch
        {
            MutationResultStatus.ConfirmedSuccess when task is not null => (
                DownloadTaskCreateNoticeKind.Success,
                "DownloadStationCreateSuccessTitle",
                "DownloadStationCreateSuccessMessage"),
            MutationResultStatus.ConfirmedSuccess => (
                DownloadTaskCreateNoticeKind.NeedsReview,
                "DownloadStationCreateReviewTitle",
                "DownloadStationCreateReviewMessage"),
            MutationResultStatus.CancelledBeforeSubmission => (
                DownloadTaskCreateNoticeKind.Cancelled,
                "DownloadStationCreateCancelledTitle",
                "DownloadStationCreateCancelledMessage"),
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission or
                MutationResultStatus.PartialSuccess => (
                    DownloadTaskCreateNoticeKind.NeedsReview,
                    "DownloadStationCreateReviewTitle",
                    "DownloadStationCreateReviewMessage"),
            MutationResultStatus.Unsupported => (
                DownloadTaskCreateNoticeKind.Unsupported,
                "DownloadStationCreateUnsupportedTitle",
                "DownloadStationCreateUnsupportedMessage"),
            _ when result.ErrorCategory == MutationErrorCategory.Permission => (
                DownloadTaskCreateNoticeKind.Permission,
                "DownloadStationCreatePermissionTitle",
                "DownloadStationCreatePermissionMessage"),
            _ when result.ErrorCategory == MutationErrorCategory.Conflict => (
                DownloadTaskCreateNoticeKind.Conflict,
                "DownloadStationCreateConflictTitle",
                "DownloadStationCreateConflictMessage"),
            _ => (
                DownloadTaskCreateNoticeKind.Failure,
                "DownloadStationCreateFailureTitle",
                "DownloadStationCreateFailureMessage"),
        };
    }

    private void SetCreateNotice(
        DownloadTaskCreateNoticeKind kind,
        string titleKey,
        string messageKey)
    {
        CreateNoticeKind = kind;
        CreateNoticeTitle = LocalizationService.Current.Get(titleKey);
        CreateNoticeMessage = LocalizationService.Current.Get(messageKey);
    }

    private void ClearCreateNotice()
    {
        CreateNoticeKind = DownloadTaskCreateNoticeKind.None;
        CreateNoticeTitle = string.Empty;
        CreateNoticeMessage = string.Empty;
    }

    private void RaiseCreateProperties()
    {
        RaisePropertyChanged(nameof(CanCreateTask));
        RaisePropertyChanged(nameof(HasCreateNotice));
        RaisePropertyChanged(nameof(IsCreateNoticeSuccess));
        RaisePropertyChanged(nameof(IsCreateNoticeWarning));
    }
}
