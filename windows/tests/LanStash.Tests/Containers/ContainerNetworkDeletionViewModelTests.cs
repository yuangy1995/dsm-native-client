using System.Reflection;
using LanStash.App.Features.Containers;
using LanStash.Domain;

namespace LanStash.Tests.Containers;

public sealed class ContainerNetworkDeletionViewModelTests
{
    private static readonly Guid Profile = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static ContainerResourceSummary Target(string id, string name) => new(id, name, ContainerResourceKind.Network, ContainerOperationalState.Unknown)
    { Network = new("bridge", 0, [], null, null, null, false) };
    private static async Task<(Fake Fake, ContainerNetworkDeletionViewModel Model)> Ready()
    {
        var repository = DispatchProxy.Create<IContainerManagerRepository, Fake>(); var fake = (Fake)repository;
        fake.Networks.Add(Target("a", "synthetic-a")); fake.Networks.Add(Target("b", "synthetic-b"));
        var model = new ContainerNetworkDeletionViewModel(); await model.ActivateAsync(repository); return (fake, model);
    }
    [Fact]
    public async Task ExactSelectionRequiresNewConfirmationAndSuccessDoesNotRepeat()
    {
        var (fake, model) = await Ready(); using var owned = model;
        model.SelectTargets([model.Items[0]]); await model.SubmitAsync(); Assert.Equal(0, fake.Writes);
        Assert.True(model.Confirm(true)); model.SelectTargets([model.Items[1]]); Assert.False(model.CanSubmit);
        model.Confirm(true); await model.SubmitAsync(); await model.SubmitAsync(); Assert.Equal(1, fake.Writes);
        Assert.Equal("b", Assert.Single(fake.LastRequest!.Baselines).Id); Assert.True(model.NeedsParentRefresh); Assert.False(model.CanSelect);
        await model.ReloadAsync(); Assert.Equal("a", Assert.Single(model.Items).Id); Assert.False(model.CanSubmit);
    }
    [Fact]
    public async Task SystemInUseAndUnknownNetworksAreExcludedAndForeignSelectionRejected()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Networks.Add(Target("system", "bridge")); fake.Networks.Add(Target("used", "used") with { Network = new("bridge", 1, ["connected"], null, null, null, false) });
        fake.Networks.Add(Target("unknown", "unknown") with { Network = null });
        await model.ReloadAsync(); Assert.Equal(2, model.Items.Count);
        model.SelectTargets([fake.Networks.Last()]); Assert.False(model.Confirm(true));
        model.SelectTargets([model.Items[0], model.Items[0]]); Assert.False(model.Confirm(true)); Assert.Equal(0, fake.Writes);
    }
    [Fact]
    public async Task ReadOnlyAndRevokedCapabilityCannotSubmit()
    {
        var (fake, model) = await Ready(); using var owned = model; model.SelectTargets([model.Items[0]]);
        fake.Writable = false; Assert.True(model.CanSelect); Assert.False(model.Confirm(true));
        fake.Writable = true; Assert.True(model.Confirm(true)); fake.Writable = false;
        await model.SubmitAsync(); Assert.Equal(0, fake.Writes);
    }
    [Fact]
    public async Task PartialBatchReloadOnlyReviewsAndKeepsUnknownTargetOutOfSelection()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Partial = true;
        model.SelectTargets(model.Items); model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(MutationResultStatus.PartialSuccess, model.LastResult!.Status); Assert.False(model.CanSubmit);
        await model.ReloadAsync(); Assert.Single(model.Pending); Assert.Empty(model.Items); Assert.Equal(1, fake.Writes);
        fake.Resolve = true; await model.ReloadAsync(); Assert.Empty(model.Pending); Assert.Empty(model.Items);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, model.LastResult!.Status); Assert.Equal(1, fake.Writes);
    }
    [Fact]
    public async Task LateResponseAfterProfileChangeIsIgnoredAndCloseCancels()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var completion = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = completion.Task;
        model.SelectTargets([model.Items[0]]); model.Confirm(true); var saving = model.SubmitAsync();
        await model.SubmitAsync(); await model.ReloadAsync(); Assert.Equal(1, fake.Writes);
        await model.ActivateAsync(DispatchProxy.Create<IContainerManagerRepository, Fake>()); Assert.True(fake.Token.IsCancellationRequested);
        completion.SetResult(Success(1)); await saving; Assert.Null(model.LastResult); Assert.False(model.NeedsParentRefresh);
    }
    [Fact]
    public async Task UnexpectedTransportExceptionDoesNotAllowReplayWhenRecoveryIsMissing()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.WriteTask = Task.FromException<MutationResult>(new IOException("合成回执丢失"));
        model.SelectTargets([model.Items[0]]); model.Confirm(true); await model.SubmitAsync(); await model.ReloadAsync();
        Assert.Equal("a", Assert.Single(model.Pending).Id); Assert.DoesNotContain(model.Items, item => item.Id == "a"); Assert.Equal(1, fake.Writes);
    }
    [Fact]
    public async Task FailedOrWrongProfileSnapshotCannotEnableSelection()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Failed = true;
        await model.ReloadAsync(); Assert.NotNull(model.ErrorMessage); Assert.False(model.CanSelect); Assert.Empty(model.Items);
        fake.Failed = false; fake.SnapshotProfile = Guid.NewGuid(); await model.ReloadAsync(); Assert.False(model.CanSelect);
        fake.SnapshotProfile = Profile; await model.ReloadAsync(); Assert.True(model.CanSelect);
    }
    private static MutationResult Success(int count) => new(1, MutationResultStatus.ConfirmedSuccess, "deleteContainerNetworks", true, false, new(count, 0, 0));
    public class Fake : DispatchProxy
    {
        public bool Writable { get; set; } = true;
        public bool Partial { get; set; } public bool Resolve { get; set; } public bool Failed { get; set; }
        public Guid SnapshotProfile { get; set; } = Profile;
        public List<ContainerResourceSummary> Networks { get; } = [];
        public List<ContainerNetworkDeletionRecovery> Pending { get; } = [];
        public int Writes { get; private set; } public CancellationToken Token { get; private set; }
        public ContainerNetworkDeleteRequest? LastRequest { get; private set; }
        public Task<MutationResult>? WriteTask { get; set; }
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_ProfileId": return Profile;
                case "get_CanDeleteNetworks": return Writable;
                case "PrepareNetworkManagementAsync": return Task.CompletedTask;
                case "GetNetworkDeletionRecoveriesAsync": return Task.FromResult<IReadOnlyList<ContainerNetworkDeletionRecovery>>(Pending.ToArray());
                case "ReviewNetworkDeletionAsync":
                    if (Pending.Count == 0) return Task.FromResult<MutationResult?>(null);
                    if (Resolve) { Networks.Clear(); Pending.Clear(); return Task.FromResult<MutationResult?>(Success(2)); }
                    return Task.FromResult<MutationResult?>(new(1, MutationResultStatus.PartialSuccess, "deleteContainerNetworks", true, true, new(1, 0, 1)));
                case "LoadSnapshotAsync": return Task.FromResult(new ContainerManagerSnapshot(SnapshotProfile,
                    ContainerManagerSection<ContainerSummary>.Available([]), ContainerManagerSection<ContainerResourceSummary>.Available([]),
                    Failed ? ContainerManagerSection<ContainerResourceSummary>.Failed : ContainerManagerSection<ContainerResourceSummary>.Available(Networks.ToArray()),
                    ContainerManagerSection<ContainerResourceSummary>.Available([]), ContainerManagerSection<ServiceEventSummary>.Available([])));
                case "DeleteNetworksAsync":
                    LastRequest = (ContainerNetworkDeleteRequest)args![0]!; Writes++; Token = (CancellationToken)args[1]!;
                    if (WriteTask is not null) return WriteTask;
                    var targets = LastRequest.Baselines;
                    foreach (var target in targets.Take(Partial ? 1 : targets.Count)) Networks.RemoveAll(item => item.Id == target.Id);
                    if (!Partial) return Task.FromResult(Success(targets.Count));
                    foreach (var target in targets.Skip(1)) Pending.Add(new(target.Id, target.Name));
                    return Task.FromResult(new MutationResult(1, MutationResultStatus.PartialSuccess, "deleteContainerNetworks", true, true, new(1, 0, targets.Count - 1)));
                default: throw new NotSupportedException(method.Name);
            }
        }
    }
}
