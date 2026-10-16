using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineActivityViewModelTests
{
    [Fact]
    public async Task ActivityIsLoadedOnDemandAndFiltersBodyAccountAndLevel()
    {
        var repository = new Fake(); using var model = new VirtualMachineManagerViewModel();
        await model.ActivateAsync(repository);
        Assert.Equal(1, repository.Inventories); Assert.Equal(0, repository.Reads);
        await model.SetActivityVisibleAsync(true); Assert.Equal(2, model.Events.Count);
        model.SetActivityFilter("SECOND LINE", ServiceEventLevel.Warning); Assert.Single(model.Events);
        model.SetActivityFilter("other-account", null); Assert.Equal("b", Assert.Single(model.Events).Id);
        model.SetActivityFilter("missing", null); Assert.Empty(model.Events); Assert.Equal(VirtualMachineManagerContentState.FilteredEmpty, model.EventsState);
        model.SetActivityFilter("", null); Assert.Equal(2, model.Events.Count); Assert.Equal(1, repository.Reads);
        await model.SetActivityVisibleAsync(false); Assert.Empty(model.Events); Assert.Equal("", model.ActivitySearch);
        await model.SetActivityVisibleAsync(true); Assert.Equal(2, repository.Reads);
        model.Dispose(); Assert.Empty(model.Events); Assert.Equal("", model.ActivitySearch);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LeaveOrSameProfileReplacementDiscardsLateBody(bool rebind)
    {
        var repository = new Fake(); using var model = new VirtualMachineManagerViewModel(); await model.ActivateAsync(repository);
        var gate = new TaskCompletionSource<VirtualMachineManagerSection<ServiceActivityEntry>>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Next = _ => gate.Task;
        var reading = model.SetActivityVisibleAsync(true); var token = repository.Token;
        if (rebind) await model.ActivateAsync(new Fake { ProfileId = repository.ProfileId, Name = "replacement" });
        else await model.SetActivityVisibleAsync(false);
        Assert.True(token.IsCancellationRequested);
        gate.SetResult(Fake.Activity()); await reading;
        Assert.Empty(model.Events); Assert.False(model.IsActivityLoading);
        if (rebind) Assert.Equal("replacement", Assert.Single(model.Machines).Name);
    }

    [Fact]
    public async Task RefreshFailureKeepsPriorBodyRetryRecoversAndAuthenticationStopsRequests()
    {
        var repository = new Fake(); using var model = new VirtualMachineManagerViewModel();
        await model.ActivateAsync(repository); await model.SetActivityVisibleAsync(true);
        repository.Next = _ => Task.FromException<VirtualMachineManagerSection<ServiceActivityEntry>>(new IOException("合成读取失败。"));
        await model.RefreshAsync(); Assert.True(model.ActivityReadFailed); Assert.Equal(2, model.Events.Count);
        repository.Next = null; await model.RefreshAsync(); Assert.False(model.ActivityReadFailed); Assert.Equal(3, repository.Reads);
        repository.Next = _ => Task.FromException<VirtualMachineManagerSection<ServiceActivityEntry>>(new DsmException("synthetic", "synthetic", 119, authenticationFailure: true));
        await model.RefreshAsync(); Assert.True(model.RequiresReconnect); Assert.False(model.CanRefresh);
        await model.RefreshAsync(); Assert.Equal(4, repository.Reads); Assert.Equal(1, repository.Inventories);
    }

    private sealed class Fake : IVirtualMachineManagerRepository
    {
        public Guid ProfileId { get; init; } = Guid.NewGuid();
        public string Name { get; init; } = "original";
        public int Inventories, Reads;
        public CancellationToken Token;
        public Func<CancellationToken, Task<VirtualMachineManagerSection<ServiceActivityEntry>>>? Next;
        public VirtualMachineManagerAvailability Availability => new(VirtualMachineManagerAvailabilityStatus.Available,
            new HashSet<VirtualMachineManagerReadFeature> { VirtualMachineManagerReadFeature.Machines, VirtualMachineManagerReadFeature.Events });
        public Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default)
        {
            Inventories++;
            var empty = VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable;
            return Task.FromResult(new VirtualMachineManagerSnapshot(ProfileId,
                VirtualMachineManagerSection<VirtualMachineSummary>.Available([new("vm-a", Name, VirtualMachineOperationalState.Stopped, null, null, null, null, null)]),
                empty, empty, empty, empty, empty, VirtualMachineManagerSection<ServiceEventSummary>.Available([])));
        }
        public Task<VirtualMachineManagerSection<ServiceActivityEntry>> LoadActivityAsync(CancellationToken token = default)
        { Reads++; Token = token; return Next?.Invoke(token) ?? Task.FromResult(Activity()); }
        public static VirtualMachineManagerSection<ServiceActivityEntry> Activity() => VirtualMachineManagerSection<ServiceActivityEntry>.Available([
            new(new("a", null, ServiceEventLevel.Warning), "Synthetic <b>plain</b>\nsecond line", "synthetic-account", new DateTime(2026, 10, 16, 12, 30, 45)),
            new(new("b", null, ServiceEventLevel.Information), "another message", "other-account")]);
    }
}
