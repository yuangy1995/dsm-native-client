using System.Reflection;
using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineSettingsViewModelTests
{
    private static VirtualMachineSettings Initial => new("guest-a", VirtualMachineOperationalState.Stopped, new("Synthetic", "Before", 2, 2048, VirtualMachineAutoStart.PreviousState));
    private static MutationResult Result(bool success) => new(1, success ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
        "saveVirtualMachineSettings", true, !success, success ? new(1, 0, 0) : new(0, 0, 1));
    private static async Task<(Fake Fake, VirtualMachineSettingsViewModel Model)> Ready()
    {
        var repository = DispatchProxy.Create<IVirtualMachineManagerRepository, Fake>();
        var model = new VirtualMachineSettingsViewModel(); await model.ActivateAsync(repository, "guest-a"); return ((Fake)repository, model);
    }
    [Fact]
    public async Task SaveRequiresCurrentConfirmationAndCapabilityAndReloadsActualValues()
    {
        var (fake, model) = await Ready(); using var owned = model;
        Assert.False(model.CanConfirm); model.ChangeDraft(model.Draft! with { Name = "Changed" });
        Assert.True(model.Confirm(true)); model.ChangeDraft(model.Draft! with { Description = "Changed" });
        await model.SubmitAsync(); Assert.Equal(0, fake.Writes);
        fake.Writable = false; Assert.False(model.Confirm(true)); fake.Writable = true;
        model.Confirm(true); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(1, fake.Writes); Assert.Equal(fake.Current, model.Baseline); Assert.False(model.HasChanges);
        Assert.True(model.NeedsParentRefresh); model.ChangeDraft(model.Draft! with { Name = "Next" }); Assert.True(model.CanConfirm);
    }
    [Fact]
    public async Task RunningHardwareAndInvalidNumbersCannotBeConfirmed()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Current = fake.Current with { State = VirtualMachineOperationalState.Running }; await model.ReloadAsync();
        Assert.False(model.CanEditHardware); model.ChangeDraft(model.Draft! with { CpuCount = 4 }); Assert.False(model.CanConfirm);
        model.ChangeDraft(fake.Current.Configuration with { Description = "Metadata" }); Assert.True(model.CanConfirm);
        fake.Current = Initial; await model.ActivateAsync((IVirtualMachineManagerRepository)fake, "guest-a");
        model.ChangeDraft(model.Draft! with { MemoryMiB = -1 }); Assert.False(model.CanConfirm); Assert.NotNull(model.ValidationMessage);
    }
    [Fact]
    public async Task UnknownSaveOnlyReviewsThenReloadsBeforeNextEdit()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Unknown = true;
        model.ChangeDraft(model.Draft! with { Name = "Changed" }); model.Confirm(true); await model.SubmitAsync();
        await model.ReloadAsync(); await model.SubmitAsync(); Assert.False(model.CanEdit); Assert.Equal(1, fake.Writes);
        fake.Resolve = true; await model.ReloadAsync(); Assert.True(model.CanEdit); Assert.False(model.HasChanges);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, model.LastResult!.Status); Assert.Equal(1, fake.Writes);
    }
    [Fact]
    public async Task PowerPendingLockClearsWhenPowerRecoveryFinishes()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.PowerPending = true;
        await model.ReloadAsync(); Assert.False(model.CanEdit); Assert.NotNull(model.ErrorMessage);
        fake.PowerPending = false; await model.ReloadAsync(); Assert.True(model.CanEdit); Assert.Null(model.ErrorMessage);
    }
    [Fact]
    public async Task LostSaveWithoutRecoveryNeverEnablesReplay()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.WriteTask = Task.FromException<MutationResult>(new IOException("synthetic"));
        model.ChangeDraft(model.Draft! with { Name = "Changed" }); model.Confirm(true); await model.SubmitAsync();
        await model.ReloadAsync(); Assert.False(model.CanEdit); Assert.False(model.CanConfirm); Assert.Equal(1, fake.Writes);
    }
    [Fact]
    public async Task ReadFailureAndWrongIdentityDoNotEnableEditing()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.FailRead = true;
        await model.ReloadAsync(); Assert.False(model.CanEdit); Assert.NotNull(model.ErrorMessage);
        fake.FailRead = false; fake.Current = Initial with { Id = "other" }; await model.ReloadAsync(); Assert.False(model.CanEdit);
        fake.Current = Initial; await model.ReloadAsync(); Assert.True(model.CanEdit);
    }
    [Fact]
    public async Task ProfileSwitchCancelsAndIgnoresLateWrite()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var delayed = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = delayed.Task;
        model.ChangeDraft(model.Draft! with { Name = "Changed" }); model.Confirm(true); var sending = model.SubmitAsync();
        await model.SubmitAsync(); Assert.Equal(1, fake.Writes);
        await model.ActivateAsync(DispatchProxy.Create<IVirtualMachineManagerRepository, Fake>(), "guest-a");
        Assert.True(fake.Token.IsCancellationRequested); delayed.SetResult(Result(true)); await sending;
        Assert.Null(model.LastResult); Assert.Equal(Initial, model.Baseline);
    }
    [Fact]
    public async Task PriorityChangeInvalidatesConfirmationAndKeepsUnknownSettingsReadOnly()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Current = Initial with { Configuration = Initial.Configuration with { CpuWeight = 256 } }; await model.ReloadAsync();
        Assert.True(model.CanEditPriority); model.ChangeDraft(model.Draft! with { CpuWeight = 1024 }); Assert.True(model.Confirm(true));
        model.ChangeDraft(model.Draft! with { CpuWeight = 64 }); Assert.False(model.CanSubmit);
        fake.Unknown = true; model.Confirm(true); await model.SubmitAsync();
        Assert.False(model.CanEditPriority); Assert.Equal(64, fake.Pending!.Desired.CpuWeight);
        await model.ReloadAsync(); Assert.Equal(1, fake.Writes); Assert.False(model.CanConfirm);
        fake.Resolve = true; await model.ReloadAsync(); Assert.True(model.CanEditPriority); Assert.Equal(64, model.Draft!.CpuWeight);
    }
    [Fact]
    public async Task PriorityNeedsCapabilityAndKnownBaselineWithoutBlockingBasicEdits()
    {
        var (fake, model) = await Ready(); using var owned = model; Assert.False(model.PriorityAvailable);
        model.ChangeDraft(model.Draft! with { CpuWeight = 256 }); Assert.False(model.CanConfirm);
        model.ChangeDraft(model.Draft! with { CpuWeight = null, Description = "basic change" }); Assert.True(model.CanConfirm);
        model.ChangeDraft(model.Baseline!.Configuration); fake.Current = Initial with { Configuration = Initial.Configuration with { CpuWeight = 128 } };
        await model.ReloadAsync(); fake.PriorityWritable = false;
        model.ChangeDraft(model.Draft! with { CpuWeight = 1024 }); Assert.False(model.CanConfirm);
        model.ChangeDraft(model.Draft! with { CpuWeight = 128, Description = "basic" }); Assert.True(model.CanConfirm);
    }
    public class Fake : DispatchProxy
    {
        public bool Writable = true, Unknown, Resolve, FailRead, PowerPending;
        public bool PriorityWritable = true;
        public int Writes;
        public CancellationToken Token;
        public VirtualMachineSettings Current = Initial;
        public VirtualMachineSettingsRequest? Pending;
        public Task<MutationResult>? WriteTask;
        protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
        {
            "get_ProfileId" => Guid.Parse("11111111-1111-1111-1111-111111111111"),
            "get_CanEditSettings" => Writable,
            "get_CanEditPriority" => PriorityWritable,
            "LoadSettingsAsync" => FailRead ? Task.FromException<VirtualMachineSettings>(new IOException("synthetic")) : Task.FromResult(Current),
            "GetSettingsRecoveriesAsync" => Task.FromResult<IReadOnlyList<VirtualMachineSettingsRecovery>>(Pending is null ? [] : [new(Current.Id, Current.Configuration.Name)]),
            "GetPowerRecoveriesAsync" => Task.FromResult<IReadOnlyList<VirtualMachinePowerRecovery>>(PowerPending ? [new(Current.Id, Current.Configuration.Name, VirtualMachinePowerAction.PowerOn)] : []),
            "ReviewSettingsAsync" => Review(),
            "SaveSettingsAsync" => Write((VirtualMachineSettingsRequest)args![0]!, (CancellationToken)args[1]!),
            _ => throw new NotSupportedException(method.Name)
        };
        private Task<MutationResult?> Review()
        { if (Resolve && Pending is { } pending) { Current = Current with { Configuration = pending.Desired }; Pending = null; } return Task.FromResult<MutationResult?>(Result(Resolve)); }
        private Task<MutationResult> Write(VirtualMachineSettingsRequest request, CancellationToken token)
        {
            Writes++; Token = token; if (WriteTask is not null) return WriteTask;
            if (Unknown) Pending = request; else Current = Current with { Configuration = request.Desired };
            return Task.FromResult(Result(!Unknown));
        }
    }
}
