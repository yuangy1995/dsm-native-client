using System.Collections.ObjectModel;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public sealed class VirtualMachineManagerViewModel : ObservableObject, IDisposable
{
    private const int MaximumCachedProfiles = 4;
    private readonly Dictionary<Guid, ProfileState> _profiles = [];
    private readonly LinkedList<Guid> _profileOrder = [];
    private IVirtualMachineManagerRepository? _repository;
    private CancellationTokenSource? _requestCancellation;
    private long _generation;
    private Guid? _activeProfileId;
    private VirtualMachineItem? _selectedMachine;
    private bool _isLoading;
    private bool _hasRefreshError;
    private bool _requiresReconnect;
    private VirtualMachineManagerContentState _machinesState = VirtualMachineManagerContentState.Loading;
    private VirtualMachineManagerContentState _hostsState = VirtualMachineManagerContentState.Loading;
    private VirtualMachineManagerContentState _storagesState = VirtualMachineManagerContentState.Loading;
    private VirtualMachineManagerContentState _networksState = VirtualMachineManagerContentState.Loading;
    private VirtualMachineManagerContentState _imagesState = VirtualMachineManagerContentState.Loading;
    private VirtualMachineManagerContentState _protectionState = VirtualMachineManagerContentState.Loading;
    private VirtualMachineManagerContentState _eventsState = VirtualMachineManagerContentState.Loading;
    private bool _disposed;

    public ObservableCollection<VirtualMachineItem> Machines { get; } = [];
    public ObservableCollection<VirtualizationResourceItem> Hosts { get; } = [];
    public ObservableCollection<VirtualizationResourceItem> Storages { get; } = [];
    public ObservableCollection<VirtualizationResourceItem> Networks { get; } = [];
    public ObservableCollection<VirtualizationResourceItem> Images { get; } = [];
    public ObservableCollection<VirtualizationResourceItem> Protection { get; } = [];
    public ObservableCollection<VirtualMachineEventItem> Events { get; } = [];

    public Guid? ActiveProfileId
    {
        get => _activeProfileId;
        private set => SetProperty(ref _activeProfileId, value);
    }

    public VirtualMachineItem? SelectedMachine
    {
        get => _selectedMachine;
        private set
        {
            if (SetProperty(ref _selectedMachine, value))
            {
                RaisePropertyChanged(nameof(HasSelection));
            }
        }
    }

    public bool IsLoading
    {
        get => _isLoading;
        private set => SetProperty(ref _isLoading, value);
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

    public VirtualMachineManagerContentState MachinesState
    {
        get => _machinesState;
        private set => SetProperty(ref _machinesState, value);
    }

    public VirtualMachineManagerContentState HostsState
    {
        get => _hostsState;
        private set => SetProperty(ref _hostsState, value);
    }

    public VirtualMachineManagerContentState StoragesState
    {
        get => _storagesState;
        private set => SetProperty(ref _storagesState, value);
    }

    public VirtualMachineManagerContentState NetworksState
    {
        get => _networksState;
        private set => SetProperty(ref _networksState, value);
    }

    public VirtualMachineManagerContentState ImagesState
    {
        get => _imagesState;
        private set => SetProperty(ref _imagesState, value);
    }

    public VirtualMachineManagerContentState ProtectionState
    {
        get => _protectionState;
        private set => SetProperty(ref _protectionState, value);
    }

    public VirtualMachineManagerContentState EventsState
    {
        get => _eventsState;
        private set => SetProperty(ref _eventsState, value);
    }

    public bool HasSelection => SelectedMachine is not null;
    public bool CanRefresh => !IsLoading && !RequiresReconnect &&
        _repository?.Availability is
        {
            Status: VirtualMachineManagerAvailabilityStatus.Available,
            Features: var features,
        } && features.Contains(VirtualMachineManagerReadFeature.Machines);

    public async Task ActivateAsync(IVirtualMachineManagerRepository repository)
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

        if (repository.Availability.Status != VirtualMachineManagerAvailabilityStatus.Available ||
            !repository.Availability.Features.Contains(VirtualMachineManagerReadFeature.Machines))
        {
            ClearVisibleContent();
            HasRefreshError = false;
            RequiresReconnect = false;
            SetAllStates(VirtualMachineManagerContentState.Unavailable);
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
        PrepareInitialStates(repository.Availability.Features);
        await LoadAsync(profile, preserveContentOnFailure: false);
    }

    public Task RefreshAsync()
    {
        ThrowIfDisposed();
        return CanRefresh &&
            CurrentProfile is { } profile
                ? LoadAsync(profile, preserveContentOnFailure: profile.Loaded)
                : Task.CompletedTask;
    }

    public void SelectMachine(VirtualMachineItem? machine)
    {
        ThrowIfDisposed();
        SelectedMachine = machine is null
            ? null
            : Machines.FirstOrDefault(item => item.Id == machine.Id);
        if (CurrentProfile is { } profile)
        {
            profile.SelectedMachineId = SelectedMachine?.Id;
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
        HasRefreshError = false;
        RequiresReconnect = false;
        SetAllStates(VirtualMachineManagerContentState.Loading);
        RaisePropertyChanged(nameof(CanRefresh));
    }

    private ProfileState? CurrentProfile => ActiveProfileId is Guid id &&
        _profiles.TryGetValue(id, out var profile) ? profile : null;

    private async Task LoadAsync(ProfileState profile, bool preserveContentOnFailure)
    {
        var repository = RequireRepository();
        var request = BeginRequest();
        IsLoading = true;
        HasRefreshError = false;
        RaisePropertyChanged(nameof(CanRefresh));
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
                throw new InvalidDataException("Virtual Machine Manager returned another profile.");
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

    private void ApplySnapshot(ProfileState profile, VirtualMachineManagerSnapshot snapshot)
    {
        ApplyMachineSection(profile, snapshot.Machines);
        ApplyResourceSection(profile, VirtualMachineManagerReadFeature.Hosts, snapshot.Hosts);
        ApplyResourceSection(profile, VirtualMachineManagerReadFeature.Storages, snapshot.Storages);
        ApplyResourceSection(profile, VirtualMachineManagerReadFeature.Networks, snapshot.Networks);
        ApplyResourceSection(profile, VirtualMachineManagerReadFeature.Images, snapshot.Images);
        ApplyResourceSection(profile, VirtualMachineManagerReadFeature.Protection, snapshot.Protection);
        ApplyEventSection(profile, snapshot.Events);
        RestoreProfile(profile);
        HasRefreshError = profile.HasSectionFailure;
    }

    private static void ApplyMachineSection(
        ProfileState profile,
        VirtualMachineManagerSection<VirtualMachineSummary> section)
    {
        if (section.Status == VirtualMachineManagerSectionStatus.Available)
        {
            profile.Machines = section.Items.Select(item => new VirtualMachineItem(item)).ToArray();
            profile.MachinesState = profile.Machines.Count == 0
                ? VirtualMachineManagerContentState.Empty
                : VirtualMachineManagerContentState.Content;
            profile.MachinesRefreshFailed = false;
        }
        else if (section.Status == VirtualMachineManagerSectionStatus.Failed)
        {
            profile.MachinesRefreshFailed = true;
            if (profile.Machines.Count == 0)
            {
                profile.MachinesState = VirtualMachineManagerContentState.Error;
            }
        }
        else
        {
            profile.Machines = [];
            profile.MachinesState = VirtualMachineManagerContentState.Unavailable;
            profile.MachinesRefreshFailed = false;
        }
    }

    private static void ApplyResourceSection(
        ProfileState profile,
        VirtualMachineManagerReadFeature feature,
        VirtualMachineManagerSection<VirtualizationResourceSummary> section)
    {
        var previous = profile.Resources[feature];
        if (section.Status == VirtualMachineManagerSectionStatus.Available)
        {
            var items = section.Items.Select(item => new VirtualizationResourceItem(item)).ToArray();
            profile.Resources[feature] = new(
                items.Length == 0
                    ? VirtualMachineManagerContentState.Empty
                    : VirtualMachineManagerContentState.Content,
                items,
                false);
        }
        else if (section.Status == VirtualMachineManagerSectionStatus.Failed)
        {
            profile.Resources[feature] = previous.Items.Count > 0
                ? previous with { RefreshFailed = true }
                : new(VirtualMachineManagerContentState.Error, [], true);
        }
        else
        {
            profile.Resources[feature] = new(
                VirtualMachineManagerContentState.Unavailable,
                [],
                false);
        }
    }

    private static void ApplyEventSection(
        ProfileState profile,
        VirtualMachineManagerSection<ServiceEventSummary> section)
    {
        if (section.Status == VirtualMachineManagerSectionStatus.Available)
        {
            profile.Events = section.Items.Select(item => new VirtualMachineEventItem(item)).ToArray();
            profile.EventsState = profile.Events.Count == 0
                ? VirtualMachineManagerContentState.Empty
                : VirtualMachineManagerContentState.Content;
            profile.EventsRefreshFailed = false;
        }
        else if (section.Status == VirtualMachineManagerSectionStatus.Failed)
        {
            profile.EventsRefreshFailed = true;
            if (profile.Events.Count == 0)
            {
                profile.EventsState = VirtualMachineManagerContentState.Error;
            }
        }
        else
        {
            profile.Events = [];
            profile.EventsState = VirtualMachineManagerContentState.Unavailable;
            profile.EventsRefreshFailed = false;
        }
    }

    private void RestoreProfile(ProfileState profile)
    {
        Replace(Machines, profile.Machines);
        Replace(Hosts, profile.Resources[VirtualMachineManagerReadFeature.Hosts].Items);
        Replace(Storages, profile.Resources[VirtualMachineManagerReadFeature.Storages].Items);
        Replace(Networks, profile.Resources[VirtualMachineManagerReadFeature.Networks].Items);
        Replace(Images, profile.Resources[VirtualMachineManagerReadFeature.Images].Items);
        Replace(Protection, profile.Resources[VirtualMachineManagerReadFeature.Protection].Items);
        Replace(Events, profile.Events);
        MachinesState = profile.MachinesState;
        HostsState = profile.Resources[VirtualMachineManagerReadFeature.Hosts].State;
        StoragesState = profile.Resources[VirtualMachineManagerReadFeature.Storages].State;
        NetworksState = profile.Resources[VirtualMachineManagerReadFeature.Networks].State;
        ImagesState = profile.Resources[VirtualMachineManagerReadFeature.Images].State;
        ProtectionState = profile.Resources[VirtualMachineManagerReadFeature.Protection].State;
        EventsState = profile.EventsState;
        SelectedMachine = profile.SelectedMachineId is { } id
            ? Machines.FirstOrDefault(item => item.Id == id)
            : null;
        if (SelectedMachine is null && profile.SelectedMachineId is not null)
        {
            profile.SelectedMachineId = null;
        }
        HasRefreshError = profile.HasSectionFailure;
    }

    private void PrepareInitialStates(IReadOnlySet<VirtualMachineManagerReadFeature> features)
    {
        ClearVisibleContent();
        MachinesState = features.Contains(VirtualMachineManagerReadFeature.Machines)
            ? VirtualMachineManagerContentState.Loading
            : VirtualMachineManagerContentState.Unavailable;
        HostsState = InitialState(features, VirtualMachineManagerReadFeature.Hosts);
        StoragesState = InitialState(features, VirtualMachineManagerReadFeature.Storages);
        NetworksState = InitialState(features, VirtualMachineManagerReadFeature.Networks);
        ImagesState = InitialState(features, VirtualMachineManagerReadFeature.Images);
        ProtectionState = InitialState(features, VirtualMachineManagerReadFeature.Protection);
        EventsState = InitialState(features, VirtualMachineManagerReadFeature.Events);
    }

    private void MarkSupportedSectionsFailed(IReadOnlySet<VirtualMachineManagerReadFeature> features)
    {
        MachinesState = FailedState(features, VirtualMachineManagerReadFeature.Machines);
        HostsState = FailedState(features, VirtualMachineManagerReadFeature.Hosts);
        StoragesState = FailedState(features, VirtualMachineManagerReadFeature.Storages);
        NetworksState = FailedState(features, VirtualMachineManagerReadFeature.Networks);
        ImagesState = FailedState(features, VirtualMachineManagerReadFeature.Images);
        ProtectionState = FailedState(features, VirtualMachineManagerReadFeature.Protection);
        EventsState = FailedState(features, VirtualMachineManagerReadFeature.Events);
    }

    private static VirtualMachineManagerContentState InitialState(
        IReadOnlySet<VirtualMachineManagerReadFeature> features,
        VirtualMachineManagerReadFeature feature) => features.Contains(feature)
            ? VirtualMachineManagerContentState.Loading
            : VirtualMachineManagerContentState.Unavailable;

    private static VirtualMachineManagerContentState FailedState(
        IReadOnlySet<VirtualMachineManagerReadFeature> features,
        VirtualMachineManagerReadFeature feature) => features.Contains(feature)
            ? VirtualMachineManagerContentState.Error
            : VirtualMachineManagerContentState.Unavailable;

    private void SaveCurrentProfileState()
    {
        if (CurrentProfile is { } profile)
        {
            profile.SelectedMachineId = SelectedMachine?.Id;
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

    private bool IsCurrent(long generation, IVirtualMachineManagerRepository repository) =>
        !_disposed && generation == _generation && ReferenceEquals(repository, _repository) &&
        ActiveProfileId == repository.ProfileId;

    private IVirtualMachineManagerRepository RequireRepository() => _repository ??
        throw new InvalidOperationException("Virtual Machine Manager is not active for a NAS profile.");

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
        Machines.Clear();
        Hosts.Clear();
        Storages.Clear();
        Networks.Clear();
        Images.Clear();
        Protection.Clear();
        Events.Clear();
        SelectedMachine = null;
    }

    private void SetAllStates(VirtualMachineManagerContentState state)
    {
        MachinesState = state;
        HostsState = state;
        StoragesState = state;
        NetworksState = state;
        ImagesState = state;
        ProtectionState = state;
        EventsState = state;
    }

    private static void Replace<T>(ObservableCollection<T> target, IReadOnlyList<T> items)
    {
        target.Clear();
        foreach (var item in items)
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
        public IReadOnlyList<VirtualMachineItem> Machines { get; set; } = [];
        public VirtualMachineManagerContentState MachinesState { get; set; } =
            VirtualMachineManagerContentState.Loading;
        public bool MachinesRefreshFailed { get; set; }
        public string? SelectedMachineId { get; set; }
        public Dictionary<VirtualMachineManagerReadFeature, ResourceState> Resources { get; } = new()
        {
            [VirtualMachineManagerReadFeature.Hosts] = ResourceState.Loading,
            [VirtualMachineManagerReadFeature.Storages] = ResourceState.Loading,
            [VirtualMachineManagerReadFeature.Networks] = ResourceState.Loading,
            [VirtualMachineManagerReadFeature.Images] = ResourceState.Loading,
            [VirtualMachineManagerReadFeature.Protection] = ResourceState.Loading,
        };
        public IReadOnlyList<VirtualMachineEventItem> Events { get; set; } = [];
        public VirtualMachineManagerContentState EventsState { get; set; } =
            VirtualMachineManagerContentState.Loading;
        public bool EventsRefreshFailed { get; set; }
        public bool HasSectionFailure => MachinesRefreshFailed ||
            EventsRefreshFailed || Resources.Values.Any(section => section.RefreshFailed);
    }

    private sealed record ResourceState(
        VirtualMachineManagerContentState State,
        IReadOnlyList<VirtualizationResourceItem> Items,
        bool RefreshFailed)
    {
        public static ResourceState Loading { get; } = new(
            VirtualMachineManagerContentState.Loading,
            [],
            false);
    }
}
