using System.Collections.ObjectModel;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

public sealed class DownloadStationViewModel : ObservableObject, IDisposable
{
    public const int DefaultPageSize = 100;

    private readonly int _pageSize;
    private readonly Dictionary<Guid, ProfileState> _profiles = [];
    private IDownloadStationRepository? _repository;
    private CancellationTokenSource? _requestCancellation;
    private long _generation;
    private Guid? _activeProfileId;
    private DownloadStationContentState _contentState = DownloadStationContentState.Loading;
    private DownloadTaskFilter _filter;
    private string _searchText = string.Empty;
    private DownloadTaskItem? _selectedTask;
    private bool _isLoading;
    private bool _isLoadingMore;
    private bool _hasRefreshError;
    private bool _hasLoadMoreError;
    private DownloadActivitySection _activity = new(
        DownloadStationSectionStatus.Unavailable,
        null);
    private bool _disposed;

    public DownloadStationViewModel(int pageSize = DefaultPageSize)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(pageSize, 1);
        _pageSize = pageSize;
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
    public bool HasActivity => _activity.Status == DownloadStationSectionStatus.Available &&
        _activity.Value is not null;
    public bool HasActivityError => _activity.Status == DownloadStationSectionStatus.Failed;
    public string ActivityDownloadSpeedText =>
        DownloadTaskItem.FormatSpeed(_activity.Value?.DownloadSpeed);
    public string ActivityUploadSpeedText =>
        DownloadTaskItem.FormatSpeed(_activity.Value?.UploadSpeed);
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
        _repository = repository;
        ActiveProfileId = repository.ProfileId;

        if (repository.Availability.Status != DownloadStationAvailabilityStatus.Available ||
            !repository.Availability.SupportedFeatures.Contains(DownloadStationReadFeature.Tasks))
        {
            Tasks.Clear();
            SelectedTask = null;
            SetActivity(new(DownloadStationSectionStatus.Unavailable, null));
            ResetErrors();
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
        _repository = null;
        ActiveProfileId = null;
        Tasks.Clear();
        SelectedTask = null;
        SetActivity(new(DownloadStationSectionStatus.Unavailable, null));
        SearchText = string.Empty;
        Filter = DownloadTaskFilter.All;
        ResetErrors();
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
            SetActivity(snapshot.Activity);
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
        RestoreFilter(profile);
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

    private bool IsCurrent(long generation, IDownloadStationRepository repository) =>
        !_disposed && generation == _generation &&
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

    private void ResetErrors()
    {
        HasRefreshError = false;
        HasLoadMoreError = false;
    }

    private void SetActivity(DownloadActivitySection activity)
    {
        _activity = activity;
        RaisePropertyChanged(nameof(HasActivity));
        RaisePropertyChanged(nameof(HasActivityError));
        RaisePropertyChanged(nameof(ActivityDownloadSpeedText));
        RaisePropertyChanged(nameof(ActivityUploadSpeedText));
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
        _requestCancellation?.Cancel();
        _requestCancellation?.Dispose();
        _requestCancellation = null;
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
    }
}
