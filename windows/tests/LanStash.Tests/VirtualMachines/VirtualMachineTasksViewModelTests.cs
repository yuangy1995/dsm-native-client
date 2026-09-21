using System.Reflection;
using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;
using LanStash.Tests.Chat;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineTasksViewModelTests
{
    private static IVirtualMachineManagerRepository Repository() => DispatchProxy.Create<IVirtualMachineManagerRepository, Fake>();
    private static VirtualMachineTaskSummary Running => new("safe-key", VirtualMachineTaskState.Running, 30);
    [Fact]
    public async Task PollsOnlyWhileVisibleAndUnfinishedThenStops()
    {
        var time = new ManualRefreshTimeProvider(); var repository = Repository(); var fake = (Fake)repository;
        using var model = new VirtualMachineTasksViewModel(time); await model.ActivateAsync(repository);
        Assert.Equal(1, time.ActiveTimers); var initial = Assert.Single(model.Tasks);
        time.Advance(TimeSpan.FromSeconds(2)); await Until(() => fake.Calls == 2 && !model.IsLoading);
        Assert.Same(initial, Assert.Single(model.Tasks));
        fake.Values = [Running with { State = VirtualMachineTaskState.Finished, ProgressPercent = 100 }];
        time.Advance(TimeSpan.FromSeconds(2)); await Until(() => fake.Calls == 3 && !model.IsLoading);
        Assert.Equal(0, time.ActiveTimers); Assert.Equal(VirtualMachineTaskState.Finished, Assert.Single(model.Tasks).Task.State);
        time.Advance(TimeSpan.FromSeconds(10)); Assert.Equal(3, fake.Calls);
    }
    [Fact]
    public async Task ManualRefreshThatEndsAllTasksDoesNotLeaveAnExtraScheduledRead()
    {
        var time = new ManualRefreshTimeProvider(); var repository = Repository(); var fake = (Fake)repository;
        using var model = new VirtualMachineTasksViewModel(time); await model.ActivateAsync(repository);
        fake.Values = [Running with { State = VirtualMachineTaskState.Finished }]; await model.RefreshAsync();
        Assert.Equal(2, fake.Calls); time.Advance(TimeSpan.FromSeconds(2)); await Task.Delay(30);
        Assert.Equal(2, fake.Calls); Assert.Equal(0, time.ActiveTimers);
    }
    [Fact]
    public async Task HideStopsTimerAndReturnRefreshesEvenFinishedList()
    {
        var time = new ManualRefreshTimeProvider(); var repository = Repository(); var fake = (Fake)repository;
        using var model = new VirtualMachineTasksViewModel(time); await model.ActivateAsync(repository);
        await model.SetVisibleAsync(false); Assert.Equal(0, time.ActiveTimers); Assert.False(model.CanRefresh);
        time.Advance(TimeSpan.FromSeconds(10)); Assert.Equal(1, fake.Calls);
        fake.Values = []; await model.SetVisibleAsync(true); Assert.Equal(2, fake.Calls); Assert.Empty(model.Tasks); Assert.Equal(0, time.ActiveTimers);
    }
    [Fact]
    public async Task HiddenOrSwitchedLateReadCannotOverwriteNewProfile()
    {
        var repository = Repository(); var fake = (Fake)repository;
        var waiting = new TaskCompletionSource<IReadOnlyList<VirtualMachineTaskSummary>>(TaskCreationOptions.RunContinuationsAsynchronously); fake.Pending = waiting.Task;
        using var model = new VirtualMachineTasksViewModel(); var opening = model.ActivateAsync(repository);
        await model.RefreshAsync(); Assert.Equal(1, fake.Calls);
        await model.SetVisibleAsync(false); Assert.True(fake.Token.IsCancellationRequested);
        var next = Repository(); ((Fake)next).Values = [];
        await model.ActivateAsync(next); waiting.SetResult([Running]); await opening;
        Assert.Empty(model.Tasks); Assert.True(model.HasLoaded); Assert.False(model.IsLoading);
    }
    [Fact]
    public async Task TransientFailureRetainsRowsAndManualRetryRecovers()
    {
        var repository = Repository(); var fake = (Fake)repository;
        using var model = new VirtualMachineTasksViewModel(new ManualRefreshTimeProvider()); await model.ActivateAsync(repository);
        var previous = Assert.Single(model.Tasks); fake.Error = new IOException("synthetic"); await model.RefreshAsync();
        Assert.True(model.HasError); Assert.Same(previous, Assert.Single(model.Tasks)); Assert.True(model.CanRefresh);
        fake.Error = null; await model.RefreshAsync(); Assert.False(model.HasError); Assert.Same(previous, Assert.Single(model.Tasks));
    }
    [Fact]
    public async Task AuthenticationClearsPrivateStateAndRequiresReactivation()
    {
        var time = new ManualRefreshTimeProvider(); var repository = Repository(); var fake = (Fake)repository;
        using var model = new VirtualMachineTasksViewModel(time); await model.ActivateAsync(repository);
        fake.Error = new DsmException("synthetic", "synthetic", 119); await model.RefreshAsync();
        Assert.True(model.RequiresReconnect); Assert.Empty(model.Tasks); Assert.False(model.CanRefresh);
        fake.Error = null; await model.RefreshAsync(); Assert.Equal(2, fake.Calls);
        await model.ActivateAsync(repository); Assert.False(model.RequiresReconnect); Assert.Single(model.Tasks);
    }
    [Fact]
    public async Task MissingCapabilityAndInitialErrorNeverPretendToBeEmptySuccess()
    {
        var repository = Repository(); var fake = (Fake)repository; fake.Available = false;
        using var model = new VirtualMachineTasksViewModel(); await model.ActivateAsync(repository);
        Assert.True(model.IsUnavailable); Assert.False(model.HasLoaded); Assert.Equal(0, fake.Calls);
        fake.Available = true; fake.Error = new IOException("synthetic"); await model.RefreshAsync(); Assert.True(model.HasError); Assert.False(model.HasLoaded);
        fake.Error = null; fake.Values = []; await model.RefreshAsync(); Assert.True(model.HasLoaded); Assert.False(model.HasError);
    }
    [Fact]
    public async Task IndividualReadFailureContinuesPollingWithoutExposingKey()
    {
        var time = new ManualRefreshTimeProvider(); var repository = Repository(); var fake = (Fake)repository;
        fake.Values = [new("hidden-identifier", VirtualMachineTaskState.ReadFailed, null)];
        using var model = new VirtualMachineTasksViewModel(time); await model.ActivateAsync(repository);
        Assert.True(model.HasReadFailures); Assert.Equal(1, time.ActiveTimers);
        Assert.DoesNotContain("hidden-identifier", Assert.Single(model.Tasks).Title);
        model.Dispose(); Assert.Equal(0, time.ActiveTimers); await model.RefreshAsync(); Assert.Equal(1, fake.Calls);
    }
    private static async Task Until(Func<bool> condition)
    { for (var i = 0; i < 100 && !condition(); i++) await Task.Delay(10); Assert.True(condition()); }
    public class Fake : DispatchProxy
    {
        public bool Available = true;
        public int Calls;
        public Exception? Error;
        public CancellationToken Token;
        public IReadOnlyList<VirtualMachineTaskSummary> Values = [Running];
        public Task<IReadOnlyList<VirtualMachineTaskSummary>>? Pending;
        protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
        { "get_CanReadTasks" => Available, "get_CanClearTasks" => false, "LoadVirtualMachineTasksAsync" => Load((CancellationToken)args![0]!), _ => throw new NotSupportedException(method.Name) };
        private Task<IReadOnlyList<VirtualMachineTaskSummary>> Load(CancellationToken token)
        { Calls++; Token = token; return Pending ?? (Error is null ? Task.FromResult(Values) : Task.FromException<IReadOnlyList<VirtualMachineTaskSummary>>(Error)); }
    }
}
