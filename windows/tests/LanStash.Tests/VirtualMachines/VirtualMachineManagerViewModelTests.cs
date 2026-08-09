using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class VirtualMachineManagerViewModelTests
{
    [Fact]
    public async Task UnavailableRepositoryShowsAllSectionsUnavailableWithoutRequest()
    {
        var repository = new FakeRepository(Guid.NewGuid(), available: false);
        using var model = new VirtualMachineManagerViewModel();

        await model.ActivateAsync(repository);

        Assert.Equal(VirtualMachineManagerContentState.Unavailable, model.MachinesState);
        Assert.Equal(VirtualMachineManagerContentState.Unavailable, model.HostsState);
        Assert.Equal(VirtualMachineManagerContentState.Unavailable, model.StoragesState);
        Assert.Equal(VirtualMachineManagerContentState.Unavailable, model.NetworksState);
        Assert.Equal(VirtualMachineManagerContentState.Unavailable, model.ImagesState);
        Assert.Empty(repository.Requests);
        Assert.False(model.CanRefresh);
    }

    [Fact]
    public async Task MissingMachineFeatureDisablesRefreshAndF5SeamMakesNoRequest()
    {
        var repository = new FakeRepository(
            Guid.NewGuid(),
            available: true,
            features: new HashSet<VirtualMachineManagerReadFeature>
            {
                VirtualMachineManagerReadFeature.Hosts,
            });
        using var model = new VirtualMachineManagerViewModel();

        await model.ActivateAsync(repository);
        await model.RefreshAsync();

        Assert.Equal(VirtualMachineManagerContentState.Unavailable, model.MachinesState);
        Assert.False(model.CanRefresh);
        Assert.Empty(repository.Requests);
    }

    [Fact]
    public async Task FiveSectionsKeepIndependentContentEmptyErrorAndUnavailableStates()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.Results.Enqueue(new VirtualMachineManagerSnapshot(
            profile,
            VirtualMachineManagerSection<VirtualMachineSummary>.Available([Machine("vm")]),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Failed,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([]),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([Resource("network", VirtualizationResourceKind.Network)]),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable));
        using var model = new VirtualMachineManagerViewModel();

        await model.ActivateAsync(repository);

        Assert.Equal(VirtualMachineManagerContentState.Content, model.MachinesState);
        Assert.Equal(VirtualMachineManagerContentState.Error, model.HostsState);
        Assert.Equal(VirtualMachineManagerContentState.Empty, model.StoragesState);
        Assert.Equal(VirtualMachineManagerContentState.Content, model.NetworksState);
        Assert.Equal(VirtualMachineManagerContentState.Unavailable, model.ImagesState);
        Assert.True(model.HasRefreshError);
        Assert.Equal("network", Assert.Single(model.Networks).Name);
    }

    [Fact]
    public async Task SectionRefreshFailureRetainsPreviousItemsAndOtherSectionsUpdate()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.Results.Enqueue(Snapshot(
            profile,
            machines: [Machine("old-vm")],
            hosts: [Resource("old-host", VirtualizationResourceKind.Host)]));
        repository.Results.Enqueue(new VirtualMachineManagerSnapshot(
            profile,
            VirtualMachineManagerSection<VirtualMachineSummary>.Available([Machine("new-vm")]),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Failed,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([Resource("storage", VirtualizationResourceKind.Storage)]),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([]),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([])));
        using var model = new VirtualMachineManagerViewModel();
        await model.ActivateAsync(repository);

        await model.RefreshAsync();

        Assert.Equal("new-vm", Assert.Single(model.Machines).Name);
        Assert.Equal("old-host", Assert.Single(model.Hosts).Name);
        Assert.Equal(VirtualMachineManagerContentState.Content, model.HostsState);
        Assert.Equal("storage", Assert.Single(model.Storages).Name);
        Assert.True(model.HasRefreshError);
    }

    [Fact]
    public async Task GlobalRefreshFailureRetainsContentAndSelection()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.Results.Enqueue(Snapshot(profile, machines: [Machine("kept")]));
        repository.Results.Enqueue(new IOException("synthetic refresh"));
        using var model = new VirtualMachineManagerViewModel();
        await model.ActivateAsync(repository);
        model.SelectMachine(model.Machines.Single());

        await model.RefreshAsync();

        Assert.Equal("kept", Assert.Single(model.Machines).Name);
        Assert.Equal("kept", model.SelectedMachine?.Name);
        Assert.Equal(VirtualMachineManagerContentState.Content, model.MachinesState);
        Assert.True(model.HasRefreshError);
        Assert.False(model.IsLoading);
    }

    [Fact]
    public async Task ProfileSwitchCancelsOldGenerationAndRejectsLateSnapshot()
    {
        var profileA = Guid.NewGuid();
        var delayed = new TaskCompletionSource<VirtualMachineManagerSnapshot>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repositoryA = Available(profileA);
        repositoryA.Results.Enqueue(delayed.Task);
        var profileB = Guid.NewGuid();
        var repositoryB = Available(profileB);
        repositoryB.Results.Enqueue(Snapshot(profileB, machines: [Machine("b")]));
        using var model = new VirtualMachineManagerViewModel();

        var activationA = model.ActivateAsync(repositoryA);
        await WaitUntilAsync(() => repositoryA.Requests.Count == 1);
        var oldToken = repositoryA.Requests.Single();
        await model.ActivateAsync(repositoryB);
        delayed.SetResult(Snapshot(profileA, machines: [Machine("late-a")]));
        await activationA;

        Assert.True(oldToken.IsCancellationRequested);
        Assert.Equal(profileB, model.ActiveProfileId);
        Assert.Equal("b", Assert.Single(model.Machines).Name);
        Assert.False(model.IsLoading);
    }

    [Fact]
    public async Task ProfileCacheRestoresSelectionAndRefreshUsesNewRepositoryBinding()
    {
        var profileA = Guid.NewGuid();
        var firstA = Available(profileA);
        firstA.Results.Enqueue(Snapshot(profileA, machines: [Machine("a")]));
        var profileB = Guid.NewGuid();
        var repositoryB = Available(profileB);
        repositoryB.Results.Enqueue(Snapshot(profileB, machines: [Machine("b")]));
        var reboundA = Available(profileA);
        reboundA.Results.Enqueue(Snapshot(profileA, machines: [Machine("a-refreshed")]));
        using var model = new VirtualMachineManagerViewModel();

        await model.ActivateAsync(firstA);
        model.SelectMachine(model.Machines.Single());
        await model.ActivateAsync(repositoryB);
        await model.ActivateAsync(reboundA);

        Assert.Equal("a", model.SelectedMachine?.Name);
        Assert.Empty(reboundA.Requests);
        await model.RefreshAsync();
        Assert.Single(reboundA.Requests);
        Assert.Equal("a-refreshed", Assert.Single(model.Machines).Name);
    }

    [Fact]
    public async Task DisposeCancelsActiveRequestAndLateResultCannotWriteBack()
    {
        var profile = Guid.NewGuid();
        var delayed = new TaskCompletionSource<VirtualMachineManagerSnapshot>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = Available(profile);
        repository.Results.Enqueue(delayed.Task);
        var model = new VirtualMachineManagerViewModel();

        var activation = model.ActivateAsync(repository);
        await WaitUntilAsync(() => repository.Requests.Count == 1);
        var token = repository.Requests.Single();
        model.Dispose();
        delayed.SetResult(Snapshot(profile, machines: [Machine("late")]));
        await activation;

        Assert.True(token.IsCancellationRequested);
        Assert.Empty(model.Machines);
    }

    [Fact]
    public void DisplayModelsNeverExposeInternalIdsOrUnknownRawValues()
    {
        var machine = new VirtualMachineItem(new(
            "internal-vm-id",
            "",
            VirtualMachineOperationalState.Unknown,
            null,
            null,
            null,
            "internal-host-id",
            null));
        var resource = new VirtualizationResourceItem(new(
            "internal-resource-id",
            "",
            VirtualizationResourceKind.Image,
            VirtualizationResourceHealth.Unknown,
            Type: "private_raw_type"));

        Assert.DoesNotContain("internal-vm-id", machine.AutomationName, StringComparison.Ordinal);
        Assert.DoesNotContain("internal-host-id", machine.HostText, StringComparison.Ordinal);
        Assert.DoesNotContain("internal-resource-id", resource.AutomationName, StringComparison.Ordinal);
        Assert.DoesNotContain("private_raw_type", resource.AutomationName, StringComparison.Ordinal);
    }

    private static FakeRepository Available(Guid profileId) => new(profileId, available: true);

    private static VirtualMachineManagerSnapshot Snapshot(
        Guid profileId,
        IReadOnlyList<VirtualMachineSummary>? machines = null,
        IReadOnlyList<VirtualizationResourceSummary>? hosts = null) => new(
            profileId,
            VirtualMachineManagerSection<VirtualMachineSummary>.Available(machines ?? []),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available(hosts ?? []),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([]),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([]),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Available([]));

    private static VirtualMachineSummary Machine(string name) => new(
        $"id-{name}",
        name,
        VirtualMachineOperationalState.Running,
        2,
        2L * 1024 * 1024 * 1024,
        20L * 1024 * 1024 * 1024,
        "host-id",
        "Host");

    private static VirtualizationResourceSummary Resource(
        string name,
        VirtualizationResourceKind kind) => new(
            $"id-{name}",
            name,
            kind,
            VirtualizationResourceHealth.Healthy,
            1_024,
            2_048);

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 100 && !condition(); attempt++)
        {
            await Task.Delay(10);
        }
        Assert.True(condition());
    }

    private sealed class FakeRepository(
        Guid profileId,
        bool available,
        IReadOnlySet<VirtualMachineManagerReadFeature>? features = null)
        : IVirtualMachineManagerRepository
    {
        public Guid ProfileId { get; } = profileId;
        public VirtualMachineManagerAvailability Availability { get; } = new(
            available
                ? VirtualMachineManagerAvailabilityStatus.Available
                : VirtualMachineManagerAvailabilityStatus.Unavailable,
            available
                ? features ?? Enum.GetValues<VirtualMachineManagerReadFeature>().ToHashSet()
                : new HashSet<VirtualMachineManagerReadFeature>());
        public Queue<object> Results { get; } = new();
        public List<CancellationToken> Requests { get; } = [];

        public Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(
            CancellationToken cancellationToken = default)
        {
            Requests.Add(cancellationToken);
            return Results.Dequeue() switch
            {
                VirtualMachineManagerSnapshot snapshot => Task.FromResult(snapshot),
                Task<VirtualMachineManagerSnapshot> task => task,
                Exception error => Task.FromException<VirtualMachineManagerSnapshot>(error),
                var value => throw new InvalidOperationException(value.GetType().Name),
            };
        }
    }
}
