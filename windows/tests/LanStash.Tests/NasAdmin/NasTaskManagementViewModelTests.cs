using System.Reflection;
using LanStash.App.Features.NasAdmin;
using LanStash.Domain;

namespace LanStash.Tests.NasAdmin;

public sealed class NasTaskManagementViewModelTests
{
    private static async Task<(Fake Fake, NasTaskManagementViewModel Model)> Ready()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        var model = new NasTaskManagementViewModel(); await model.ActivateAsync(repository); model.SelectTask(model.Tasks[0]); return (fake, model);
    }

    [Fact]
    public async Task ListNeverPrefetchesScriptOrOutputAndSelectionClearsSensitiveData()
    {
        var (fake, model) = await Ready(); using var owned = model;
        Assert.Equal(0, fake.DetailReads); Assert.Equal(0, fake.OutputReads); Assert.Null(model.Draft);
        await model.OpenDetailAsync(false); Assert.Equal("synthetic-script", model.Draft!.Script); Assert.False(model.IsEditing);
        model.SelectTask(null); Assert.Null(model.Draft); Assert.Null(model.Output); Assert.Empty(model.Results);
    }

    [Theory]
    [InlineData(true)] [InlineData(false)]
    public async Task CreateAndEditRequireCurrentConfirmedDraft(bool create)
    {
        var (fake, model) = await Ready(); using var owned = model;
        if (create) await model.CreateAsync(); else await model.OpenDetailAsync(true);
        var next = model.Draft! with { Name = create ? "new-task" : model.Draft!.Name, Script = "changed-script" };
        model.ChangeDraft(next); await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
        Assert.True(model.Confirm(true)); model.ChangeDraft(next with { Script = "changed-again" });
        await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
        Assert.True(model.Confirm(true)); await model.ExecuteAsync(); await model.ExecuteAsync();
        Assert.Equal(1, fake.Writes); Assert.NotNull(fake.Save); Assert.Equal(create, fake.Save.BaselineTask is null);
        Assert.Null(model.Draft); Assert.True(model.WasSuccessful); Assert.False(model.IsBusy);
    }

    [Theory]
    [InlineData(NasTaskCommand.Enable)] [InlineData(NasTaskCommand.Disable)] [InlineData(NasTaskCommand.Run)] [InlineData(NasTaskCommand.Delete)]
    public async Task CommandsUseSeparateConfirmationAndPreviewWhenNeeded(NasTaskCommand command)
    {
        var (fake, model) = await Ready(); using var owned = model;
        if (command == NasTaskCommand.Enable) { fake.Row = fake.Row with { IsEnabled = false }; fake.Detail = fake.Detail with { IsEnabled = false }; await model.ReloadAsync(); }
        await model.ChooseCommandAsync(command); Assert.Equal(command is NasTaskCommand.Enable or NasTaskCommand.Run ? 1 : 0, fake.DetailReads);
        await model.ExecuteAsync(); Assert.Equal(0, fake.Writes); Assert.True(model.Confirm(true)); await model.ExecuteAsync();
        Assert.Equal(command, fake.Command!.Command); Assert.Null(model.Draft); Assert.Null(model.Output); Assert.Equal(1, fake.Writes);
        if (command == NasTaskCommand.Run) { Assert.Equal("task.run.accepted", model.LastResult!.DiagnosticTag); Assert.Equal(0, fake.ResultReads); }
    }

    [Fact]
    public async Task HistoryDoesNotFetchOutputUntilSelected()
    {
        var (fake, model) = await Ready(); using var owned = model;
        await model.LoadResultsAsync(); Assert.Single(model.Results); Assert.Equal(0, fake.OutputReads);
        Assert.True(model.HasLoadedResults); Assert.False(model.HasLoadedOutput);
        await model.SelectResultAsync(model.Results[0]); Assert.Equal("synthetic-output", model.Output!.Output);
        Assert.True(model.HasLoadedOutput);
        model.CloseDetail(); Assert.Empty(model.Results); Assert.Null(model.Output); Assert.Null(model.SelectedResult); Assert.False(model.HasLoadedResults);
    }

    [Fact]
    public async Task UnrelatedResultAndLateOutputCannotPopulateAnotherSelection()
    {
        var (fake, model) = await Ready(); using var owned = model; await model.LoadResultsAsync();
        await model.SelectResultAsync(new("other", "other-task", null, null, null, null, null)); Assert.Equal(0, fake.OutputReads); Assert.Null(model.SelectedResult);
        var complete = new TaskCompletionSource<NasTaskResultOutput>(TaskCreationOptions.RunContinuationsAsynchronously); fake.OutputTask = complete.Task;
        var reading = model.SelectResultAsync(model.Results[0]); model.SelectTask(null); complete.SetResult(new("late-command", "late-output")); await reading;
        Assert.Null(model.Output); Assert.Empty(model.Results);
    }

    [Fact]
    public async Task UnknownRunBlocksNewCommandsAndRecoveryDoesNotReplay()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Unknown = true;
        await model.ChooseCommandAsync(NasTaskCommand.Run); model.Confirm(true); await model.ExecuteAsync();
        Assert.Single(model.PendingCommands); Assert.False(model.CanCommand(NasTaskCommand.Delete)); Assert.False(model.WasSuccessful);
        await model.ReloadAsync(); Assert.Single(model.PendingCommands); Assert.Equal(1, fake.Writes); Assert.Equal(0, fake.ResultReads);
    }

    [Fact]
    public async Task BusyWriteCannotBeRepeatedAndProfileSwitchDropsLateResult()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var complete = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = complete.Task;
        await model.ChooseCommandAsync(NasTaskCommand.Delete); model.Confirm(true); var writing = model.ExecuteAsync();
        await model.ReloadAsync(); await model.ExecuteAsync(); Assert.Equal(1, fake.Writes); Assert.True(model.IsBusy);
        await model.ActivateAsync(DispatchProxy.Create<INasSettingsRepository, Fake>()); Assert.True(fake.LastToken.IsCancellationRequested);
        complete.SetResult(Success()); await writing; Assert.Null(model.LastResult); Assert.Null(model.Draft);
    }

    [Fact]
    public async Task ClosedCapabilitiesAndIncompletePreviewNeverSubmit()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Available = false;
        Assert.False(model.CanCreate); Assert.False(model.CanCommand(NasTaskCommand.Run)); await model.OpenDetailAsync(false);
        Assert.NotNull(model.Draft); Assert.False(model.IsEditing); Assert.False(model.Confirm(true));
        model.CloseDetail(); fake.Available = true; fake.Detail = fake.Detail with { Script = null };
        await model.ChooseCommandAsync(NasTaskCommand.Run); Assert.False(model.Confirm(true)); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task RecoveryCanCompleteForMissingSavedOrDeletedTask()
    {
        var repository = DispatchProxy.Create<INasSettingsRepository, Fake>(); var fake = (Fake)repository;
        fake.Recoveries.Add(new(12, "synthetic-task", "owner", NasTaskCommand.Delete)); fake.ReviewSuccess = true; fake.Removed = true;
        using var model = new NasTaskManagementViewModel(); await model.ActivateAsync(repository);
        Assert.Empty(model.Tasks); Assert.Empty(model.PendingCommands); Assert.True(model.WasSuccessful); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task LateDetailCannotLeakIntoAnotherTaskAndLoadFailureIsNotSuccess()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var completed = new TaskCompletionSource<NasTaskDetail>(TaskCreationOptions.RunContinuationsAsynchronously); fake.DetailTask = completed.Task;
        var loading = model.OpenDetailAsync(false); model.SelectTask(null); completed.SetResult(fake.Detail); await loading;
        Assert.Null(model.Draft); Assert.False(model.IsBusy);
        model.SelectTask(model.Tasks[0]); fake.DetailTask = Task.FromException<NasTaskDetail>(new IOException("合成详情失败"));
        await model.OpenDetailAsync(true); Assert.NotNull(model.ErrorMessage); Assert.Null(model.Draft); Assert.False(model.CanSave); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task RevokedCapabilityInvalidatesConfirmedCommand()
    {
        var (fake, model) = await Ready(); using var owned = model;
        await model.ChooseCommandAsync(NasTaskCommand.Delete); Assert.True(model.Confirm(true));
        fake.Available = false; Assert.False(model.CanExecute); await model.ExecuteAsync(); Assert.Equal(0, fake.Writes);
    }

    [Fact]
    public async Task SuccessfulSaveIsNotChangedToUnknownWhenListRefreshFails()
    {
        var (fake, model) = await Ready(); using var owned = model;
        await model.OpenDetailAsync(true); model.ChangeDraft(model.Draft! with { Script = "changed-script" });
        Assert.True(model.Confirm(true)); fake.ListFails = true; await model.ExecuteAsync();
        Assert.True(model.WasSuccessful); Assert.NotNull(model.ErrorMessage); Assert.Empty(model.PendingSaves);
        Assert.False(model.CanCreate); Assert.False(model.CanCommand(NasTaskCommand.Run)); Assert.Equal(1, fake.Writes);
        fake.ListFails = false; await model.ReloadAsync(); Assert.True(model.CanCreate); Assert.Equal(1, fake.Writes);
    }

    [Fact]
    public async Task UnknownSaveKeepsRecoveryAndNeverResubmitsOnRefresh()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Unknown = true;
        await model.OpenDetailAsync(true); model.ChangeDraft(model.Draft! with { Script = "changed-script" });
        Assert.True(model.Confirm(true)); await model.ExecuteAsync();
        Assert.Single(model.PendingSaves); Assert.False(model.CanEdit); Assert.Null(model.Draft);
        await model.ReloadAsync(); Assert.Single(model.PendingSaves); Assert.Equal(1, fake.Writes);
        fake.ReviewSuccess = true; await model.ReloadAsync(); Assert.Empty(model.PendingSaves);
        Assert.True(model.WasSuccessful); Assert.True(model.CanEdit); Assert.Equal(1, fake.Writes);
    }

    private static MutationResult Success(string? tag = null) => new(1, MutationResultStatus.ConfirmedSuccess, "taskCommand", true, false, new(1, 0, 0), diagnosticTag: tag);
    private static MutationResult UnknownResult() => new(1, MutationResultStatus.SubmittedButUnverified, "taskCommand", true, true, new(0, 0, 1));
    public class Fake : DispatchProxy
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public NasTaskEntry Row { get; set; } = new(12, "synthetic-task", "runner", "owner", "script", null, true, null, true, true);
        public NasTaskDetail Detail { get; set; } = new(12, "owner", "synthetic-task", "runner", "owner", true,
            new(0, "1,2,3,4,5", null, 1002, [], 3, 0, 0, 0, 3), "synthetic-script", false, "");
        public bool Available { get; set; } = true; public bool Unknown { get; set; } public bool ReviewSuccess { get; set; } public bool Removed { get; set; }
        public int DetailReads { get; private set; } public int ResultReads { get; private set; } public int OutputReads { get; private set; } public int Writes { get; private set; }
        public List<NasTaskRecoveryInfo> Recoveries { get; } = []; public List<NasTaskSaveRecoveryInfo> SaveRecoveries { get; } = [];
        public NasTaskCommandRequest? Command { get; private set; } public NasTaskSaveRequest? Save { get; private set; }
        public Task<MutationResult>? WriteTask { get; set; } public Task<NasTaskResultOutput>? OutputTask { get; set; } public CancellationToken LastToken { get; private set; }
        public Task<NasTaskDetail>? DetailTask { get; set; }
        public bool ListFails { get; set; }
        private static NasSettingsWriteAvailability Flags => new(false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false);
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_ProfileId": return ProfileId;
                case "get_WriteAvailability": return Flags;
                case "get_CanSaveScheduledTasks": return Available;
                case "get_TaskCommandAvailability": return new NasTaskCommandAvailability(Available, Available, Available);
                case "PrepareServiceSettingsAsync": return Task.FromResult(Flags);
                case "GetTaskRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasTaskRecoveryInfo>>(Recoveries.ToArray());
                case "GetTaskSaveRecoveriesAsync": return Task.FromResult<IReadOnlyList<NasTaskSaveRecoveryInfo>>(SaveRecoveries.ToArray());
                case "ReviewTaskCommandAsync": if (ReviewSuccess) Recoveries.Clear(); return Task.FromResult<MutationResult?>(ReviewSuccess ? Success() : UnknownResult());
                case "ReviewTaskSaveAsync": if (ReviewSuccess) SaveRecoveries.Clear(); return Task.FromResult<MutationResult?>(ReviewSuccess ? Success() : UnknownResult());
                case "LoadScheduledTasksAsync": return ListFails ? Task.FromException<IReadOnlyList<NasTaskEntry>>(new IOException("合成列表失败")) : Task.FromResult<IReadOnlyList<NasTaskEntry>>(Removed ? [] : [Row]);
                case "LoadScheduledTaskDetailAsync": DetailReads++; return DetailTask ?? Task.FromResult(args![0] is null ? Detail with { Id = null, Name = "", Script = "" } : Detail);
                case "LoadScheduledTaskResultsAsync": ResultReads++; return Task.FromResult<IReadOnlyList<NasTaskResult>>([new("r1", Row.Name, null, null, "normal", 0, null)]);
                case "LoadScheduledTaskOutputAsync": OutputReads++; return OutputTask ?? Task.FromResult(new NasTaskResultOutput("synthetic-script", "synthetic-output"));
                case "SaveScheduledTaskAsync":
                    Save = (NasTaskSaveRequest)args![0]!; Writes++; LastToken = (CancellationToken)args[1]!;
                    if (WriteTask is not null) return WriteTask;
                    if (Unknown) { SaveRecoveries.Add(new(Save.RequestId, Save.Desired.Id, Save.Desired.Name!, Save.Desired.RealOwner)); return Task.FromResult(UnknownResult()); }
                    Detail = Save.Desired with { Id = Save.Desired.Id ?? 21 }; Row = Row with { Id = Detail.Id!.Value, Name = Detail.Name!, Owner = Detail.Owner, IsEnabled = Detail.IsEnabled };
                    return Task.FromResult(Success());
                case "ExecuteTaskCommandAsync":
                    Command = (NasTaskCommandRequest)args![0]!; Writes++; LastToken = (CancellationToken)args[1]!;
                    if (WriteTask is not null) return WriteTask;
                    if (Unknown) { Recoveries.Add(new(Row.Id, Row.Name, Row.RealOwner, Command.Command)); return Task.FromResult(UnknownResult()); }
                    if (Command.Command == NasTaskCommand.Delete) Removed = true;
                    if (Command.Command is NasTaskCommand.Enable or NasTaskCommand.Disable) Row = Row with { IsEnabled = Command.Command == NasTaskCommand.Enable };
                    return Task.FromResult(Success(Command.Command == NasTaskCommand.Run ? "task.run.accepted" : null));
                default: throw new NotSupportedException(method.Name);
            }
        }
    }
}
