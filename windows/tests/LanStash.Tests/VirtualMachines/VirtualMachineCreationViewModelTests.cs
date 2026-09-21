using System.Reflection;
using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;
using LanStash.Tests.Chat;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineCreationViewModelTests
{
    private static async Task<(Fake Fake, VirtualMachineCreationViewModel Model)> Ready(ManualRefreshTimeProvider? time = null)
    {
        var repository = DispatchProxy.Create<IVirtualMachineManagerRepository, Fake>(); var model = new VirtualMachineCreationViewModel(time ?? new());
        await model.ActivateAsync(repository); model.ChangeDraft(model.Draft! with { Settings = model.Draft!.Settings with { Name = "Synthetic" } });
        return ((Fake)repository, model);
    }
    [Fact]
    public async Task CurrentConfirmationAndCapabilityAreRequiredAndSuccessCannotCreateTwice()
    {
        var (fake, model) = await Ready(); using var owned = model;
        await model.SubmitAsync(); Assert.Equal(0, fake.Creates); Assert.True(model.Confirm(true));
        model.ChangeDraft(model.Draft! with { Settings = model.Draft!.Settings with { Description = "changed" } }); await model.SubmitAsync(); Assert.Equal(0, fake.Creates);
        fake.Writable = false; Assert.False(model.Confirm(true)); fake.Writable = true; model.Confirm(true); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(1, fake.Creates); Assert.Equal(VirtualMachineCreationStage.Complete, model.LastResult!.Stage); Assert.False(model.CanEdit); Assert.True(model.NeedsParentRefresh);
    }
    [Fact]
    public async Task MutatingConfirmedArrayCannotChangeWhatWasApproved()
    {
        var (fake, model) = await Ready(); using var owned = model; model.Confirm(true);
        ((VirtualMachineCreationDisk[])model.Draft!.Disks)[0] = new(1024);
        Assert.False(model.CanSubmit); await model.SubmitAsync(); Assert.Equal(0, fake.Creates);
    }
    [Fact]
    public async Task AutomaticReviewNeverWritesDeferredConfigurationWithoutNewConfirmation()
    {
        var time = new ManualRefreshTimeProvider(); var (fake, model) = await Ready(time); using var owned = model; fake.Stage = VirtualMachineCreationStage.Creating;
        model.Confirm(true); await model.SubmitAsync(); Assert.Equal(1, time.ActiveTimers);
        fake.Stage = VirtualMachineCreationStage.Configure; time.Advance(TimeSpan.FromSeconds(2)); await Until(() => fake.Reviews == 1 && !model.IsBusy);
        Assert.Equal(0, fake.Continues); Assert.False(model.CanSubmit); Assert.True(model.CanConfirm); Assert.Equal(0, time.ActiveTimers);
        model.Confirm(true); await model.SubmitAsync(); Assert.Equal(1, fake.Creates); Assert.Equal(1, fake.Continues);
    }
    [Fact]
    public async Task MissingReceiptAndImageSourceNeverPollOrEnableNewCreation()
    {
        foreach (var stage in new[] { VirtualMachineCreationStage.VerifyReceipt, VirtualMachineCreationStage.VerifyImageSource })
        {
            var time = new ManualRefreshTimeProvider(); var (fake, model) = await Ready(time); using var owned = model; fake.Stage = stage;
            model.Confirm(true); await model.SubmitAsync(); Assert.False(model.CanConfirm); Assert.False(model.CanEdit); Assert.Equal(0, time.ActiveTimers);
            await model.RefreshAsync(); Assert.Equal(1, fake.Creates); Assert.Equal(0, fake.Continues);
        }
    }
    [Fact]
    public async Task RecoveryShowsOriginalDraftButRequiresNewConfirmationToContinue()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.LastRequest = model.Draft! with { RequestId = Guid.NewGuid(), RiskConfirmed = false }; fake.Recovery = new(fake.LastRequest);
        await model.RefreshAsync(); fake.Stage = VirtualMachineCreationStage.Configure; await model.SelectRecoveryAsync(Assert.Single(model.Recoveries));
        Assert.Equal(fake.LastRequest.RequestId, model.ActiveRequest!.RequestId); Assert.False(model.CanEdit); Assert.False(model.CanSubmit);
        model.Confirm(true); await model.SubmitAsync(); Assert.Equal(0, fake.Creates); Assert.Equal(1, fake.Continues);
    }
    [Fact]
    public async Task PreflightFailureRequiresFreshOptionsAndNewConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.PreflightFailure = true;
        model.Confirm(true); await model.SubmitAsync(); Assert.Null(model.ActiveRequest); Assert.False(model.CanConfirm);
        fake.PreflightFailure = false; await model.RefreshAsync(); Assert.True(model.CanConfirm); Assert.False(model.CanSubmit);
    }
    [Fact]
    public async Task DisposalCancelsInFlightRequestAndIgnoresItsLateResult()
    {
        var (fake, model) = await Ready(); var completion = new TaskCompletionSource<VirtualMachineCreationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.Delayed = completion.Task;
        model.Confirm(true); var sending = model.SubmitAsync(); await model.SubmitAsync(); Assert.Equal(1, fake.Creates);
        model.Dispose(); Assert.True(fake.Token.IsCancellationRequested); completion.SetResult(fake.Result(VirtualMachineCreationStage.Complete)); await sending;
        Assert.Null(model.LastResult); Assert.Null(model.ActiveRequest);
    }
    [Fact]
    public async Task InvalidResourcesAndMalformedMacCannotBeConfirmed()
    {
        var (fake, model) = await Ready(); using var owned = model;
        model.ChangeDraft(model.Draft! with { Networks = [new(null, " a:00:00:00:00:01")] }); Assert.False(model.CanConfirm);
        model.ChangeDraft(model.Draft! with { Networks = [new(null, "02:00:00:00:00:01")] }); Assert.True(model.CanConfirm);
        fake.NoStorage = true; await model.RefreshAsync(); Assert.NotNull(model.ErrorMessage); Assert.False(model.CanConfirm);
    }
    [Fact]
    public async Task MissingRecoveryResultNeverReusesAnOldContinuePermission()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Stage = VirtualMachineCreationStage.Configure;
        model.Confirm(true); await model.SubmitAsync(); Assert.True(model.CanConfirm);
        fake.MissingReview = true; await model.RefreshAsync(); Assert.NotNull(model.ErrorMessage); Assert.False(model.CanConfirm); Assert.Null(model.LastResult);
    }
    private static async Task Until(Func<bool> condition) { for (var i = 0; i < 100 && !condition(); i++) await Task.Delay(10); Assert.True(condition()); }
    [Fact]
    public async Task PowerOptionChangesInvalidateConfirmationAndRequireActualCapability()
    {
        var (fake, model) = await Ready(); using var owned = model; model.Confirm(true);
        model.ChangeDraft(model.Draft! with { PowerOnAfterCreation = true }); Assert.False(model.CanSubmit);
        fake.PowerAvailable = false; Assert.False(model.CanConfirm); Assert.NotNull(model.ValidationMessage);
        fake.PowerAvailable = true; Assert.True(model.Confirm(true)); await model.SubmitAsync();
        Assert.True(fake.LastRequest!.PowerOnAfterCreation); Assert.Equal(1, fake.Creates);
    }
    [Fact]
    public async Task PowerRecoveryPollsReadOnlyAndStopsForExplicitContinuation()
    {
        var time = new ManualRefreshTimeProvider(); var (fake, model) = await Ready(time); using var owned = model;
        model.ChangeDraft(model.Draft! with { PowerOnAfterCreation = true }); fake.Stage = VirtualMachineCreationStage.VerifyPower;
        model.Confirm(true); await model.SubmitAsync(); Assert.Equal(1, time.ActiveTimers);
        time.Advance(TimeSpan.FromSeconds(2)); await Until(() => fake.Reviews == 1 && !model.IsBusy); Assert.Equal(0, fake.Continues);
        fake.Stage = VirtualMachineCreationStage.PowerOn; await model.RefreshAsync(); Assert.False(model.CanSubmit); Assert.True(model.CanConfirm);
        model.Confirm(true); await model.SubmitAsync(); Assert.Equal(1, fake.Continues); Assert.Equal(1, fake.Creates);
    }
    [Fact]
    public async Task PowerContinuationUsesPowerActionAndKeepsPowerStageOnUnexpectedFailure()
    {
        var (fake, model) = await Ready(); using var owned = model;
        model.ChangeDraft(model.Draft! with { PowerOnAfterCreation = true }); fake.Stage = VirtualMachineCreationStage.PowerOn;
        model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(LanStash.App.Localization.LocalizationService.Current.Get("VmPowerOnAction"), model.PrimaryText);
        fake.ContinueFailure = true; model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(VirtualMachineCreationStage.VerifyPower, model.LastResult!.Stage);
        Assert.Equal(LanStash.App.Localization.LocalizationService.Current.Get("VmCreatePowerUnknown"), model.ErrorMessage);
        Assert.False(model.CanSubmit); Assert.Equal(1, fake.Continues);
    }
    [Fact]
    public async Task AuthenticationFailureStopsAutomaticPowerReviewWithoutLosingRecovery()
    {
        var time = new ManualRefreshTimeProvider(); var (fake, model) = await Ready(time); using var owned = model;
        fake.Stage = VirtualMachineCreationStage.VerifyPower; fake.ErrorCategory = MutationErrorCategory.Authentication;
        model.ChangeDraft(model.Draft! with { PowerOnAfterCreation = true }); model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(0, time.ActiveTimers); Assert.NotNull(model.ActiveRequest); Assert.False(model.CanSubmit);
        await model.RefreshAsync(); Assert.Equal(1, fake.Reviews); Assert.Equal(0, fake.Continues); Assert.Equal(0, time.ActiveTimers);
    }
    [Fact]
    public async Task AdvancedPresetFirmwareAndIsoAreBoundToConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.AdvancedAvailable = true; await model.RefreshAsync(); Assert.True(model.CanChooseAdvanced);
        model.SelectOperatingSystem(VirtualMachineOperatingSystem.Linux);
        model.ChangeDraft(model.Draft! with { Advanced = model.Draft!.Advanced! with { Firmware = VirtualMachineFirmware.Uefi, BootImage = Fake.AdvancedImage } });
        model.Confirm(true); Assert.True(model.CanSubmit);
        model.ChangeDraft(model.Draft! with { Advanced = model.Draft!.Advanced! with { Firmware = VirtualMachineFirmware.Legacy } });
        Assert.False(model.CanSubmit); model.Confirm(true);
        model.ChangeDraft(model.Draft! with { Advanced = model.Draft!.Advanced! with { BootImage = null } });
        Assert.False(model.CanSubmit); model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(VirtualMachineOperatingSystem.Linux, fake.LastRequest!.Advanced!.OperatingSystem);
        Assert.Equal(VirtualMachineFirmware.Legacy, fake.LastRequest.Advanced.Firmware); Assert.Null(fake.LastRequest.Advanced.BootImage);
    }
    [Fact]
    public async Task AdvancedReadFailureDoesNotSubmitOrSilentlySwitchAnExistingAdvancedDraft()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.AdvancedAvailable = true; await model.RefreshAsync();
        model.SelectOperatingSystem(VirtualMachineOperatingSystem.Windows); model.Confirm(true); Assert.True(model.CanSubmit);
        fake.AdvancedFail = true; await model.RefreshAsync(); Assert.NotNull(model.Draft!.Advanced); Assert.False(model.CanChooseAdvanced);
        model.Confirm(true); await model.SubmitAsync(); Assert.Equal(0, fake.Creates);
        model.SelectOperatingSystem(null); Assert.Null(model.Draft!.Advanced); model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(1, fake.Creates); Assert.Null(fake.LastRequest!.Advanced);
    }
    [Fact]
    public async Task FrozenAdvancedResourcesCannotReusePriorConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.AdvancedAvailable = true; await model.RefreshAsync();
        model.SelectOperatingSystem(VirtualMachineOperatingSystem.Other); model.Confirm(true);
        fake.AdvancedFrozen = true; await model.RefreshAsync(); model.Confirm(true); await model.SubmitAsync();
        Assert.False(model.CanSubmit); Assert.False(model.CanChooseAdvanced); Assert.Equal(0, fake.Creates);
    }
    public class Fake : DispatchProxy
    {
        public static readonly Guid Profile = Guid.Parse("11111111-1111-1111-1111-111111111111");
        public bool Writable = true, NoStorage, PreflightFailure, MissingReview;
        public bool AdvancedAvailable, AdvancedFail, AdvancedFrozen;
        public static VirtualMachineCreationStorage AdvancedStorage => new("storage", "Pool", "host", "Host", 0, "107374182400", "0", "online", "healthy");
        public static VirtualMachineCreationImage AdvancedImage => new("iso", "ISO", "storage", "host", "iso", "online", "healthy");
        public bool PowerAvailable = true;
        public bool ContinueFailure;
        public MutationErrorCategory? ErrorCategory;
        public int Creates, Continues, Reviews;
        public CancellationToken Token;
        public VirtualMachineCreationStage Stage = VirtualMachineCreationStage.Complete;
        public VirtualMachineCreationRequest? LastRequest;
        public VirtualMachineCreationRecovery? Recovery;
        public Task<VirtualMachineCreationResult>? Delayed;
        protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
        {
            "get_ProfileId" => Profile, "get_CanCreateMachine" => Writable, "get_CanControlPower" => PowerAvailable, "get_CanCreateAdvancedMachine" => AdvancedAvailable,
            "LoadAdvancedCreationInventoryAsync" => AdvancedFail ? Task.FromException<VirtualMachineAdvancedCreationInventory>(new IOException("synthetic")) :
                Task.FromResult(new VirtualMachineAdvancedCreationInventory(Profile, AdvancedFrozen, false, [AdvancedStorage], [AdvancedImage])),
            "GetCreationRecoveriesAsync" => Task.FromResult<IReadOnlyList<VirtualMachineCreationRecovery>>(Recovery is null ? [] : [Recovery]),
            "LoadSnapshotAsync" => Task.FromResult(new VirtualMachineManagerSnapshot(Profile, VirtualMachineManagerSection<VirtualMachineSummary>.Available([]), Resources(),
                Resources(NoStorage ? [] : [new("storage", "Pool", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy)]), Resources(), Resources(), Resources(), VirtualMachineManagerSection<ServiceEventSummary>.Available([]))),
            "CreateMachineAsync" => Create((VirtualMachineCreationRequest)args![0]!, (CancellationToken)args[1]!),
            "ReviewCreationAsync" => Review(), "ContinueCreationAsync" => Continue((bool)args![1]!), _ => throw new NotSupportedException(method.Name)
        };
        private static VirtualMachineManagerSection<VirtualizationResourceSummary> Resources(params VirtualizationResourceSummary[] items) => VirtualMachineManagerSection<VirtualizationResourceSummary>.Available(items);
        private Task<VirtualMachineCreationResult> Create(VirtualMachineCreationRequest request, CancellationToken token)
        {
            Creates++; LastRequest = request; Token = token;
            return Delayed ?? Task.FromResult(PreflightFailure ? new VirtualMachineCreationResult(request.RequestId, VirtualMachineCreationStage.Rejected,
                new(1, MutationResultStatus.ConfirmedFailure, "createVirtualMachine", false, true, new(0, 1, 0), MutationErrorCategory.Conflict)) : Result(Stage));
        }
        private Task<VirtualMachineCreationResult?> Review() { Reviews++; return Task.FromResult<VirtualMachineCreationResult?>(MissingReview ? null : Result(Stage)); }
        private Task<VirtualMachineCreationResult?> Continue(bool confirmed) { Assert.True(confirmed); Continues++; return ContinueFailure ? Task.FromException<VirtualMachineCreationResult?>(new IOException("synthetic")) : Task.FromResult<VirtualMachineCreationResult?>(Result(VirtualMachineCreationStage.Complete)); }
        public VirtualMachineCreationResult Result(VirtualMachineCreationStage stage) => new(LastRequest!.RequestId, stage,
            new(1, stage == VirtualMachineCreationStage.Complete ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified, "createVirtualMachine", true, true,
                stage == VirtualMachineCreationStage.Complete ? new(2, 0, 0) : new(0, 0, 1), ErrorCategory), CanContinue: stage is VirtualMachineCreationStage.Configure or VirtualMachineCreationStage.PowerOn);
    }
}
