using LanStash.App.Features.Containers;
using LanStash.Domain;

namespace LanStash.Tests.Containers;

public sealed class ContainerMutationViewModelTests
{
    [Fact]
    public async Task RestartingTargetsAppearOnlyForStopAndRestart()
    {
        var repository = new Repository(); repository.Containers.Clear();
        repository.Containers.Add(new("looping", "Restarting service", ContainerOperationalState.Restarting, null));
        using var browser = new ContainerManagerViewModel(); await browser.ActivateAsync(repository);
        browser.SetFilter(ContainerManagerFilter.Running);
        var visible = Assert.Single(browser.Containers);
        Assert.Equal(ContainerOperationalState.Restarting, visible.State);
        Assert.Equal(LanStash.App.Localization.LocalizationService.Current.Get("ContainerManagerStatusRestarting"), visible.StatusText);
        using var model = new ContainerMutationViewModel(); await model.ActivateAsync(repository);
        Assert.Empty(model.Items);
        model.SetAction(ContainerMutationAction.Delete); Assert.Empty(model.Items);
        model.SetAction(ContainerMutationAction.Stop); Assert.Single(model.Items);
        model.SelectTargets(model.Items.ToArray()); Assert.True(model.Confirm(true));
        model.SetAction(ContainerMutationAction.Restart); Assert.Single(model.Items); Assert.False(model.CanSubmit);
    }
    [Theory]
    [InlineData(ContainerMutationAction.Start)]
    [InlineData(ContainerMutationAction.Stop)]
    [InlineData(ContainerMutationAction.Restart)]
    [InlineData(ContainerMutationAction.Delete)]
    public async Task BatchConfirmsSnapshotsOnceAndRequiresFreshSelectionAfterwards(ContainerMutationAction action)
    {
        var repository = new Repository(action is ContainerMutationAction.Stop or ContainerMutationAction.Restart);
        using var model = new ContainerMutationViewModel(); await model.ActivateAsync(repository); model.SetAction(action);
        model.SelectTargets(model.Items.ToArray());
        await model.SubmitAsync(); Assert.Empty(repository.Writes);
        Assert.True(model.Confirm(true)); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(3, repository.Writes.Count);
        Assert.Equal(3, repository.Writes.Select(request => request.RequestId).Distinct().Count());
        Assert.All(repository.Writes, request => { Assert.True(request.RiskConfirmed); Assert.Equal(action, request.Action); Assert.Equal(repository.ProfileId, request.ProfileId); });
        Assert.True(model.AllSucceeded); Assert.False(model.CanSubmit); Assert.True(model.NeedsParentRefresh); Assert.True(model.CanSelect);
        await model.ReloadAsync(); Assert.False(model.CanSubmit);
    }

    [Fact]
    public async Task QueryActionSelectionAndReloadInvalidateConfirmation()
    {
        var repository = new Repository(); using var model = new ContainerMutationViewModel(); await model.ActivateAsync(repository);
        model.SelectTargets(model.Items.ToArray()); model.Confirm(true); model.SetQuery("sample-1"); Assert.False(model.CanSubmit);
        model.SelectTargets(model.Items.ToArray()); model.Confirm(true); model.SetAction(ContainerMutationAction.Delete); Assert.False(model.CanSubmit);
        model.SelectTargets(model.Items.ToArray()); model.Confirm(true); model.SelectTargets([]); Assert.False(model.CanSubmit);
        model.SelectTargets(model.Items.ToArray()); model.Confirm(true); await model.ReloadAsync(); Assert.False(model.CanSubmit);
        Assert.Empty(repository.Writes);
    }

    [Fact]
    public async Task UnknownStopsBatchAndRefreshOnlyReviewsUntilUserConfirmsRemainingTargets()
    {
        var repository = new Repository { Unknown = true }; using var model = new ContainerMutationViewModel(); await model.ActivateAsync(repository);
        model.SelectTargets(model.Items.ToArray()); model.Confirm(true); await model.SubmitAsync();
        Assert.Single(repository.Writes); Assert.Single(model.Pending); Assert.Equal(2, model.Results.Count(row => row.Result is null));
        await model.ReloadAsync(); Assert.Single(repository.Writes); Assert.Equal(2, model.Items.Count);
        repository.ReviewCompletes = true; await model.ReloadAsync();
        Assert.Single(repository.Writes); Assert.Empty(model.Pending); Assert.False(model.CanSubmit);
        repository.Unknown = false; model.SelectTargets(model.Items.ToArray()); model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(3, repository.Writes.Count); Assert.True(model.AllSucceeded);
    }

    [Fact]
    public async Task OnePermissionRejectionDoesNotHideOtherResults()
    {
        var repository = new Repository { DenyFirst = true }; using var model = new ContainerMutationViewModel(); await model.ActivateAsync(repository);
        model.SelectTargets(model.Items.ToArray()); model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(3, repository.Writes.Count); Assert.False(model.AllSucceeded);
        Assert.Equal(2, model.Results.Count(row => row.Result?.Status == MutationResultStatus.ConfirmedSuccess));
        Assert.Single(model.Results, row => row.Result?.Status == MutationResultStatus.PermissionDenied);
    }

    [Fact]
    public async Task ClosedWindowCancelsWaitAndReopenedModelFindsPendingWithoutResubmitting()
    {
        var repository = new Repository { WriteGate = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var model = new ContainerMutationViewModel(); await model.ActivateAsync(repository);
        model.SelectTargets(model.Items.ToArray()); model.Confirm(true); var saving = model.SubmitAsync();
        await repository.WriteStarted.Task; model.Dispose(); await saving;
        Assert.True(repository.WriteToken.IsCancellationRequested); Assert.Empty(model.Results);
        using var reopened = new ContainerMutationViewModel(); await reopened.ActivateAsync(repository);
        Assert.Single(reopened.Pending); Assert.Single(repository.Writes); Assert.False(reopened.CanSubmit);
    }

    [Fact]
    public async Task LateOldProfileSnapshotCannotReplaceCurrentProfile()
    {
        var old = new Repository { LoadGate = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var current = new Repository(); current.Containers.Clear(); current.Containers.Add(new("new", "new profile item", ContainerOperationalState.Stopped, null));
        using var model = new ContainerMutationViewModel(); var loading = model.ActivateAsync(old); await old.LoadStarted.Task;
        await model.ActivateAsync(current); old.LoadGate.SetResult(old.Snapshot()); await loading;
        Assert.Equal("new", Assert.Single(model.Items).Id); Assert.True(old.LoadToken.IsCancellationRequested); Assert.Null(model.ErrorMessage);
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task ReadOnlyOrWrongProfileCannotSubmit(bool readOnly, bool wrongProfile)
    {
        var repository = new Repository { CanMutateContainers = !readOnly, WrongProfile = wrongProfile };
        using var model = new ContainerMutationViewModel(); await model.ActivateAsync(repository);
        model.SelectTargets(model.Items.ToArray()); Assert.False(model.Confirm(true)); await model.SubmitAsync(); Assert.Empty(repository.Writes);
        if (wrongProfile) Assert.NotNull(model.ErrorMessage);
    }

    private sealed class Repository(bool running = false) : IContainerManagerRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public bool CanMutateContainers { get; init; } = true;
        public ContainerManagerAvailability Availability => new(ContainerManagerAvailabilityStatus.InternalObserved, new HashSet<ContainerManagerReadFeature> { ContainerManagerReadFeature.Containers });
        public List<ContainerSummary> Containers { get; } = Enumerable.Range(1, 3).Select(id => new ContainerSummary($"c-{id}", $"sample-{id}", running ? ContainerOperationalState.Running : ContainerOperationalState.Stopped, null)).ToList();
        public List<ContainerMutationRequest> Writes { get; } = [];
        private readonly Dictionary<Guid, ContainerMutationRequest> _pending = [];
        public bool Unknown { get; set; }
        public bool ReviewCompletes { get; set; }
        public bool DenyFirst { get; init; }
        public bool WrongProfile { get; init; }
        public TaskCompletionSource? WriteGate { get; init; }
        public TaskCompletionSource<ContainerManagerSnapshot>? LoadGate { get; init; }
        public TaskCompletionSource WriteStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource LoadStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationToken WriteToken { get; private set; }
        public CancellationToken LoadToken { get; private set; }
        public ContainerManagerSnapshot Snapshot() => new(WrongProfile ? Guid.NewGuid() : ProfileId, ContainerManagerSection<ContainerSummary>.Available(Containers.ToArray()),
            ContainerManagerSection<ContainerResourceSummary>.Unavailable, ContainerManagerSection<ContainerResourceSummary>.Unavailable,
            ContainerManagerSection<ContainerResourceSummary>.Unavailable, ContainerManagerSection<ServiceEventSummary>.Unavailable);
        public Task<ContainerManagerSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default)
        { LoadToken = cancellationToken; LoadStarted.TrySetResult(); return LoadGate?.Task ?? Task.FromResult(Snapshot()); }
        public Task<IReadOnlyList<ContainerMutationRecovery>> GetContainerMutationRecoveriesAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<ContainerMutationRecovery>>(_pending.Values.Select(request => new ContainerMutationRecovery(request.RequestId, request.Baseline, request.Action)).ToArray());
        public Task<MutationResult?> ReviewContainerMutationAsync(Guid requestId, CancellationToken cancellationToken = default)
        {
            if (!_pending.TryGetValue(requestId, out var request)) return Task.FromResult<MutationResult?>(null);
            if (!ReviewCompletes) return Task.FromResult<MutationResult?>(Result(MutationResultStatus.SubmittedButUnverified));
            _pending.Remove(requestId); Apply(request); return Task.FromResult<MutationResult?>(Result(MutationResultStatus.ConfirmedSuccess));
        }
        public async Task<MutationResult> MutateContainerAsync(ContainerMutationRequest request, CancellationToken cancellationToken = default)
        {
            Writes.Add(request); WriteToken = cancellationToken; _pending.Add(request.RequestId, request); WriteStarted.TrySetResult();
            if (WriteGate is not null) await WriteGate.Task.WaitAsync(cancellationToken);
            if (Unknown) return Result(MutationResultStatus.SubmittedButUnverified);
            _pending.Remove(request.RequestId);
            if (DenyFirst && request.Baseline.Id == "c-1") return new(1, MutationResultStatus.PermissionDenied, "containerMutation", true, true, new(0, 1, 0), MutationErrorCategory.Permission);
            Apply(request); return Result(MutationResultStatus.ConfirmedSuccess);
        }
        private void Apply(ContainerMutationRequest request)
        {
            var item = Containers.FirstOrDefault(item => item.Id == request.Baseline.Id); if (item is null) return;
            if (request.Action == ContainerMutationAction.Delete) Containers.Remove(item);
            else Containers[Containers.IndexOf(item)] = item with { State = request.Action == ContainerMutationAction.Stop ? ContainerOperationalState.Stopped : ContainerOperationalState.Running };
        }
        private static MutationResult Result(MutationResultStatus status) => new(1, status, "containerMutation", true, true,
            status == MutationResultStatus.ConfirmedSuccess ? new(1, 0, 0) : new(0, 0, 1));
    }
}
