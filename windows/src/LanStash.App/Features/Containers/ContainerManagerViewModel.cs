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
    private ContainerManagerContentState _contentState = ContainerManagerContentState.Loading;
    private ContainerManagerFilter _filter;
    private ContainerItem? _selectedContainer;
    private bool _isLoading;
    private bool _hasRefreshError;
    private bool _disposed;

    public ObservableCollection<ContainerItem> Containers { get; } = [];

    public Guid? ActiveProfileId
    {
        get => _activeProfileId;
        private set => SetProperty(ref _activeProfileId, value);
    }

    public ContainerManagerContentState ContentState
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

    public bool HasContent => ContentState == ContainerManagerContentState.Content;
    public bool IsEmpty => ContentState == ContainerManagerContentState.Empty;
    public bool IsFilteredEmpty => ContentState == ContainerManagerContentState.FilteredEmpty;
    public bool HasError => ContentState == ContainerManagerContentState.Error;
    public bool IsUnavailable => ContentState == ContainerManagerContentState.Unavailable;
    public bool HasSelection => SelectedContainer is not null;
    public bool CanRefresh => !IsLoading &&
        _repository?.Availability.Status == ContainerManagerAvailabilityStatus.InternalObserved;

    private ProfileState? CurrentProfile => ActiveProfileId is Guid id &&
        _profiles.TryGetValue(id, out var profile) ? profile : null;

    public async Task ActivateAsync(IContainerManagerRepository repository)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(repository);
        SaveCurrentProfileState();
        CancelRequest();
        _repository = repository;
        ActiveProfileId = repository.ProfileId;

        if (repository.Availability.Status != ContainerManagerAvailabilityStatus.InternalObserved)
        {
            Containers.Clear();
            SelectedContainer = null;
            Filter = ContainerManagerFilter.All;
            HasRefreshError = false;
            ContentState = ContainerManagerContentState.Unavailable;
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
            ApplyFilter(profile);
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
        Containers.Clear();
        SelectedContainer = null;
        Filter = ContainerManagerFilter.All;
        HasRefreshError = false;
        ContentState = ContainerManagerContentState.Loading;
        RaisePropertyChanged(nameof(CanRefresh));
    }

    private async Task LoadAsync(ProfileState profile, bool preserveContentOnFailure)
    {
        var repository = RequireRepository();
        var request = BeginRequest();
        IsLoading = true;
        HasRefreshError = false;
        if (!preserveContentOnFailure || !profile.Loaded)
        {
            Containers.Clear();
            SelectedContainer = null;
            ContentState = ContainerManagerContentState.Loading;
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
            profile.AllContainers = snapshot.Containers
                .Select(item => new ContainerItem(item))
                .ToArray();
            profile.Loaded = true;
            ApplyFilter(profile);
            TouchProfile(repository.ProfileId);
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
                    Containers.Clear();
                    SelectedContainer = null;
                    ContentState = ContainerManagerContentState.Error;
                }
            }
        }
        finally
        {
            if (IsCurrent(request.Generation, repository))
            {
                IsLoading = false;
            }
        }
    }

    private void ApplyFilter(ProfileState profile)
    {
        var filtered = profile.AllContainers
            .Where(item => MatchesFilter(item.State, Filter))
            .ToArray();
        Containers.Clear();
        foreach (var item in filtered)
        {
            Containers.Add(item);
        }
        ContentState = Containers.Count > 0
            ? ContainerManagerContentState.Content
            : profile.AllContainers.Count == 0
                ? ContainerManagerContentState.Empty
                : ContainerManagerContentState.FilteredEmpty;
        RestoreSelection(profile);
    }

    private static bool MatchesFilter(
        ContainerOperationalState state,
        ContainerManagerFilter filter) => filter switch
        {
            ContainerManagerFilter.All => true,
            ContainerManagerFilter.Running => state == ContainerOperationalState.Running,
            ContainerManagerFilter.Stopped => state == ContainerOperationalState.Stopped,
            ContainerManagerFilter.Attention => state is
                ContainerOperationalState.Attention or ContainerOperationalState.Unknown,
            _ => false,
        };

    private void RestoreProfile(ProfileState profile)
    {
        HasRefreshError = false;
        Filter = profile.Filter;
        ApplyFilter(profile);
    }

    private void RestoreSelection(ProfileState profile)
    {
        SelectedContainer = profile.SelectedContainerId is { } id
            ? Containers.FirstOrDefault(item => item.Id == id)
            : null;
        if (SelectedContainer is null && profile.SelectedContainerId is not null)
        {
            profile.SelectedContainerId = null;
        }
    }

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

    private void CancelRequest()
    {
        _generation++;
        _requestCancellation?.Cancel();
        _requestCancellation?.Dispose();
        _requestCancellation = null;
        IsLoading = false;
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
        public IReadOnlyList<ContainerItem> AllContainers { get; set; } = [];
        public ContainerManagerFilter Filter { get; set; }
        public string? SelectedContainerId { get; set; }
    }
}
