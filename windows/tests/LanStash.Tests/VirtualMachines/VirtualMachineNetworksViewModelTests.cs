using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineNetworksViewModelTests
{
    [Theory]
    [InlineData(" ", "VmNetworkInvalidName")]
    [InlineData("network 1", "VmNetworkNameTaken")]
    public async Task InvalidOrDuplicateNameHasAnActionableValidationMessage(string name, string expected)
    {
        var repository = new Repository(2); using var model = new VirtualMachineNetworksViewModel(repository);
        await model.LoadAsync(); model.SetSelection(["net-0"]); model.SetName(name);
        Assert.Equal(expected, model.ValidationKey); model.SetConfirmed(true);
        Assert.False(model.CanSubmit); await model.SubmitAsync(); Assert.Empty(repository.Writes);
    }

    [Theory]
    [InlineData("selection")]
    [InlineData("name")]
    [InlineData("action")]
    public async Task ChangingInputsInvalidatesConfirmation(string change)
    {
        var repository = new Repository(2); using var model = new VirtualMachineNetworksViewModel(repository);
        await model.LoadAsync(); model.SetSelection(["net-0"]); model.SetName("Renamed"); model.SetConfirmed(true); Assert.True(model.CanSubmit);
        if (change == "selection") model.SetSelection(["net-1"]);
        else if (change == "name") model.SetName("Different");
        else model.SetAction(VirtualMachineNetworkAction.Delete);
        Assert.False(model.CanSubmit); await model.SubmitAsync(); Assert.Empty(repository.Writes);
    }

    [Fact]
    public async Task EntireLargeSelectionIsProcessedWithoutTruncation()
    {
        var repository = new Repository(205); using var model = new VirtualMachineNetworksViewModel(repository);
        await ConfirmAll(model); await model.SubmitAsync();
        Assert.Equal(205, repository.Writes.Count); Assert.Equal(205, model.Results.Count);
        Assert.All(model.Results, item => Assert.Equal(MutationResultStatus.ConfirmedSuccess, item.Result!.Status));
        Assert.False(model.CanConfirm); Assert.True(model.NeedsParentRefresh);
    }

    [Fact]
    public async Task ChangedTailStopsBeforeAnyWrite()
    {
        var repository = new Repository(205); using var model = new VirtualMachineNetworksViewModel(repository);
        await ConfirmAll(model); repository.Networks[^1] = repository.Networks[^1] with { Name = "Changed" };
        await model.SubmitAsync(); Assert.Empty(repository.Writes); Assert.Equal("VmNetworkChanged", model.MessageKey);
    }

    [Fact]
    public async Task UnknownStopsRemainingAndReviewOnlyReadsWhilePreservingPriorResults()
    {
        var repository = new Repository(5) { UnknownAt = 3 }; using var model = new VirtualMachineNetworksViewModel(repository);
        await ConfirmAll(model); await model.SubmitAsync();
        Assert.Equal(3, repository.Writes.Count); Assert.Equal(3, model.Results.Count); Assert.True(model.CanReview); Assert.False(model.CanConfirm);
        repository.Resolve = true; await model.ReviewAsync();
        Assert.Equal(3, repository.Writes.Count); Assert.Equal(3, model.Results.Count);
        Assert.All(model.Results, item => Assert.Equal(MutationResultStatus.ConfirmedSuccess, item.Result!.Status));
        Assert.Empty(model.Pending); Assert.False(model.CanConfirm);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AuthenticationResultOrExceptionStopsTheBatch(bool throws)
    {
        var repository = new Repository(5) { AuthAt = 2, ThrowAuth = throws }; using var model = new VirtualMachineNetworksViewModel(repository);
        await ConfirmAll(model); await model.SubmitAsync();
        Assert.Equal(2, repository.Writes.Count); Assert.True(model.RequiresReconnect); Assert.Equal("VmNetworkSignIn", model.MessageKey);
    }

    [Fact]
    public async Task CancellationBeforeSubmissionStartsNothing()
    {
        var repository = new Repository(2); using var model = new VirtualMachineNetworksViewModel(repository);
        await ConfirmAll(model); repository.BeforeRead = model.Cancel; await model.SubmitAsync();
        Assert.Empty(repository.Writes); Assert.Equal("VmNetworkStopped", model.MessageKey);
    }

    [Fact]
    public async Task DisposedLoadingPageIgnoresLateResponses()
    {
        var repository = new Repository(2) { ReadBarrier = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var model = new VirtualMachineNetworksViewModel(repository); var loading = model.LoadAsync();
        model.Dispose(); repository.ReadBarrier.SetResult(new(false, repository.Networks.ToArray())); await loading;
        Assert.Empty(model.Networks); Assert.False(model.CanEdit); Assert.Empty(repository.Writes);
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task FrozenOrReadOnlyInventoryDoesNotAllowConfirmation(bool frozen, bool readOnly)
    {
        var repository = new Repository(2) { Frozen = frozen, CanManageNetworks = !readOnly }; using var model = new VirtualMachineNetworksViewModel(repository);
        await ConfirmAll(model); Assert.False(model.CanSubmit); await model.SubmitAsync(); Assert.Empty(repository.Writes);
    }

    [Fact]
    public async Task FailureToLoadIsNotReportedAsAnEmptyInventory()
    {
        var repository = new Repository(2) { FailRead = true }; using var model = new VirtualMachineNetworksViewModel(repository);
        await model.LoadAsync(); Assert.Equal("VmNetworkLoadFailed", model.MessageKey); Assert.False(model.CanEdit);
    }

    private static async Task ConfirmAll(VirtualMachineNetworksViewModel model)
    { await model.LoadAsync(); model.SetAction(VirtualMachineNetworkAction.Delete); model.SetSelection(model.Networks.Select(item => item.Id)); model.SetConfirmed(true); }

    private sealed class Repository(int count) : IVirtualMachineManagerRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public VirtualMachineManagerAvailability Availability => new(VirtualMachineManagerAvailabilityStatus.Available, new HashSet<VirtualMachineManagerReadFeature> { VirtualMachineManagerReadFeature.Networks });
        public bool CanReadNetworkManagement => true;
        public bool CanManageNetworks { get; set; } = true;
        public bool Frozen, Resolve, ThrowAuth, FailRead;
        public int UnknownAt, AuthAt;
        public Action? BeforeRead;
        public TaskCompletionSource<VirtualMachineNetworkInventory>? ReadBarrier;
        public List<VirtualMachineNetwork> Networks { get; } = Enumerable.Range(0, count).Select(index => new VirtualMachineNetwork($"net-{index}", $"Network {index}", "external", "", 0, [new("host", "nic")], [])).ToList();
        public List<VirtualMachineNetworkRequest> Writes { get; } = [];
        public List<VirtualMachineNetworkRecovery> Pending { get; } = [];
        public Task<VirtualMachineNetworkInventory> LoadNetworkManagementAsync(CancellationToken token = default)
        {
            BeforeRead?.Invoke(); token.ThrowIfCancellationRequested();
            if (FailRead) throw new InvalidOperationException("synthetic");
            return ReadBarrier?.Task ?? Task.FromResult(new VirtualMachineNetworkInventory(Frozen, Networks.ToArray()));
        }
        public Task<MutationResult> MutateNetworkAsync(VirtualMachineNetworkRequest request, CancellationToken token = default)
        {
            Writes.Add(request);
            if (Writes.Count == AuthAt)
            {
                if (ThrowAuth) throw new DsmException("synthetic", "synthetic", 119);
                return Task.FromResult(new MutationResult(1, MutationResultStatus.ConfirmedFailure, "virtualMachineNetwork", true, true, new(0, 1, 0), MutationErrorCategory.Authentication));
            }
            if (Writes.Count == UnknownAt)
            {
                Pending.Add(new(request.Baseline.Id, request.Baseline.Name, request.Action));
                return Task.FromResult(new MutationResult(1, MutationResultStatus.SubmittedButUnverified, "virtualMachineNetwork", true, true, new(0, 0, 1)));
            }
            return Task.FromResult(Success());
        }
        public Task<IReadOnlyList<VirtualMachineNetworkRecovery>> GetNetworkRecoveriesAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualMachineNetworkRecovery>>(Pending.ToArray());
        public Task<MutationResult?> ReviewNetworkAsync(string id, CancellationToken token = default)
        { if (Resolve) Pending.RemoveAll(item => item.Id == id); return Task.FromResult<MutationResult?>(Resolve ? Success() : new(1, MutationResultStatus.SubmittedButUnverified, "virtualMachineNetwork", true, true, new(0, 0, 1))); }
        private static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "virtualMachineNetwork", true, false, new(1, 0, 0));
        public Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default) => throw new NotSupportedException();
    }
}
