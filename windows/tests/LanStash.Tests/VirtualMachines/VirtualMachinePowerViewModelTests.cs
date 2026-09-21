using System.Reflection;
using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachinePowerViewModelTests
{
    private static VirtualMachineSummary Target => new("guest-a", "Synthetic", VirtualMachineOperationalState.Stopped, null, null, null, null, null);
    private static MutationResult Result(bool success) => new(1, success ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
        "virtualMachinePower", true, !success, success ? new(1, 0, 0) : new(0, 0, 1));
    private static async Task<(Fake Fake, VirtualMachinePowerViewModel Model)> Ready()
    {
        var repository = DispatchProxy.Create<IVirtualMachineManagerRepository, Fake>();
        var model = new VirtualMachinePowerViewModel(); await model.ActivateAsync(repository, Target, VirtualMachinePowerAction.PowerOn); return ((Fake)repository, model);
    }
    [Fact]
    public async Task ConfirmationCapabilityAndRepeatedClickProtectSubmission()
    {
        var (fake, model) = await Ready(); using var owned = model;
        await model.SubmitAsync(); Assert.Equal(0, fake.Writes); fake.Writable = false; Assert.False(model.Confirm(true));
        fake.Writable = true; Assert.True(model.Confirm(true)); fake.Writable = false; await model.SubmitAsync(); Assert.Equal(0, fake.Writes);
        fake.Writable = true; model.Confirm(true); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(1, fake.Writes); Assert.False(model.CanConfirm); Assert.True(model.NeedsParentRefresh);
    }
    [Fact]
    public async Task UnknownResultOnlyReviewsUntilConfirmed()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Unknown = true;
        model.Confirm(true); await model.SubmitAsync(); await model.ReloadAsync(); await model.SubmitAsync();
        Assert.Equal(1, fake.Writes); Assert.Equal(MutationResultStatus.SubmittedButUnverified, model.LastResult!.Status);
        fake.Resolve = true; await model.ReloadAsync(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, model.LastResult!.Status);
        Assert.False(model.CanSubmit); Assert.Equal(1, fake.Writes);
    }
    [Fact]
    public async Task PendingDifferentActionIsReportedAsItsOwnOperation()
    {
        var repository = DispatchProxy.Create<IVirtualMachineManagerRepository, Fake>(); var fake = (Fake)repository;
        fake.Pending = new("guest-a", "Synthetic", VirtualMachinePowerAction.Shutdown);
        using var model = new VirtualMachinePowerViewModel(); await model.ActivateAsync(repository, Target, VirtualMachinePowerAction.PowerOn);
        Assert.Equal(VirtualMachinePowerAction.Shutdown, model.ResultAction); Assert.False(model.CanConfirm); Assert.Equal(0, fake.Writes);
    }
    [Fact]
    public async Task ProfileSwitchCancelsAndIgnoresLateSubmission()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var delayed = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = delayed.Task;
        model.Confirm(true); var sending = model.SubmitAsync(); await model.SubmitAsync(); Assert.Equal(1, fake.Writes);
        await model.ActivateAsync(DispatchProxy.Create<IVirtualMachineManagerRepository, Fake>(), Target, VirtualMachinePowerAction.PowerOn);
        Assert.True(fake.Token.IsCancellationRequested); delayed.SetResult(Result(true)); await sending; Assert.Null(model.LastResult);
    }
    [Fact]
    public async Task FailedPreparationCannotEnableConfirmation()
    {
        var repository = DispatchProxy.Create<IVirtualMachineManagerRepository, Fake>(); var fake = (Fake)repository; fake.FailRead = true;
        using var model = new VirtualMachinePowerViewModel(); await model.ActivateAsync(repository, Target, VirtualMachinePowerAction.PowerOn);
        Assert.NotNull(model.ErrorMessage); Assert.False(model.CanConfirm); fake.FailRead = false; await model.ReloadAsync(); Assert.True(model.CanConfirm);
    }
    public class Fake : DispatchProxy
    {
        public bool Writable = true, Unknown, Resolve, FailRead;
        public int Writes;
        public CancellationToken Token;
        public VirtualMachinePowerRecovery? Pending;
        public Task<MutationResult>? WriteTask;
        protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
        {
            "get_ProfileId" => Guid.Parse("11111111-1111-1111-1111-111111111111"),
            "get_CanControlPower" => Writable,
            "GetPowerRecoveriesAsync" => FailRead ? Task.FromException<IReadOnlyList<VirtualMachinePowerRecovery>>(new IOException("synthetic")) :
                Task.FromResult<IReadOnlyList<VirtualMachinePowerRecovery>>(Pending is null ? [] : [Pending]),
            "ReviewPowerAsync" => Review(),
            "ControlPowerAsync" => Write((VirtualMachinePowerRequest)args![0]!, (CancellationToken)args[1]!),
            _ => throw new NotSupportedException(method.Name)
        };
        private Task<MutationResult?> Review() { if (Resolve) Pending = null; return Task.FromResult<MutationResult?>(Result(Resolve)); }
        private Task<MutationResult> Write(VirtualMachinePowerRequest request, CancellationToken token)
        { Writes++; Token = token; if (WriteTask is not null) return WriteTask; if (Unknown) Pending = new(request.Baseline.Id, request.Baseline.Name, request.Action); return Task.FromResult(Result(!Unknown)); }
    }
}
