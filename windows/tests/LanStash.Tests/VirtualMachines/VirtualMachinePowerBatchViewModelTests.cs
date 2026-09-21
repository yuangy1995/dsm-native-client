using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachinePowerBatchViewModelTests
{
    [Theory]
    [InlineData(VirtualMachinePowerAction.PowerOn)]
    [InlineData(VirtualMachinePowerAction.Shutdown)]
    [InlineData(VirtualMachinePowerAction.PowerOff)]
    public async Task FullSelectionNeedsConfirmationAndRunsSerially(VirtualMachinePowerAction action)
    {
        var repository = new Repository(205, action); using var model = new VirtualMachineBatchViewModel(repository);
        await model.RefreshAsync(); model.SetAction(action); model.SelectAll();
        await model.SubmitAsync(); Assert.Empty(repository.Calls);
        model.Confirm(true); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(205, repository.Calls.Count); Assert.Equal(205, model.ConfirmedCount); Assert.Equal(0, model.NotStartedCount);
        Assert.Equal(1, repository.MaximumConcurrency);
        Assert.Equal(205, repository.Calls.Select(item => item.RequestId).Distinct().Count());
        Assert.All(repository.Calls, item => { Assert.True(item.RiskConfirmed); Assert.Equal(action, item.Action); Assert.Equal(repository.ProfileId, item.ProfileId); });
    }

    [Fact]
    public async Task ChangedLastTargetAbortsBeforeAnyWrite()
    {
        var repository = new Repository(205); using var model = new VirtualMachineBatchViewModel(repository);
        await model.RefreshAsync(); model.SelectAll(); model.Confirm(true);
        repository.Machines[^1] = repository.Machines[^1] with { Name = "changed" };
        await model.SubmitAsync(); Assert.Empty(repository.Calls);
        Assert.False(model.CanConfirm); Assert.Equal("VmBatchChanged", model.MessageKey);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task UnknownOrAuthenticationStopsAtTheAffectedItem(bool authentication)
    {
        var repository = new Repository(205) { StopAt = 23, Authentication = authentication }; using var model = new VirtualMachineBatchViewModel(repository);
        await model.RefreshAsync(); model.SelectAll(); model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(23, repository.Calls.Count); Assert.Equal(22, model.ConfirmedCount); Assert.Equal(182, model.NotStartedCount);
        Assert.Equal(authentication ? 0 : 1, model.UnknownCount); Assert.Equal(authentication ? 1 : 0, model.FailedCount);
        if (authentication) Assert.Equal("VmBatchSignIn", model.MessageKey);
        else
        {
            repository.Resolve = true; await model.ReviewAsync();
            Assert.Equal(23, repository.Calls.Count); Assert.Equal(23, model.ConfirmedCount); Assert.Equal(0, model.UnknownCount);
            Assert.Equal(182, model.NotStartedCount); Assert.False(model.CanSubmit);
        }
    }

    [Fact]
    public async Task ChangingSelectionOrActionInvalidatesConfirmation()
    {
        var repository = new Repository(2, VirtualMachinePowerAction.Shutdown); using var model = new VirtualMachineBatchViewModel(repository);
        await model.RefreshAsync(); model.SetAction(VirtualMachinePowerAction.Shutdown); model.SelectAll(); model.Confirm(true);
        model.SetAction(VirtualMachinePowerAction.PowerOff); Assert.False(model.CanSubmit);
        model.Confirm(true); model.Select(repository.Machines[0].Id, false); Assert.False(model.CanSubmit);
        await model.SubmitAsync(); Assert.Empty(repository.Calls);
    }

    [Fact]
    public async Task CancellingInFlightKeepsUnknownAndStopsRemaining()
    {
        var repository = new Repository(3) { Hold = new(TaskCreationOptions.RunContinuationsAsynchronously) }; using var model = new VirtualMachineBatchViewModel(repository);
        await model.RefreshAsync(); model.SelectAll(); model.Confirm(true); var work = model.SubmitAsync();
        await repository.Started.Task.WaitAsync(TimeSpan.FromSeconds(2)); model.Cancel();
        repository.Hold.SetResult(Unknown()); await work;
        Assert.True(repository.Token.IsCancellationRequested); Assert.Single(repository.Calls);
        Assert.Equal(1, model.UnknownCount); Assert.Equal(2, model.NotStartedCount); Assert.True(model.CanReview);
    }

    [Fact]
    public async Task DisposingIgnoresLateResultAndNeverRunsNextTarget()
    {
        var repository = new Repository(3) { Hold = new(TaskCreationOptions.RunContinuationsAsynchronously) }; using var model = new VirtualMachineBatchViewModel(repository);
        await model.RefreshAsync(); model.SelectAll(); model.Confirm(true); var work = model.SubmitAsync();
        await repository.Started.Task.WaitAsync(TimeSpan.FromSeconds(2)); model.Dispose(); repository.Hold.SetResult(Success()); await work;
        Assert.Single(repository.Calls); Assert.Equal(0, model.ConfirmedCount); Assert.False(model.CanSubmit);
    }

    [Fact]
    public async Task PendingOperationsAreReadOnlyAndRetainTheirOriginalAction()
    {
        var repository = new Repository(2) { Resolve = true };
        repository.Pending.Add(new(repository.Machines[0].Id, repository.Machines[0].Name, VirtualMachinePowerAction.PowerOff));
        using var model = new VirtualMachineBatchViewModel(repository); await model.RefreshAsync(); model.SelectAll(); Assert.Equal(1, model.SelectedCount);
        await model.ReviewAsync(); Assert.Empty(repository.Calls);
        Assert.Equal(VirtualMachineBatchAction.PowerOff, Assert.Single(model.Reviews).Target.Action);
        Assert.False(model.CanConfirm);
    }

    [Theory]
    [InlineData("readonly")]
    [InlineData("duplicate")]
    [InlineData("profile")]
    [InlineData("failed")]
    public async Task UnavailableOrInvalidSnapshotNeverEnablesWrites(string mode)
    {
        var repository = new Repository(2) { Mode = mode }; using var model = new VirtualMachineBatchViewModel(repository);
        await model.RefreshAsync(); model.SelectAll(); model.Confirm(true); await model.SubmitAsync();
        Assert.False(model.CanSubmit); Assert.Empty(repository.Calls);
    }

    private static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "virtualMachinePower", true, false, new(1, 0, 0));
    private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "virtualMachinePower", true, true, new(0, 0, 1));
    [Theory]
    [InlineData(1)]
    [InlineData(21)]
    [InlineData(205)]
    public async Task DeletionModeUsesCompleteConfirmedSelectionWithoutPowerCalls(int count)
    {
        var repository = new Repository(count); using var model = new VirtualMachineBatchViewModel(repository, deletion: true);
        await model.RefreshAsync(); model.SelectAll(); await model.SubmitAsync(); Assert.Empty(repository.Deletes);
        model.SetAction(VirtualMachinePowerAction.PowerOn); Assert.Equal(VirtualMachineBatchAction.Delete, model.Action);
        model.Confirm(true); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(count, model.ConfirmedCount); Assert.Equal(count, repository.Deletes.Count); Assert.Empty(repository.Calls);
        Assert.Equal(count, repository.Deletes.Select(item => item.RequestId).Distinct().Count());
        Assert.All(repository.Deletes, item => Assert.True(item.RiskConfirmed));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task DeletionStopsOnUnknownOrRejectionAndReviewDoesNotContinue(bool rejected)
    {
        var repository = new Repository(3) { StopAt = 2, RejectDelete = rejected };
        using var model = new VirtualMachineBatchViewModel(repository, deletion: true);
        await model.RefreshAsync(); model.SelectAll(); model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(2, repository.Deletes.Count); Assert.Equal(1, model.ConfirmedCount); Assert.Equal(1, model.NotStartedCount);
        Assert.Equal(rejected ? 1 : 0, model.FailedCount); Assert.Equal(rejected ? 0 : 1, model.UnknownCount);
        if (!rejected)
        {
            repository.Resolve = true; await model.ReviewAsync(); Assert.Equal(2, model.ConfirmedCount);
            Assert.Equal(2, repository.Deletes.Count); Assert.Equal(1, model.NotStartedCount);
        }
        Assert.Empty(repository.Calls);
    }

    [Fact]
    public async Task DeletionCannotSelectRunningMachinesOrReuseStaleConfirmation()
    {
        var repository = new Repository(3); repository.Machines[0] = repository.Machines[0] with { State = VirtualMachineOperationalState.Running };
        using var model = new VirtualMachineBatchViewModel(repository, deletion: true);
        await model.RefreshAsync(); model.SelectAll(); Assert.Equal(2, model.SelectedCount);
        model.Confirm(true); repository.Machines[^1] = repository.Machines[^1] with { Name = "changed" };
        await model.SubmitAsync(); Assert.Empty(repository.Deletes); Assert.Equal("VmBatchChanged", model.MessageKey);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(205)]
    public async Task ImageDeletionHasItsOwnTargetsAndDoesNotLoadOrDeleteMachines(int count)
    {
        var repository = new Repository(count) { Mode = "images-only" };
        using var model = new VirtualMachineBatchViewModel(repository, images: true);
        await model.RefreshAsync(); model.SelectAll(); Assert.Equal(count, model.SelectedCount);
        await model.SubmitAsync(); Assert.Empty(repository.ImageDeletes);
        model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(count, model.ConfirmedCount); Assert.Equal(count, repository.ImageDeletes.Count);
        Assert.Empty(repository.Deletes); Assert.Empty(repository.Calls);
        Assert.All(model.Results, item => { Assert.Null(item.Target.Machine); Assert.NotNull(item.Target.Image); });
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ImageUnknownOrRejectedStopsAndOnlyReviews(bool rejected)
    {
        var repository = new Repository(3) { Mode = "images-only", StopAt = 2, RejectDelete = rejected };
        using var model = new VirtualMachineBatchViewModel(repository, images: true);
        await model.RefreshAsync(); model.SelectAll(); model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(2, repository.ImageDeletes.Count); Assert.Equal(1, model.NotStartedCount);
        Assert.Equal(rejected ? 1 : 0, model.FailedCount); Assert.Equal(rejected ? 0 : 1, model.UnknownCount);
        if (!rejected) { repository.Resolve = true; await model.ReviewAsync(); Assert.Equal(2, model.ConfirmedCount); Assert.Equal(1, model.NotStartedCount); }
        Assert.Equal(2, repository.ImageDeletes.Count);
    }

    [Fact]
    public async Task ImageSelectionRejectsUnknownTypesAndChangedTailBeforeWriting()
    {
        var repository = new Repository(3) { Mode = "images-only" }; repository.Images[0] = repository.Images[0] with { Type = "future" };
        using var model = new VirtualMachineBatchViewModel(repository, images: true);
        await model.RefreshAsync(); model.SelectAll(); Assert.Equal(2, model.SelectedCount); model.Confirm(true);
        repository.Images[^1] = repository.Images[^1] with { Name = "changed" };
        await model.SubmitAsync(); Assert.Empty(repository.ImageDeletes); Assert.Equal("VmBatchChanged", model.MessageKey);
    }

    private sealed class Repository : IVirtualMachineManagerRepository
    {
        public Repository(int count, VirtualMachinePowerAction action = VirtualMachinePowerAction.PowerOn)
        { Machines = Enumerable.Range(0, count).Select(index => new VirtualMachineSummary($"vm-{index}", $"VM {index}",
            action == VirtualMachinePowerAction.PowerOn ? VirtualMachineOperationalState.Stopped : VirtualMachineOperationalState.Running, 2, 1024, null, null, null)).ToArray();
          Images = Enumerable.Range(0, count).Select(index => new VirtualizationResourceSummary($"image-{index}", $"Image {index}", VirtualizationResourceKind.Image, VirtualizationResourceHealth.Unknown, Type: "disk")).ToArray(); }
        public Guid ProfileId => Guid.Parse("11111111-1111-1111-1111-111111111111");
        public VirtualMachineManagerAvailability Availability => new(VirtualMachineManagerAvailabilityStatus.Available, new HashSet<VirtualMachineManagerReadFeature> { VirtualMachineManagerReadFeature.Machines });
        public bool CanControlPower => Mode != "readonly";
        public bool CanDeleteImages => Mode != "readonly";
        public VirtualizationResourceSummary[] Images;
        public List<VirtualMachineImageDeleteRequest> ImageDeletes { get; } = [];
        public List<VirtualMachineDeleteRecovery> ImagePending { get; } = [];
        public Task<IReadOnlyList<VirtualizationResourceSummary>> LoadImageDeletionTargetsAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualizationResourceSummary>>(Images.ToArray());
        public Task<IReadOnlyList<VirtualMachineDeleteRecovery>> GetImageDeletionRecoveriesAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualMachineDeleteRecovery>>(ImagePending.ToArray());
        public Task<MutationResult?> ReviewImageDeletionAsync(string id, CancellationToken token = default)
        { if (Resolve) ImagePending.RemoveAll(item => item.Id == id); return Task.FromResult<MutationResult?>(ImageResult(Resolve)); }
        public Task<MutationResult> DeleteImageAsync(VirtualMachineImageDeleteRequest request, CancellationToken token = default)
        {
            ImageDeletes.Add(request);
            if (ImageDeletes.Count != StopAt) return Task.FromResult(ImageResult(true));
            if (RejectDelete) return Task.FromResult(new MutationResult(1, MutationResultStatus.PermissionDenied, "virtualMachineImageDelete", true, true, new(0, 1, 0), MutationErrorCategory.Permission));
            ImagePending.Add(new(request.Baseline.Id, request.Baseline.Name)); return Task.FromResult(ImageResult(false));
        }
        private static MutationResult ImageResult(bool success) => new(1, success ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
            "virtualMachineImageDelete", true, !success, success ? new(1, 0, 0) : new(0, 0, 1));
        public bool CanDeleteMachines => Mode != "readonly";
        public List<VirtualMachineDeleteRequest> Deletes { get; } = [];
        public List<VirtualMachineDeleteRecovery> DeletionPending { get; } = [];
        public bool RejectDelete;
        public Task<IReadOnlyList<VirtualMachineDeleteRecovery>> GetDeletionRecoveriesAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualMachineDeleteRecovery>>(DeletionPending.ToArray());
        public Task<MutationResult?> ReviewDeletionAsync(string id, CancellationToken token = default)
        { if (Resolve) DeletionPending.RemoveAll(item => item.Id == id); return Task.FromResult<MutationResult?>(DeleteResult(Resolve)); }
        public Task<MutationResult> DeleteMachineAsync(VirtualMachineDeleteRequest request, CancellationToken token = default)
        {
            Deletes.Add(request);
            if (Deletes.Count != StopAt) return Task.FromResult(DeleteResult(true));
            if (RejectDelete) return Task.FromResult(new MutationResult(1, MutationResultStatus.PermissionDenied, "virtualMachineDelete", true, true, new(0, 1, 0), MutationErrorCategory.Permission));
            DeletionPending.Add(new(request.Baseline.Id, request.Baseline.Name)); return Task.FromResult(DeleteResult(false));
        }
        private static MutationResult DeleteResult(bool success) => new(1, success ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
            "virtualMachineDelete", true, !success, success ? new(1, 0, 0) : new(0, 0, 1));
        public VirtualMachineSummary[] Machines;
        public List<VirtualMachinePowerRequest> Calls { get; } = [];
        public List<VirtualMachinePowerRecovery> Pending { get; } = [];
        public string Mode = "";
        public int StopAt, MaximumConcurrency;
        private int _active;
        public bool Authentication, Resolve;
        public CancellationToken Token;
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<MutationResult>? Hold;
        public Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default) => Mode == "images-only" ? throw new InvalidOperationException("映像操作不得加载无关 VM 分区。") : Task.FromResult(new VirtualMachineManagerSnapshot(
            Mode == "profile" ? Guid.NewGuid() : ProfileId,
            new(Mode == "failed" ? VirtualMachineManagerSectionStatus.Failed : VirtualMachineManagerSectionStatus.Available, Mode == "duplicate" ? [Machines[0], Machines[0]] : Machines.ToArray()),
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable, VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable, VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable,
            VirtualMachineManagerSection<VirtualizationResourceSummary>.Unavailable, VirtualMachineManagerSection<ServiceEventSummary>.Unavailable));
        public Task<IReadOnlyList<VirtualMachinePowerRecovery>> GetPowerRecoveriesAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualMachinePowerRecovery>>(Pending.ToArray());
        public Task<MutationResult?> ReviewPowerAsync(string id, CancellationToken token = default)
        { if (Resolve) Pending.RemoveAll(item => item.Id == id); return Task.FromResult<MutationResult?>(Resolve ? Success() : Unknown()); }
        public async Task<MutationResult> ControlPowerAsync(VirtualMachinePowerRequest request, CancellationToken token = default)
        {
            Calls.Add(request); Token = token; Started.TrySetResult(); MaximumConcurrency = Math.Max(MaximumConcurrency, ++_active);
            try
            {
                await Task.Yield();
                if (Hold is not null) return await Hold.Task;
                if (Calls.Count != StopAt) return Success();
                if (Authentication) return new(1, MutationResultStatus.ConfirmedFailure, "virtualMachinePower", false, false, new(0, 1, 0), MutationErrorCategory.Authentication);
                Pending.Add(new(request.Baseline.Id, request.Baseline.Name, request.Action)); return Unknown();
            }
            finally { _active--; }
        }
    }
}
