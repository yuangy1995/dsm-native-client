using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineTaskCleanupViewModelTests
{
    [Fact]
    public async Task ConfirmationFreezesOnlyUnprotectedFinishedTasks()
    {
        var repository = new Repository(); using var model = new VirtualMachineTasksViewModel(); await model.ActivateAsync(repository);
        await model.SubmitCleanupAsync(); Assert.Equal(0, repository.Writes);
        var request = model.BeginCleanupConfirmation(); Assert.NotNull(request); Assert.False(request.RiskConfirmed);
        Assert.Equal(["finished"], request.Keys); Assert.False(model.CanRefresh);
        repository.Tasks.Add(new("later", VirtualMachineTaskState.Finished, 100));
        await model.SubmitCleanupAsync(); await model.SubmitCleanupAsync();
        Assert.Equal(1, repository.Writes); Assert.True(repository.Last!.RiskConfirmed); Assert.Equal(["finished"], repository.Last.Keys);
        model.EndCleanupConfirmation(); await model.RefreshAsync(); Assert.True(model.CanPrepareCleanup);
    }
    [Fact]
    public async Task ClosingPendingConfirmationDiscardsLateReplyAndReopensReadOnlyRecovery()
    {
        var repository = new Repository { Waiting = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var model = new VirtualMachineTasksViewModel(); await model.ActivateAsync(repository); model.BeginCleanupConfirmation();
        var work = model.SubmitCleanupAsync(); model.EndCleanupConfirmation();
        repository.Waiting.SetResult(new(1, 0, 0, 1, 0)); await work;
        Assert.True(repository.Token.IsCancellationRequested); Assert.Null(model.LastCleanup);
        Assert.True(model.CanReviewCleanup); repository.Resolve = true; await model.ReviewCleanupAsync();
        Assert.Equal(1, repository.Writes); Assert.Equal(1, model.LastCleanup!.ClearedCount); Assert.Empty(model.CleanupRecoveries);
    }
    [Fact]
    public async Task HiddenPageCannotApplyLateCleanupOrKeepPolling()
    {
        var repository = new Repository { Waiting = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var model = new VirtualMachineTasksViewModel(); await model.ActivateAsync(repository); model.BeginCleanupConfirmation();
        var work = model.SubmitCleanupAsync(); await model.SetVisibleAsync(false);
        repository.Waiting.SetResult(new(1, 1, 0, 0, 0)); await work;
        Assert.True(repository.Token.IsCancellationRequested); Assert.Null(model.LastCleanup); Assert.False(model.CanRefresh);
    }
    [Fact]
    public async Task ReadonlyAndProtectedOnlyListsCannotPrepareCleanup()
    {
        var repository = new Repository { Writable = false }; using var model = new VirtualMachineTasksViewModel(); await model.ActivateAsync(repository);
        Assert.Null(model.BeginCleanupConfirmation()); repository.Writable = true; repository.Tasks.RemoveAll(item => !item.IsProtected);
        await model.RefreshAsync(); Assert.False(model.CanPrepareCleanup); Assert.Null(model.BeginCleanupConfirmation()); Assert.Equal(0, repository.Writes);
    }
    private sealed class Repository : IVirtualMachineManagerRepository
    {
        public Guid ProfileId => Guid.Parse("11111111-1111-1111-1111-111111111111");
        public VirtualMachineManagerAvailability Availability => new(VirtualMachineManagerAvailabilityStatus.Available, new HashSet<VirtualMachineManagerReadFeature>());
        public bool CanReadTasks => true;
        public bool CanClearTasks => Writable;
        public bool Writable = true, Resolve;
        public List<VirtualMachineTaskSummary> Tasks = [new("finished", VirtualMachineTaskState.Finished, 100), new("running", VirtualMachineTaskState.Running, 50), new("protected", VirtualMachineTaskState.Finished, 100) { IsProtected = true }];
        public VirtualMachineTaskCleanupRequest? Last; public int Writes; public CancellationToken Token;
        public TaskCompletionSource<VirtualMachineTaskCleanupResult>? Waiting;
        private Guid? _pending;
        public Task<IReadOnlyList<VirtualMachineTaskSummary>> LoadVirtualMachineTasksAsync(CancellationToken token = default) => Task.FromResult<IReadOnlyList<VirtualMachineTaskSummary>>(Tasks.ToArray());
        public Task<VirtualMachineTaskCleanupResult> ClearFinishedTasksAsync(VirtualMachineTaskCleanupRequest request, CancellationToken token = default)
        { Last = request; Writes++; Token = token; if (Waiting is not null) _pending = request.RequestId; return Waiting?.Task ?? Task.FromResult(new VirtualMachineTaskCleanupResult(request.Keys.Count, request.Keys.Count, 0, 0, 0)); }
        public Task<IReadOnlyList<VirtualMachineTaskCleanupRecovery>> GetTaskCleanupRecoveriesAsync(CancellationToken token = default) =>
            Task.FromResult<IReadOnlyList<VirtualMachineTaskCleanupRecovery>>(_pending is { } id ? [new(id, 1)] : []);
        public Task<VirtualMachineTaskCleanupResult?> ReviewTaskCleanupAsync(Guid id, CancellationToken token = default)
        { if (Resolve) _pending = null; return Task.FromResult<VirtualMachineTaskCleanupResult?>(Resolve ? new(1, 1, 0, 0, 0) : new(1, 0, 0, 1, 0)); }
        public Task<VirtualMachineManagerSnapshot> LoadSnapshotAsync(CancellationToken token = default) => throw new NotSupportedException();
    }
}
