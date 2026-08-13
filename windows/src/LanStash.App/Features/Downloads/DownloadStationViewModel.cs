using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.Features.Transfers;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

public sealed partial class DownloadStationViewModel : ObservableObject, IDisposable
{
    public const int DefaultPageSize = 100;

    private readonly int _pageSize;
    private readonly ForegroundTransferCoordinator? _activityCoordinator;
    private readonly Dictionary<Guid, ProfileState> _profiles = [];
    private IDownloadStationRepository? _repository;
    private CancellationTokenSource? _requestCancellation;
    private CancellationTokenSource? _controlCancellation;
    private long _generation;
    private long _controlGeneration;
    private Guid? _activeProfileId;
    private DownloadStationContentState _contentState = DownloadStationContentState.Loading;
    private DownloadTaskFilter _filter;
    private string _searchText = string.Empty;
    private DownloadTaskItem? _selectedTask;
    private bool _isLoading;
    private bool _isLoadingMore;
    private bool _hasRefreshError;
    private bool _hasLoadMoreError;
    private bool _isControllingTask;
    private DownloadTaskControlNoticeKind _controlNoticeKind;
    private string _controlNoticeTitle = string.Empty;
    private string _controlNoticeMessage = string.Empty;
    private DownloadActivitySection _activity = new(
        DownloadStationSectionStatus.Unavailable,
        null);
    private DownloadStationSettingsSection _settings = new(
        DownloadStationSectionStatus.Unavailable,
        null);
    private DownloadRssSection _rss = new(
        DownloadStationSectionStatus.Unavailable,
        null);
    private bool _disposed;

    internal DownloadStationViewModel(
        int pageSize = DefaultPageSize,
        ForegroundTransferCoordinator? activityCoordinator = null)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(pageSize, 1);
        _pageSize = pageSize;
        _activityCoordinator = activityCoordinator;
    }

    public ObservableCollection<DownloadTaskItem> Tasks { get; } = [];

    public Guid? ActiveProfileId
    {
        get => _activeProfileId;
        private set => SetProperty(ref _activeProfileId, value);
    }

    public DownloadStationContentState ContentState
    {
        get => _contentState;
        private set
        {
            if (SetProperty(ref _contentState, value))
            {
                RaiseStateProperties();
            }
        }
    }

    public DownloadTaskFilter Filter
    {
        get => _filter;
        private set => SetProperty(ref _filter, value);
    }

    public string SearchText
    {
        get => _searchText;
        private set => SetProperty(ref _searchText, value);
    }

    public DownloadTaskItem? SelectedTask
    {
        get => _selectedTask;
        private set
        {
            if (SetProperty(ref _selectedTask, value))
            {
                RaisePropertyChanged(nameof(HasSelection));
                RaisePropertyChanged(nameof(CanDeleteSelectedTask));
            }
        }
    }

    public bool IsLoading
    {
        get => _isLoading;
        private set
        {
            if (SetProperty(ref _isLoading, value))
            {
                RaisePropertyChanged(nameof(CanLoadMore));
            }
        }
    }

    public bool IsLoadingMore
    {
        get => _isLoadingMore;
        private set
        {
            if (SetProperty(ref _isLoadingMore, value))
            {
                RaisePropertyChanged(nameof(CanLoadMore));
            }
        }
    }

    public bool HasRefreshError
    {
        get => _hasRefreshError;
        private set => SetProperty(ref _hasRefreshError, value);
    }

    public bool HasLoadMoreError
    {
        get => _hasLoadMoreError;
        private set => SetProperty(ref _hasLoadMoreError, value);
    }

    public bool HasContent => ContentState == DownloadStationContentState.Content;
    public bool IsEmpty => ContentState == DownloadStationContentState.Empty;
    public bool IsFilteredEmpty => ContentState == DownloadStationContentState.FilteredEmpty;
    public bool HasError => ContentState == DownloadStationContentState.Error;
    public bool IsUnavailable => ContentState == DownloadStationContentState.Unavailable;
    public bool HasSelection => SelectedTask is not null;
    public bool IsControllingTask
    {
        get => _isControllingTask;
        private set
        {
            if (SetProperty(ref _isControllingTask, value))
            {
                RaiseControlProperties();
                RaiseDeleteProperties();
            }
        }
    }
    public bool CanPauseSelectedTask => SelectedTask is { State: DownloadTaskState.Waiting or
        DownloadTaskState.Downloading or DownloadTaskState.Checking } &&
        !IsControllingTask &&
        !IsDeletingTask &&
        _repository is { Availability.Status: DownloadStationAvailabilityStatus.Available };
    public bool CanResumeSelectedTask => SelectedTask is { State: DownloadTaskState.Paused } &&
        !IsControllingTask &&
        !IsDeletingTask &&
        _repository is { Availability.Status: DownloadStationAvailabilityStatus.Available };
    public DownloadTaskControlNoticeKind ControlNoticeKind
    {
        get => _controlNoticeKind;
        private set
        {
            if (SetProperty(ref _controlNoticeKind, value))
            {
                RaiseControlProperties();
            }
        }
    }
    public bool HasControlNotice => ControlNoticeKind != DownloadTaskControlNoticeKind.None;
    public bool IsControlNoticeSuccess =>
        ControlNoticeKind == DownloadTaskControlNoticeKind.Success;
    public bool IsControlNoticeWarning =>
        ControlNoticeKind is DownloadTaskControlNoticeKind.NeedsReview or
            DownloadTaskControlNoticeKind.Conflict or
            DownloadTaskControlNoticeKind.Permission or
            DownloadTaskControlNoticeKind.Unsupported;
    public string ControlNoticeTitle
    {
        get => _controlNoticeTitle;
        private set => SetProperty(ref _controlNoticeTitle, value);
    }
    public string ControlNoticeMessage
    {
        get => _controlNoticeMessage;
        private set => SetProperty(ref _controlNoticeMessage, value);
    }
    public bool HasActivity => _activity.Status == DownloadStationSectionStatus.Available &&
        _activity.Value is not null;
    public bool HasActivityError => _activity.Status == DownloadStationSectionStatus.Failed;
    public string ActivityDownloadSpeedText =>
        DownloadTaskItem.FormatSpeed(_activity.Value?.DownloadSpeed);
    public string ActivityUploadSpeedText =>
        DownloadTaskItem.FormatSpeed(_activity.Value?.UploadSpeed);
    public string ActivityEmuleDownloadSpeedText =>
        DownloadTaskItem.FormatSpeed(_activity.Value?.EmuleDownloadSpeed);
    public string ActivityEmuleUploadSpeedText =>
        DownloadTaskItem.FormatSpeed(_activity.Value?.EmuleUploadSpeed);
    public bool HasAdvancedSummary =>
        HasSettings || HasSettingsError || HasRss || HasRssError;
    public bool HasSettings => _settings.Status == DownloadStationSectionStatus.Available &&
        _settings.Value is not null;
    public bool HasSettingsError => _settings.Status == DownloadStationSectionStatus.Failed;
    public bool HasRss => _rss.Status == DownloadStationSectionStatus.Available &&
        _rss.Value is not null;
    public bool HasRssError => _rss.Status == DownloadStationSectionStatus.Failed;
    public string SettingsDefaultDestinationText =>
        TextOrUnavailable(_settings.Value?.DefaultDestination);
    public string SettingsAutoExtractText =>
        FormatToggle(_settings.Value?.IsAutoExtractEnabled);
    public string SettingsEmuleText =>
        FormatEmuleSettings(_settings.Value);
    public string SettingsScheduleText =>
        FormatScheduleSettings(_settings.Value);
    public string SettingsSpeedLimitText =>
        FormatSpeedLimits(_settings.Value);
    public string RssSitesText => _rss.Value is { } rss
        ? LocalizationService.Current.Format(
            "DownloadStationRssSiteCount",
            rss.SiteCount.ToString("N0", System.Globalization.CultureInfo.CurrentCulture))
        : LocalizationService.Current.Get("DownloadStationValueUnavailable");
    public string RssFeedsText => _rss.Value is { } rss
        ? LocalizationService.Current.Format(
            "DownloadStationRssFeedCount",
            rss.FeedCount.ToString("N0", System.Globalization.CultureInfo.CurrentCulture))
        : LocalizationService.Current.Get("DownloadStationValueUnavailable");
    public bool CanLoadMore => !IsLoading && !IsLoadingMore &&
        CurrentProfile is { HasMore: true, NextOffset: not null };

    private ProfileState? CurrentProfile => ActiveProfileId is Guid profileId &&
        _profiles.TryGetValue(profileId, out var state) ? state : null;

    public async Task ActivateAsync(IDownloadStationRepository repository)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        SaveCurrentProfileState();
        CancelRequest();
        CancelControl();
        CancelBtSearch(resetSession: true);
        _repository = repository;
        ActiveProfileId = repository.ProfileId;
        RaiseBtSearchAvailabilityProperties();

        if (repository.Availability.Status != DownloadStationAvailabilityStatus.Available ||
            !repository.Availability.SupportedFeatures.Contains(DownloadStationReadFeature.Tasks))
        {
            Tasks.Clear();
            SelectedTask = null;
            SetActivity(new(DownloadStationSectionStatus.Unavailable, null));
            SetSettings(new(DownloadStationSectionStatus.Unavailable, null));
            SetRss(new(DownloadStationSectionStatus.Unavailable, null));
            ResetErrors();
            ClearControlNotice();
            ClearCreateNotice();
            ContentState = DownloadStationContentState.Unavailable;
            return;
        }

        if (_profiles.TryGetValue(repository.ProfileId, out var cached) && cached.Loaded)
        {
            RestoreProfile(cached);
            return;
        }

        var profile = cached ?? new ProfileState();
        _profiles[repository.ProfileId] = profile;
        RestoreFilter(profile);
        SetActivity(profile.Activity);
        await LoadFirstPageAsync(profile, preserveContentOnFailure: false);
    }

    public void Deactivate()
    {
        ThrowIfDisposed();
        SaveCurrentProfileState();
        CancelRequest();
        CancelControl();
        CancelBtSearch(resetSession: true);
        CancelCreate();
        CancelDelete();
        _repository = null;
        ActiveProfileId = null;
        RaiseBtSearchAvailabilityProperties();
        Tasks.Clear();
        SelectedTask = null;
        SetActivity(new(DownloadStationSectionStatus.Unavailable, null));
        SetSettings(new(DownloadStationSectionStatus.Unavailable, null));
        SetRss(new(DownloadStationSectionStatus.Unavailable, null));
        SearchText = string.Empty;
        Filter = DownloadTaskFilter.All;
        ResetErrors();
        ClearControlNotice();
        ClearCreateNotice();
        ClearDeleteNotice();
        ContentState = DownloadStationContentState.Loading;
    }

    public Task RefreshAsync()
    {
        ThrowIfDisposed();
        return _repository is { Availability.Status: DownloadStationAvailabilityStatus.Available } &&
            CurrentProfile is { } profile
                ? LoadFirstPageAsync(profile, preserveContentOnFailure: profile.Loaded)
                : Task.CompletedTask;
    }

    public async Task LoadMoreAsync()
    {
        ThrowIfDisposed();
        if (_repository is not { Availability.Status: DownloadStationAvailabilityStatus.Available }
                repository ||
            CurrentProfile is not { } profile ||
            !CanLoadMore || profile.NextOffset is not int requestedOffset)
        {
            return;
        }

        var request = BeginRequest();
        IsLoadingMore = true;
        HasLoadMoreError = false;
        try
        {
            var page = await repository.ListTasksAsync(
                requestedOffset,
                _pageSize,
                request.Cancellation.Token);
            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }
            ValidatePage(page, requestedOffset);
            MergePage(profile, page);
            SyncActivity(profile);
            ApplyFilter(profile);
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                HasLoadMoreError = true;
                ApplyFilter(profile);
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, repository))
            {
                IsLoadingMore = false;
                RaisePropertyChanged(nameof(CanLoadMore));
            }
        }
    }

    public void SetSearchText(string? value)
    {
        ThrowIfDisposed();
        SearchText = value?.Trim() ?? string.Empty;
        if (CurrentProfile is { } profile)
        {
            profile.SearchText = SearchText;
            ApplyFilter(profile);
        }
    }

    public void SetFilter(DownloadTaskFilter filter)
    {
        ThrowIfDisposed();
        Filter = filter;
        if (CurrentProfile is { } profile)
        {
            profile.Filter = filter;
            ApplyFilter(profile);
        }
    }

    public void ShowAll()
    {
        ThrowIfDisposed();
        SearchText = string.Empty;
        Filter = DownloadTaskFilter.All;
        if (CurrentProfile is { } profile)
        {
            profile.SearchText = string.Empty;
            profile.Filter = DownloadTaskFilter.All;
            ApplyFilter(profile);
        }
    }

    public void SelectTask(DownloadTaskItem? task)
    {
        ThrowIfDisposed();
        SelectedTask = task is null
            ? null
            : Tasks.FirstOrDefault(item => item.Id == task.Id);
        if (CurrentProfile is { } profile)
        {
            profile.SelectedTaskId = SelectedTask?.Id;
        }
        ClearControlNotice();
        ClearDeleteNotice();
    }

    public async Task ControlSelectedTaskAsync(DownloadTaskControlAction action)
    {
        ThrowIfDisposed();
        if (IsControllingTask ||
            _repository is not { Availability.Status: DownloadStationAvailabilityStatus.Available } repository ||
            CurrentProfile is not { } profile ||
            SelectedTask is not { } selected ||
            !CanControl(action, selected.State))
        {
            return;
        }

        var request = BeginControl();
        IsControllingTask = true;
        SetControlNotice(
            DownloadTaskControlNoticeKind.InProgress,
            action == DownloadTaskControlAction.Pause
                ? "DownloadStationControlPausingTitle"
                : "DownloadStationControlResumingTitle",
            "DownloadStationControlInProgressMessage");
        try
        {
            var outcome = await repository.ControlTaskAsync(
                new DownloadTaskControlRequest(
                    repository.ProfileId,
                    selected.Task,
                    action),
                request.Cancellation.Token);
            if (!IsCurrentControl(request.Generation, repository))
            {
                return;
            }

            ApplyControlOutcome(action, profile, outcome);
            if (outcome.Result.Status == MutationResultStatus.ConfirmedSuccess)
            {
                await LoadFirstPageAsync(profile, preserveContentOnFailure: true);
            }
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        finally
        {
            if (IsCurrentControl(request.Generation, repository))
            {
                IsControllingTask = false;
            }
        }
    }

    private async Task LoadFirstPageAsync(ProfileState profile, bool preserveContentOnFailure)
    {
        var repository = RequireRepository();
        var request = BeginRequest();
        IsLoading = true;
        HasRefreshError = false;
        HasLoadMoreError = false;
        if (!preserveContentOnFailure || !profile.Loaded)
        {
            ContentState = DownloadStationContentState.Loading;
        }
        try
        {
            var snapshot = await repository.LoadSnapshotAsync(
                0,
                _pageSize,
                request.Cancellation.Token);
            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }
            if (snapshot.ProfileId != repository.ProfileId)
            {
                throw new InvalidDataException("Download Station returned another profile.");
            }
            ValidatePage(snapshot.Tasks, 0);
            profile.AllTasks = snapshot.Tasks.Tasks
                .Select(task => new DownloadTaskItem(task))
                .ToArray();
            profile.NextOffset = snapshot.Tasks.NextOffset;
            profile.HasMore = snapshot.Tasks.HasMore;
            profile.SourceTotal = snapshot.Tasks.SourceTotal;
            profile.Activity = snapshot.Activity;
            profile.DefaultDestination = snapshot.DefaultDestination;
            profile.Settings = snapshot.Settings;
            profile.Rss = snapshot.Rss;
            SetActivity(snapshot.Activity);
            SetSettings(snapshot.Settings);
            SetRss(snapshot.Rss);
            SyncActivity(profile);
            RaisePropertyChanged(nameof(CreateDestinationText));
            profile.Loaded = true;
            ApplyFilter(profile);
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                HasRefreshError = true;
                if (!preserveContentOnFailure || !profile.Loaded)
                {
                    Tasks.Clear();
                    SelectedTask = null;
                    ContentState = DownloadStationContentState.Error;
                }
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, repository))
            {
                IsLoading = false;
                RaisePropertyChanged(nameof(CanLoadMore));
            }
        }
    }

    private static void ValidatePage(DownloadTaskPage page, int requestedOffset)
    {
        var expectedNextOffset = checked(page.SourceOffset + page.SourceRecordCount);
        if (page.SourceOffset != requestedOffset || page.SourceRecordCount < 0 ||
            page.SourceTotal < 0 || page.SourceRecordCount != page.Tasks.Count ||
            expectedNextOffset > page.SourceTotal ||
            page.HasMore != (expectedNextOffset < page.SourceTotal) ||
            page.HasMore != (page.NextOffset is not null) ||
            page.NextOffset is int nextOffset && nextOffset != expectedNextOffset)
        {
            throw new InvalidDataException("Download Station returned an invalid page.");
        }
    }

    private static void MergePage(ProfileState profile, DownloadTaskPage page)
    {
        var existingIDs = profile.AllTasks.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        if (page.SourceTotal != profile.SourceTotal ||
            page.Tasks.Any(task => !existingIDs.Add(task.Id)))
        {
            throw new InvalidDataException("Download Station task paging changed during loading.");
        }
        profile.AllTasks = profile.AllTasks
            .Concat(page.Tasks.Select(task => new DownloadTaskItem(task)))
            .ToArray();
        profile.NextOffset = page.NextOffset;
        profile.HasMore = page.HasMore;
    }

    private void ApplyFilter(ProfileState profile)
    {
        var search = SearchText.Trim();
        var filtered = profile.AllTasks.Where(item =>
            MatchesFilter(item.State, Filter) &&
            (string.IsNullOrEmpty(search) ||
             item.Title.Contains(search, StringComparison.CurrentCultureIgnoreCase) ||
             (item.Task.Destination?.Contains(
                 search,
                 StringComparison.CurrentCultureIgnoreCase) ?? false)))
            .ToArray();
        Tasks.Clear();
        foreach (var item in filtered)
        {
            Tasks.Add(item);
        }
        ContentState = Tasks.Count > 0
            ? DownloadStationContentState.Content
            : profile.AllTasks.Count == 0
                ? DownloadStationContentState.Empty
                : DownloadStationContentState.FilteredEmpty;
        RestoreSelection(profile);
        RaisePropertyChanged(nameof(CanLoadMore));
        RaiseControlProperties();
        RaiseDeleteProperties();
    }

    private static bool MatchesFilter(DownloadTaskState state, DownloadTaskFilter filter) =>
        filter switch
        {
            DownloadTaskFilter.All => true,
            DownloadTaskFilter.Active => state is DownloadTaskState.Waiting or
                DownloadTaskState.Downloading or DownloadTaskState.Checking or
                DownloadTaskState.Seeding,
            DownloadTaskFilter.Finished => state == DownloadTaskState.Finished,
            DownloadTaskFilter.Paused => state == DownloadTaskState.Paused,
            _ => false,
        };

    private void RestoreProfile(ProfileState profile)
    {
        ResetErrors();
        SetActivity(profile.Activity);
        SetSettings(profile.Settings);
        SetRss(profile.Rss);
        RestoreFilter(profile);
        SyncActivity(profile);
        ApplyFilter(profile);
    }

    private void RestoreFilter(ProfileState profile)
    {
        SearchText = profile.SearchText;
        Filter = profile.Filter;
    }

    private void RestoreSelection(ProfileState profile)
    {
        SelectedTask = profile.SelectedTaskId is { } id
            ? Tasks.FirstOrDefault(item => item.Id == id)
            : null;
        if (SelectedTask is null && profile.SelectedTaskId is not null)
        {
            profile.SelectedTaskId = null;
        }
    }

    private void SaveCurrentProfileState()
    {
        if (CurrentProfile is { } profile)
        {
            profile.SearchText = SearchText;
            profile.Filter = Filter;
            profile.SelectedTaskId = SelectedTask?.Id;
        }
    }

    private (long Generation, CancellationTokenSource Cancellation) BeginRequest()
    {
        CancelRequest();
        var cancellation = _requestCancellation = new CancellationTokenSource();
        return (_generation, cancellation);
    }

    private (long Generation, CancellationTokenSource Cancellation) BeginControl()
    {
        CancelControl();
        var cancellation = _controlCancellation = new CancellationTokenSource();
        return (_controlGeneration, cancellation);
    }

    private bool IsCurrent(long generation, IDownloadStationRepository repository) =>
        !_disposed && generation == _generation &&
        ReferenceEquals(repository, _repository) && ActiveProfileId == repository.ProfileId;

    private bool IsCurrentControl(long generation, IDownloadStationRepository repository) =>
        !_disposed && generation == _controlGeneration &&
        ReferenceEquals(repository, _repository) && ActiveProfileId == repository.ProfileId;

    private IDownloadStationRepository RequireRepository() => _repository ??
        throw new InvalidOperationException("Download Station is not active for a NAS profile.");

    private ProfileState RequireProfile() => CurrentProfile ??
        throw new InvalidOperationException("Download Station is not active for a NAS profile.");

    private void CancelRequest()
    {
        _generation++;
        _requestCancellation?.Cancel();
        _requestCancellation?.Dispose();
        _requestCancellation = null;
        IsLoading = false;
        IsLoadingMore = false;
    }

    private void CancelControl()
    {
        _controlGeneration++;
        _controlCancellation?.Cancel();
        _controlCancellation?.Dispose();
        _controlCancellation = null;
        IsControllingTask = false;
    }

    private void ResetErrors()
    {
        HasRefreshError = false;
        HasLoadMoreError = false;
    }

    private static bool CanControl(DownloadTaskControlAction action, DownloadTaskState state) =>
        action switch
        {
            DownloadTaskControlAction.Pause => state is DownloadTaskState.Waiting or
                DownloadTaskState.Downloading or DownloadTaskState.Checking,
            DownloadTaskControlAction.Resume => state == DownloadTaskState.Paused,
            _ => false,
        };

    private void ApplyControlOutcome(
        DownloadTaskControlAction action,
        ProfileState profile,
        DownloadTaskControlOutcome outcome)
    {
        if (outcome.Task is { } task)
        {
            ReplaceTask(profile, task);
        }
        var (kind, titleKey, messageKey) = ControlNoticeFor(action, outcome.Result);
        SetControlNotice(kind, titleKey, messageKey);
    }

    private void ReplaceTask(ProfileState profile, DownloadTask task)
    {
        profile.AllTasks = profile.AllTasks
            .Select(item => string.Equals(item.Id, task.Id, StringComparison.Ordinal)
                ? new DownloadTaskItem(task)
                : item)
            .ToArray();
        SyncActivity(profile);
        ApplyFilter(profile);
    }

    private static (DownloadTaskControlNoticeKind Kind, string TitleKey, string MessageKey)
        ControlNoticeFor(DownloadTaskControlAction action, MutationResult result)
    {
        return result.Status switch
        {
            MutationResultStatus.ConfirmedSuccess => (
                DownloadTaskControlNoticeKind.Success,
                action == DownloadTaskControlAction.Pause
                    ? "DownloadStationControlPausedTitle"
                    : "DownloadStationControlResumedTitle",
                "DownloadStationControlSuccessMessage"),
            MutationResultStatus.CancelledBeforeSubmission => (
                DownloadTaskControlNoticeKind.Cancelled,
                "DownloadStationControlCancelledTitle",
                "DownloadStationControlCancelledMessage"),
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission => (
                    DownloadTaskControlNoticeKind.NeedsReview,
                    "DownloadStationControlReviewTitle",
                    "DownloadStationControlReviewMessage"),
            MutationResultStatus.Unsupported => (
                DownloadTaskControlNoticeKind.Unsupported,
                "DownloadStationControlUnsupportedTitle",
                "DownloadStationControlUnsupportedMessage"),
            _ when result.ErrorCategory == MutationErrorCategory.Permission => (
                DownloadTaskControlNoticeKind.Permission,
                "DownloadStationControlPermissionTitle",
                "DownloadStationControlPermissionMessage"),
            _ when result.ErrorCategory == MutationErrorCategory.Conflict => (
                DownloadTaskControlNoticeKind.Conflict,
                "DownloadStationControlConflictTitle",
                "DownloadStationControlConflictMessage"),
            _ => (
                DownloadTaskControlNoticeKind.Failure,
                "DownloadStationControlFailureTitle",
                "DownloadStationControlFailureMessage"),
        };
    }

    private void SetControlNotice(
        DownloadTaskControlNoticeKind kind,
        string titleKey,
        string messageKey)
    {
        ControlNoticeKind = kind;
        ControlNoticeTitle = LocalizationService.Current.Get(titleKey);
        ControlNoticeMessage = LocalizationService.Current.Get(messageKey);
    }

    private void ClearControlNotice()
    {
        ControlNoticeKind = DownloadTaskControlNoticeKind.None;
        ControlNoticeTitle = string.Empty;
        ControlNoticeMessage = string.Empty;
    }

    private void RaiseControlProperties()
    {
        RaisePropertyChanged(nameof(CanPauseSelectedTask));
        RaisePropertyChanged(nameof(CanResumeSelectedTask));
        RaisePropertyChanged(nameof(HasControlNotice));
        RaisePropertyChanged(nameof(IsControlNoticeSuccess));
        RaisePropertyChanged(nameof(IsControlNoticeWarning));
    }

    private void SetActivity(DownloadActivitySection activity)
    {
        _activity = activity;
        RaisePropertyChanged(nameof(HasActivity));
        RaisePropertyChanged(nameof(HasActivityError));
        RaisePropertyChanged(nameof(ActivityDownloadSpeedText));
        RaisePropertyChanged(nameof(ActivityUploadSpeedText));
        RaisePropertyChanged(nameof(ActivityEmuleDownloadSpeedText));
        RaisePropertyChanged(nameof(ActivityEmuleUploadSpeedText));
    }

    private void SetSettings(DownloadStationSettingsSection settings)
    {
        _settings = settings;
        RaisePropertyChanged(nameof(HasAdvancedSummary));
        RaisePropertyChanged(nameof(HasSettings));
        RaisePropertyChanged(nameof(HasSettingsError));
        RaisePropertyChanged(nameof(SettingsDefaultDestinationText));
        RaisePropertyChanged(nameof(SettingsAutoExtractText));
        RaisePropertyChanged(nameof(SettingsEmuleText));
        RaisePropertyChanged(nameof(SettingsScheduleText));
        RaisePropertyChanged(nameof(SettingsSpeedLimitText));
        RaisePropertyChanged(nameof(CreateDestinationText));
    }

    private void SetRss(DownloadRssSection rss)
    {
        _rss = rss;
        RaisePropertyChanged(nameof(HasAdvancedSummary));
        RaisePropertyChanged(nameof(HasRss));
        RaisePropertyChanged(nameof(HasRssError));
        RaisePropertyChanged(nameof(RssSitesText));
        RaisePropertyChanged(nameof(RssFeedsText));
    }

    private void SyncActivity(ProfileState profile)
    {
        if (ActiveProfileId is not Guid profileId)
        {
            return;
        }
        _activityCoordinator?.SyncDownloadStationTasks(
            profileId,
            profile.AllTasks.Select(item => item.Task).ToArray());
    }

    private void RaiseStateProperties()
    {
        RaisePropertyChanged(nameof(HasContent));
        RaisePropertyChanged(nameof(IsEmpty));
        RaisePropertyChanged(nameof(IsFilteredEmpty));
        RaisePropertyChanged(nameof(HasError));
        RaisePropertyChanged(nameof(IsUnavailable));
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        _generation++;
        _controlGeneration++;
        CancelBtSearch(resetSession: true);
        _requestCancellation?.Cancel();
        _requestCancellation?.Dispose();
        _requestCancellation = null;
        _controlCancellation?.Cancel();
        _controlCancellation?.Dispose();
        _controlCancellation = null;
        CancelCreate();
        CancelDelete();
    }

    private sealed class ProfileState
    {
        public bool Loaded { get; set; }
        public IReadOnlyList<DownloadTaskItem> AllTasks { get; set; } = [];
        public int? NextOffset { get; set; }
        public bool HasMore { get; set; }
        public int SourceTotal { get; set; }
        public string SearchText { get; set; } = string.Empty;
        public DownloadTaskFilter Filter { get; set; }
        public string? SelectedTaskId { get; set; }
        public DownloadActivitySection Activity { get; set; } = new(
            DownloadStationSectionStatus.Unavailable,
            null);
        public DownloadDefaultDestinationSection DefaultDestination { get; set; } = new(
            DownloadStationSectionStatus.Unavailable,
            null);
        public DownloadStationSettingsSection Settings { get; set; } = new(
            DownloadStationSectionStatus.Unavailable,
            null);
        public DownloadRssSection Rss { get; set; } = new(
            DownloadStationSectionStatus.Unavailable,
            null);
    }

    private static string TextOrUnavailable(string? value) =>
        string.IsNullOrWhiteSpace(value)
            ? LocalizationService.Current.Get("DownloadStationValueUnavailable")
            : value.Trim();

    private static string FormatToggle(bool? value) => value switch
    {
        true => LocalizationService.Current.Get("DownloadStationSettingEnabled"),
        false => LocalizationService.Current.Get("DownloadStationSettingDisabled"),
        _ => LocalizationService.Current.Get("DownloadStationValueUnavailable"),
    };

    private static string FormatEmuleSettings(DownloadStationSettingsSummary? settings)
    {
        if (settings is null)
        {
            return LocalizationService.Current.Get("DownloadStationValueUnavailable");
        }
        return LocalizationService.Current.Format(
            "DownloadStationSettingsEmuleSummary",
            FormatToggle(settings.IsEmuleEnabled),
            FormatLimitKb(settings.EmuleDownloadLimitKb),
            FormatLimitKb(settings.EmuleUploadLimitKb));
    }

    private static string FormatScheduleSettings(DownloadStationSettingsSummary? settings)
    {
        if (settings is null)
        {
            return LocalizationService.Current.Get("DownloadStationValueUnavailable");
        }
        return LocalizationService.Current.Format(
            "DownloadStationSettingsScheduleSummary",
            FormatToggle(settings.IsScheduleEnabled),
            FormatToggle(settings.IsEmuleScheduleEnabled));
    }

    private static string FormatSpeedLimits(DownloadStationSettingsSummary? settings)
    {
        if (settings is null)
        {
            return LocalizationService.Current.Get("DownloadStationValueUnavailable");
        }
        return LocalizationService.Current.Format(
            "DownloadStationSettingsSpeedLimitSummary",
            FormatLimitKb(settings.BtDownloadLimitKb),
            FormatLimitKb(settings.BtUploadLimitKb),
            FormatLimitKb(settings.HttpDownloadLimitKb),
            FormatLimitKb(settings.FtpDownloadLimitKb),
            FormatLimitKb(settings.NzbDownloadLimitKb));
    }

    private static string FormatLimitKb(int? value) => value switch
    {
        null => LocalizationService.Current.Get("DownloadStationValueUnavailable"),
        <= 0 => LocalizationService.Current.Get("DownloadStationLimitUnlimited"),
        _ => LocalizationService.Current.Format(
            "DownloadStationLimitValue",
            value.Value.ToString("N0", System.Globalization.CultureInfo.CurrentCulture)),
    };
}
