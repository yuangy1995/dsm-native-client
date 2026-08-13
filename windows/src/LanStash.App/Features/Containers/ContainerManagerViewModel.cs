using System.Collections.ObjectModel;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Containers;

public sealed class ContainerManagerViewModel : ObservableObject, IDisposable
{
    private const int MaximumCachedProfiles = 4;
    private readonly Dictionary<Guid, ProfileState> _profiles = [];
    private readonly LinkedList<Guid> _profileOrder = [];
    private IContainerManagerRepository? _repository;
    private CancellationTokenSource? _requestCancellation;
    private long _generation;
    private Guid? _activeProfileId;
    private ContainerManagerContentState _containersState = ContainerManagerContentState.Loading;
    private ContainerManagerContentState _imagesState = ContainerManagerContentState.Loading;
    private ContainerManagerContentState _networksState = ContainerManagerContentState.Loading;
    private ContainerManagerContentState _projectsState = ContainerManagerContentState.Loading;
    private ContainerManagerContentState _eventsState = ContainerManagerContentState.Loading;
    private ContainerManagerFilter _filter;
    private ContainerItem? _selectedContainer;
    private bool _isLoading;
    private bool _hasRefreshError;
    private bool _requiresReconnect;
    private bool _disposed;

    public ObservableCollection<ContainerItem> Containers { get; } = [];
    public ObservableCollection<ContainerResourceItem> Images { get; } = [];
    public ObservableCollection<ContainerResourceItem> Networks { get; } = [];
    public ObservableCollection<ContainerResourceItem> Projects { get; } = [];
    public ObservableCollection<ContainerEventItem> Events { get; } = [];

    public Guid? ActiveProfileId
    {
        get => _activeProfileId;
        private set => SetProperty(ref _activeProfileId, value);
    }

    public ContainerManagerContentState ContentState => ContainersState;

    public ContainerManagerContentState ContainersState
    {
        get => _containersState;
        private set
        {
            if (SetProperty(ref _containersState, value))
            {
                RaisePropertyChanged(nameof(ContentState));
                RaiseStateProperties();
            }
        }
    }

    public ContainerManagerContentState ImagesState
    {
        get => _imagesState;
        private set => SetProperty(ref _imagesState, value);
    }

    public ContainerManagerContentState NetworksState
    {
        get => _networksState;
        private set => SetProperty(ref _networksState, value);
    }

    public ContainerManagerContentState ProjectsState
    {
        get => _projectsState;
        private set => SetProperty(ref _projectsState, value);
    }

    public ContainerManagerContentState EventsState
    {
        get => _eventsState;
        private set => SetProperty(ref _eventsState, value);
    }

    public ContainerManagerFilter Filter
    {
        get => _filter;
        private set => SetProperty(ref _filter, value);
    }

    public ContainerItem? SelectedContainer
    {
        get => _selectedContainer;
        private set
        {
            if (SetProperty(ref _selectedContainer, value))
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
                RaisePropertyChanged(nameof(CanRefresh));
            }
        }
    }

    public bool HasRefreshError
    {
        get => _hasRefreshError;
        private set => SetProperty(ref _hasRefreshError, value);
    }

    public bool RequiresReconnect
    {
        get => _requiresReconnect;
        private set
        {
            if (SetProperty(ref _requiresReconnect, value))
            {
                RaisePropertyChanged(nameof(CanRefresh));
            }
        }
    }

    public bool HasContent => ContainersState == ContainerManagerContentState.Content;
    public bool IsEmpty => ContainersState == ContainerManagerContentState.Empty;
    public bool IsFilteredEmpty => ContainersState == ContainerManagerContentState.FilteredEmpty;
    public bool HasError => ContainersState == ContainerManagerContentState.Error;
    public bool IsUnavailable => ContainersState == ContainerManagerContentState.Unavailable;
    public bool HasSelection => SelectedContainer is not null;
    public bool CanRefresh => !IsLoading && !RequiresReconnect &&
        _repository?.Availability.Status == ContainerManagerAvailabilityStatus.InternalObserved;

    private ProfileState? CurrentProfile => ActiveProfileId is Guid id &&
        _profiles.TryGetValue(id, out var profile) ? profile : null;

    public async Task ActivateAsync(IContainerManagerRepository repository)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        var keepsReconnectBlock = ReferenceEquals(_repository, repository) &&
            ActiveProfileId == repository.ProfileId && RequiresReconnect;
        SaveCurrentProfileState();
        CancelRequest();
        _repository = repository;
        ActiveProfileId = repository.ProfileId;
        RequiresReconnect = keepsReconnectBlock;

        if (repository.Availability.Status != ContainerManagerAvailabilityStatus.InternalObserved)
        {
            ClearVisibleContent();
            Filter = ContainerManagerFilter.All;
            HasRefreshError = false;
            RequiresReconnect = false;
            SetAllStates(ContainerManagerContentState.Unavailable);
            RaisePropertyChanged(nameof(CanRefresh));
            return;
        }

        if (_profiles.TryGetValue(repository.ProfileId, out var cached) && cached.Loaded)
        {
            TouchProfile(repository.ProfileId);
            RestoreProfile(cached);
            RaisePropertyChanged(nameof(CanRefresh));
            return;
        }

        var profile = cached ?? new ProfileState();
        CacheProfile(repository.ProfileId, profile);
        Filter = profile.Filter;
        PrepareInitialStates(repository.Availability.Features);
        await LoadAsync(profile, preserveContentOnFailure: false);
    }

    public Task RefreshAsync()
    {
        ThrowIfDisposed();
        return CanRefresh && CurrentProfile is { } profile
            ? LoadAsync(profile, preserveContentOnFailure: profile.Loaded)
            : Task.CompletedTask;
    }

    public void SetFilter(ContainerManagerFilter filter)
    {
        ThrowIfDisposed();
        Filter = filter;
        if (CurrentProfile is { } profile)
        {
            profile.Filter = filter;
            RestoreContainers(profile);
        }
    }

    public void SelectContainer(ContainerItem? item)
    {
        ThrowIfDisposed();
        SelectedContainer = item is null
            ? null
            : Containers.FirstOrDefault(candidate => candidate.Id == item.Id);
        if (CurrentProfile is { } profile)
        {
            profile.SelectedContainerId = SelectedContainer?.Id;
        }
    }

    public void Deactivate()
    {
        ThrowIfDisposed();
        SaveCurrentProfileState();
        CancelRequest();
        _repository = null;
        ActiveProfileId = null;
        ClearVisibleContent();
        Filter = ContainerManagerFilter.All;
        HasRefreshError = false;
        RequiresReconnect = false;
        SetAllStates(ContainerManagerContentState.Loading);
        RaisePropertyChanged(nameof(CanRefresh));
    }

    private async Task LoadAsync(ProfileState profile, bool preserveContentOnFailure)
    {
        var repository = RequireRepository();
        var request = BeginRequest();
        IsLoading = true;
        HasRefreshError = false;
        if (!preserveContentOnFailure)
        {
            PrepareInitialStates(repository.Availability.Features);
        }
        try
        {
            var snapshot = await repository.LoadSnapshotAsync(request.Cancellation.Token);
            if (!IsCurrent(request.Generation, repository))
            {
                return;
            }
            if (snapshot.ProfileId != repository.ProfileId)
            {
                throw new InvalidDataException("Container Manager returned another profile.");
            }
            ApplySnapshot(profile, snapshot);
            profile.Loaded = true;
            TouchProfile(repository.ProfileId);
        }
        catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
        {
        }
        catch (DsmException error) when (IsAuthenticationFailure(error))
        {
            if (IsCurrent(request.Generation, repository))
            {
                RequiresReconnect = true;
                HasRefreshError = false;
                if (!preserveContentOnFailure || !profile.Loaded)
                {
                    ClearVisibleContent();
                    MarkSupportedSectionsFailed(repository.Availability.Features);
                }
            }
        }
        catch
        {
            if (IsCurrent(request.Generation, repository))
            {
                HasRefreshError = true;
                if (!preserveContentOnFailure || !profile.Loaded)
                {
                    ClearVisibleContent();
                    MarkSupportedSectionsFailed(repository.Availability.Features);
                }
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, repository))
            {
                IsLoading = false;
                RaisePropertyChanged(nameof(CanRefresh));
            }
        }
    }

    private void ApplySnapshot(ProfileState profile, ContainerManagerSnapshot snapshot)
    {
        ApplyContainerSection(profile, snapshot.Containers);
        ApplyResourceSection(profile, ContainerManagerReadFeature.Images, snapshot.Images);
        ApplyResourceSection(profile, ContainerManagerReadFeature.Networks, snapshot.Networks);
        ApplyResourceSection(profile, ContainerManagerReadFeature.Projects, snapshot.Projects);
        ApplyEventSection(profile, snapshot.Events);
        RestoreProfile(profile);
        HasRefreshError = profile.HasSectionFailure;
    }

    private static void ApplyContainerSection(
        ProfileState profile,
        ContainerManagerSection<ContainerSummary> section)
    {
        if (section.Status == ContainerManagerSectionStatus.Available)
        {
            profile.Containers = section.Items.Select(item => new ContainerItem(item)).ToArray();
            profile.ContainersBaseState = profile.Containers.Count == 0
                ? ContainerManagerContentState.Empty
                : ContainerManagerContentState.Content;
            profile.ContainersRefreshFailed = false;
        }
        else if (section.Status == ContainerManagerSectionStatus.Failed)
        {
            profile.ContainersRefreshFailed = true;
            if (profile.Containers.Count == 0)
            {
                profile.ContainersBaseState = ContainerManagerContentState.Error;
            }
        }
        else
        {
            profile.Containers = [];
            profile.ContainersBaseState = ContainerManagerContentState.Unavailable;
            profile.ContainersRefreshFailed = false;
        }
    }

    private static void ApplyResourceSection(
        ProfileState profile,
        ContainerManagerReadFeature feature,
        ContainerManagerSection<ContainerResourceSummary> section)
    {
        var previous = profile.Resources[feature];
        if (section.Status == ContainerManagerSectionStatus.Available)
        {
            var items = section.Items.Select(item => new ContainerResourceItem(item)).ToArray();
            profile.Resources[feature] = new(
                items.Length == 0 ? ContainerManagerContentState.Empty : ContainerManagerContentState.Content,
                items,
                false);
        }
        else if (section.Status == ContainerManagerSectionStatus.Failed)
        {
            profile.Resources[feature] = previous.Items.Count > 0
                ? previous with { RefreshFailed = true }
                : new(ContainerManagerContentState.Error, [], true);
        }
        else
        {
            profile.Resources[feature] = new(ContainerManagerContentState.Unavailable, [], false);
        }
    }

    private static void ApplyEventSection(
        ProfileState profile,
        ContainerManagerSection<ServiceEventSummary> section)
    {
        if (section.Status == ContainerManagerSectionStatus.Available)
        {
            profile.Events = section.Items.Select(item => new ContainerEventItem(item)).ToArray();
            profile.EventsState = profile.Events.Count == 0
                ? ContainerManagerContentState.Empty
                : ContainerManagerContentState.Content;
            profile.EventsRefreshFailed = false;
        }
        else if (section.Status == ContainerManagerSectionStatus.Failed)
        {
            profile.EventsRefreshFailed = true;
            if (profile.Events.Count == 0)
            {
                profile.EventsState = ContainerManagerContentState.Error;
            }
        }
        else
        {
            profile.Events = [];
            profile.EventsState = ContainerManagerContentState.Unavailable;
            profile.EventsRefreshFailed = false;
        }
    }

    private void RestoreProfile(ProfileState profile)
    {
        Filter = profile.Filter;
        RestoreContainers(profile);
        Replace(Images, profile.Resources[ContainerManagerReadFeature.Images].Items);
        Replace(Networks, profile.Resources[ContainerManagerReadFeature.Networks].Items);
        Replace(Projects, profile.Resources[ContainerManagerReadFeature.Projects].Items);
        Replace(Events, profile.Events);
        ImagesState = profile.Resources[ContainerManagerReadFeature.Images].State;
        NetworksState = profile.Resources[ContainerManagerReadFeature.Networks].State;
        ProjectsState = profile.Resources[ContainerManagerReadFeature.Projects].State;
        EventsState = profile.EventsState;
        HasRefreshError = profile.HasSectionFailure;
    }

    private void RestoreContainers(ProfileState profile)
    {
        var visible = profile.Containers.Where(MatchesFilter).ToArray();
        Replace(Containers, visible);
        ContainersState = profile.ContainersBaseState == ContainerManagerContentState.Content && visible.Length == 0
            ? ContainerManagerContentState.FilteredEmpty
            : profile.ContainersBaseState;
        SelectedContainer = profile.SelectedContainerId is { } id
            ? Containers.FirstOrDefault(item => item.Id == id)
            : null;
        if (SelectedContainer is null && profile.SelectedContainerId is not null)
        {
            profile.SelectedContainerId = null;
        }
    }

    private bool MatchesFilter(ContainerItem item) => Filter switch
    {
        ContainerManagerFilter.Running => item.State == ContainerOperationalState.Running,
        ContainerManagerFilter.Stopped => item.State == ContainerOperationalState.Stopped,
        ContainerManagerFilter.Attention => item.State is ContainerOperationalState.Attention or ContainerOperationalState.Unknown,
        _ => true,
    };

    private void PrepareInitialStates(IReadOnlySet<ContainerManagerReadFeature> features)
    {
        ClearVisibleContent();
        ContainersState = InitialState(features, ContainerManagerReadFeature.Containers);
        ImagesState = InitialState(features, ContainerManagerReadFeature.Images);
        NetworksState = InitialState(features, ContainerManagerReadFeature.Networks);
        ProjectsState = InitialState(features, ContainerManagerReadFeature.Projects);
        EventsState = InitialState(features, ContainerManagerReadFeature.Events);
    }

    private void MarkSupportedSectionsFailed(IReadOnlySet<ContainerManagerReadFeature> features)
    {
        ContainersState = FailedState(features, ContainerManagerReadFeature.Containers);
        ImagesState = FailedState(features, ContainerManagerReadFeature.Images);
        NetworksState = FailedState(features, ContainerManagerReadFeature.Networks);
        ProjectsState = FailedState(features, ContainerManagerReadFeature.Projects);
        EventsState = FailedState(features, ContainerManagerReadFeature.Events);
    }

    private static ContainerManagerContentState InitialState(
        IReadOnlySet<ContainerManagerReadFeature> features,
        ContainerManagerReadFeature feature) => features.Contains(feature)
            ? ContainerManagerContentState.Loading
            : ContainerManagerContentState.Unavailable;

    private static ContainerManagerContentState FailedState(
        IReadOnlySet<ContainerManagerReadFeature> features,
        ContainerManagerReadFeature feature) => features.Contains(feature)
            ? ContainerManagerContentState.Error
            : ContainerManagerContentState.Unavailable;

    private void SaveCurrentProfileState()
    {
        if (CurrentProfile is { } profile)
        {
            profile.Filter = Filter;
            profile.SelectedContainerId = SelectedContainer?.Id;
        }
    }

    private void CacheProfile(Guid profileId, ProfileState profile)
    {
        _profiles[profileId] = profile;
        TouchProfile(profileId);
        while (_profiles.Count > MaximumCachedProfiles && _profileOrder.First is { } oldest)
        {
            _profileOrder.RemoveFirst();
            _profiles.Remove(oldest.Value);
        }
    }

    private void TouchProfile(Guid profileId)
    {
        _profileOrder.Remove(profileId);
        _profileOrder.AddLast(profileId);
    }

    private (long Generation, CancellationTokenSource Cancellation) BeginRequest()
    {
        CancelRequest();
        var cancellation = _requestCancellation = new CancellationTokenSource();
        return (_generation, cancellation);
    }

    private bool IsCurrent(long generation, IContainerManagerRepository repository) =>
        !_disposed && generation == _generation && ReferenceEquals(repository, _repository) &&
        ActiveProfileId == repository.ProfileId;

    private IContainerManagerRepository RequireRepository() => _repository ??
        throw new InvalidOperationException("Container Manager is not active for a NAS profile.");

    private static bool IsAuthenticationFailure(DsmException error) =>
        error.AuthenticationFailure || error.Code is 106 or 107 or 119;

    private void CancelRequest()
    {
        _generation++;
        _requestCancellation?.Cancel();
        _requestCancellation?.Dispose();
        _requestCancellation = null;
        IsLoading = false;
    }

    private void ClearVisibleContent()
    {
        Containers.Clear();
        Images.Clear();
        Networks.Clear();
        Projects.Clear();
        Events.Clear();
        SelectedContainer = null;
    }

    private void SetAllStates(ContainerManagerContentState state)
    {
        ContainersState = state;
        ImagesState = state;
        NetworksState = state;
        ProjectsState = state;
        EventsState = state;
    }

    private void RaiseStateProperties()
    {
        RaisePropertyChanged(nameof(HasContent));
        RaisePropertyChanged(nameof(IsEmpty));
        RaisePropertyChanged(nameof(IsFilteredEmpty));
        RaisePropertyChanged(nameof(HasError));
        RaisePropertyChanged(nameof(IsUnavailable));
    }

    private static void Replace<T>(ObservableCollection<T> target, IReadOnlyList<T> source)
    {
        target.Clear();
        foreach (var item in source)
        {
            target.Add(item);
        }
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
        public ContainerManagerFilter Filter { get; set; }
        public IReadOnlyList<ContainerItem> Containers { get; set; } = [];
        public ContainerManagerContentState ContainersBaseState { get; set; } = ContainerManagerContentState.Loading;
        public bool ContainersRefreshFailed { get; set; }
        public string? SelectedContainerId { get; set; }
        public Dictionary<ContainerManagerReadFeature, ResourceState> Resources { get; } = new()
        {
            [ContainerManagerReadFeature.Images] = ResourceState.Loading,
            [ContainerManagerReadFeature.Networks] = ResourceState.Loading,
            [ContainerManagerReadFeature.Projects] = ResourceState.Loading,
        };
        public IReadOnlyList<ContainerEventItem> Events { get; set; } = [];
        public ContainerManagerContentState EventsState { get; set; } = ContainerManagerContentState.Loading;
        public bool EventsRefreshFailed { get; set; }
        public bool HasSectionFailure => ContainersRefreshFailed || EventsRefreshFailed ||
            Resources.Values.Any(section => section.RefreshFailed);
    }

    private sealed record ResourceState(
        ContainerManagerContentState State,
        IReadOnlyList<ContainerResourceItem> Items,
        bool RefreshFailed)
    {
        public static ResourceState Loading { get; } = new(ContainerManagerContentState.Loading, [], false);
    }
}
