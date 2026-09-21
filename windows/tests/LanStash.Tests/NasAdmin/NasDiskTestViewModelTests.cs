using System.Reflection;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDiskTestViewModelTests
{
    private static async Task<(Fake Fake, NasDiskTestViewModel Model)> Ready()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        var model = new NasDiskTestViewModel(); await model.ActivateAsync(repository); await model.SelectAsync(model.Disks[0]); return (fake, model);
    }
    [Theory]
    [InlineData(NasDiskTestCommand.Quick)] [InlineData(NasDiskTestCommand.Extended)] [InlineData(NasDiskTestCommand.Stop)]
    public async Task CommandsNeedCurrentSelectionAndExplicitConfirmation(NasDiskTestCommand command)
    {
        var (fake, model) = await Ready(); using var owned = model;
        if (command == NasDiskTestCommand.Stop) { fake.Running = true; await model.RefreshStateAsync(); }
        model.Choose(command); await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
        Assert.True(model.Confirm(true)); await model.ExecuteAsync(); await model.ExecuteAsync();
        Assert.Equal(1, fake.Writes); Assert.True(model.WasSuccessful); Assert.Equal(command, fake.Sent!.Command);
        Assert.Equal(command != NasDiskTestCommand.Stop, model.State!.IsRunning);
    }
    [Fact]
    public async Task HistoryIsExplicitAndFailureDoesNotInventAnIdleState()
    {
        var (fake, model) = await Ready(); using var owned = model;
        Assert.Equal(0, fake.HistoryReads); Assert.Null(model.History);
        fake.HistoryFails = true; await model.LoadHistoryAsync(); Assert.NotNull(model.HistoryError); Assert.Null(model.History);
        Assert.NotNull(model.State); Assert.True(model.CanChoose(NasDiskTestCommand.Quick));
        fake.HistoryFails = false; await model.LoadHistoryAsync(); Assert.Empty(model.History!.Entries); Assert.Null(model.HistoryError);
    }
    [Fact]
    public async Task SearchSelectionAndCapabilityChangesInvalidateConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model;
        model.Choose(NasDiskTestCommand.Quick); Assert.True(model.Confirm(true)); model.SetSearch("no-match");
        Assert.Null(model.Selected); Assert.Null(model.State); Assert.False(model.CanExecute);
        model.SetSearch(""); await model.SelectAsync(model.Disks[0]); model.Choose(NasDiskTestCommand.Quick); model.Confirm(true);
        fake.Available = false; await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
    }
    [Fact]
    public async Task LateStateAfterSelectionChangeCannotPopulateAnotherDisk()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var complete = new TaskCompletionSource<NasDiskTestState>(TaskCreationOptions.RunContinuationsAsynchronously);
        fake.StateTask = complete.Task; var load = model.RefreshStateAsync();
        await model.SelectAsync(null); complete.SetResult(new(fake.Target, true, NasDiskTestType.Quick, false, null, null)); await load;
        Assert.Null(model.State); Assert.Null(model.Selected); Assert.False(model.IsBusy);
    }
    [Fact]
    public async Task UnsupportedUnknownAndOtherBusyNeverOfferStart()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Busy = null; await model.RefreshStateAsync(); Assert.False(model.CanChoose(NasDiskTestCommand.Quick));
        fake.Busy = true; await model.RefreshStateAsync(); Assert.False(model.CanChoose(NasDiskTestCommand.Extended));
        fake.Target = fake.Target with { SupportsSmartTest = null }; await model.ReloadAsync();
        await model.SelectAsync(model.Disks[0]); Assert.False(model.CanRead); Assert.Null(model.State);
    }
    [Fact]
    public async Task UnknownCommandSurvivesReloadWithoutReplay()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Unknown = true;
        model.Choose(NasDiskTestCommand.Quick); model.Confirm(true); await model.ExecuteAsync();
        Assert.Single(model.Pending); Assert.False(model.WasSuccessful); await model.ReloadAsync();
        Assert.Single(model.Pending); Assert.False(model.CanChoose(NasDiskTestCommand.Quick)); Assert.Equal(1, fake.Writes);
        fake.Resolve = true; await model.ReloadAsync(); Assert.Empty(model.Pending); Assert.True(model.WasSuccessful); Assert.Equal(1, fake.Writes);
    }
    [Fact]
    public async Task ConfirmedWriteRemainsSuccessfulWhenDisplayRefreshFails()
    {
        var (fake, model) = await Ready(); using var owned = model;
        model.Choose(NasDiskTestCommand.Quick); model.Confirm(true); fake.FailStateAfterWrite = true; await model.ExecuteAsync();
        Assert.True(model.WasSuccessful); Assert.NotNull(model.ErrorMessage); Assert.Null(model.State);
        Assert.False(model.CanChoose(NasDiskTestCommand.Quick));
    }
    [Fact]
    public async Task BusyWriteAndProfileSwitchDoNotAllowDuplicatesOrLateFeedback()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var complete = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = complete.Task;
        model.Choose(NasDiskTestCommand.Quick); model.Confirm(true); var write = model.ExecuteAsync();
        await model.ReloadAsync(); await model.ExecuteAsync(); Assert.Equal(1, fake.Writes);
        await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>()); Assert.True(fake.Token.IsCancellationRequested);
        complete.SetResult(Success()); await write; Assert.Null(model.LastResult); Assert.Null(model.State);
    }
    [Fact]
    public async Task PollOnlyRefreshesRunningDiskWithoutActiveConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var reads = fake.StateReads; await model.PollAsync(); Assert.Equal(reads, fake.StateReads);
        fake.Running = true; await model.RefreshStateAsync(); await model.LoadHistoryAsync();
        reads = fake.StateReads; await model.PollAsync(); Assert.Equal(reads + 1, fake.StateReads);
        model.Choose(NasDiskTestCommand.Stop); model.Confirm(true); reads = fake.StateReads;
        await model.PollAsync(); Assert.Equal(reads, fake.StateReads); Assert.True(model.CanExecute);
        await model.RefreshStateAsync(); fake.Running = false; await model.PollAsync();
        Assert.False(model.State!.IsRunning); Assert.Equal(2, fake.HistoryReads);
        Assert.Equal(0, fake.Writes);
    }

    private static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "diskTest", true, false, new(1, 0, 0), diagnosticTag: "disk.test.running");
    private static MutationResult Unknown() => new(1, MutationResultStatus.SubmittedButUnverified, "diskTest", true, true, new(0, 0, 1));
    public class Fake : DispatchProxy
    {
        public NasDiskTestTarget Target { get; set; } = new("disk-a", "device-a", "Synthetic disk", true);
        public bool Available { get; set; } = true; public bool Running { get; set; } public bool? Busy { get; set; } = false;
        public bool Unknown { get; set; } public bool Resolve { get; set; } public bool HistoryFails { get; set; } public bool FailStateAfterWrite { get; set; }
        public int HistoryReads { get; private set; } public int Writes { get; private set; }
        public int StateReads { get; private set; }
        public List<NasDiskTestRecovery> Pending { get; } = [];
        public NasDiskTestRequest? Sent { get; private set; } public CancellationToken Token { get; private set; }
        public Task<NasDiskTestState>? StateTask { get; set; } public Task<MutationResult>? WriteTask { get; set; }
        public NasSettingsWriteAvailability Flags => new(false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, Available);
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_ProfileId": return Guid.Parse("11111111-1111-1111-1111-111111111111");
                case "get_WriteAvailability": return Flags;
                case "PrepareServiceSettingsAsync": return Task.FromResult(Flags);
                case "LoadDiskTestTargetsAsync": return Task.FromResult<IReadOnlyList<NasDiskTestTarget>>([Target]);
                case "GetDiskTestRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasDiskTestRecovery>>(Pending.ToArray());
                case "ReviewDiskTestAsync": if (Resolve) Pending.Clear(); return Task.FromResult<MutationResult?>(Resolve ? Success() : NasDiskTestViewModelTests.Unknown());
                case "LoadDiskTestStateAsync":
                    StateReads++;
                    if (FailStateAfterWrite && Writes > 0) return Task.FromException<NasDiskTestState>(new IOException("合成状态失败"));
                    return StateTask ?? Task.FromResult(new NasDiskTestState((NasDiskTestTarget)args![0]!, Running, Running ? NasDiskTestType.Quick : null, Busy, null, null));
                case "LoadDiskTestHistoryAsync": HistoryReads++; return HistoryFails ? Task.FromException<NasDiskTestHistory>(new IOException("合成历史失败")) : Task.FromResult(new NasDiskTestHistory([], false));
                case "ExecuteDiskTestAsync":
                    Writes++; Sent = (NasDiskTestRequest)args![0]!; Token = (CancellationToken)args[1]!;
                    if (WriteTask is not null) return WriteTask;
                    if (Unknown) { Pending.Add(new(Target, Sent.Command)); return Task.FromResult(NasDiskTestViewModelTests.Unknown()); }
                    Running = Sent.Command != NasDiskTestCommand.Stop;
                    return Task.FromResult(new MutationResult(1, MutationResultStatus.ConfirmedSuccess, "diskTest", true, false, new(1, 0, 0),
                        diagnosticTag: Running ? "disk.test.running" : "disk.test.stopped"));
                default: throw new NotSupportedException(method.Name);
            }
        }
    }
}
