using System.Reflection;
using LanStash.App.Features.VirtualMachines;
using LanStash.Domain;
using LanStash.Tests.Chat;

namespace LanStash.Tests.VirtualMachines;

public sealed class VirtualMachineImageImportViewModelTests
{
    private static async Task<(Fake Fake, VirtualMachineImageImportViewModel Model, ManualRefreshTimeProvider Time)> Ready()
    {
        var repository = DispatchProxy.Create<IVirtualMachineManagerRepository, Fake>(); var time = new ManualRefreshTimeProvider();
        var model = new VirtualMachineImageImportViewModel(repository, time); await model.RefreshAsync();
        model.Edit("Image", "/share/image.iso", VirtualMachineImageType.Iso, model.Storages);
        return ((Fake)repository, model, time);
    }
    [Fact]
    public async Task EveryEditInvalidatesConfirmationAndSubmissionCannotRepeat()
    {
        var (fake, model, _) = await Ready(); using var owned = model;
        await model.SubmitAsync(); Assert.Equal(0, fake.Imports);
        model.Confirm(true); Assert.True(model.CanSubmit);
        model.Edit("Image", "/share/other.iso", VirtualMachineImageType.Iso, model.Storages); Assert.False(model.CanSubmit);
        model.Confirm(true); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(1, fake.Imports); Assert.True(model.CanNew); Assert.True(model.NeedsParentRefresh);
    }
    [Fact]
    public async Task MutatingExposedDraftCannotChangeAlreadyConfirmedSelection()
    {
        var (fake, model, _) = await Ready(); using var owned = model; model.Confirm(true);
        ((VirtualizationResourceSummary[])model.Draft!.Storages)[0] = new("other", "Other", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy);
        await model.SubmitAsync(); Assert.False(model.CanSubmit); Assert.Equal(0, fake.Imports);
    }
    [Theory]
    [InlineData(true)][InlineData(false)]
    public async Task ReadOnlyOrMissingStorageNeverSubmits(bool readOnly)
    {
        var (fake, model, _) = await Ready(); using var owned = model;
        fake.Writable = !readOnly; fake.Empty = !readOnly; await model.RefreshAsync(); model.Confirm(true); await model.SubmitAsync();
        Assert.Equal(0, fake.Imports); Assert.False(model.CanSubmit);
    }
    [Fact]
    public async Task PendingPollsOnlyReadsAndStopsAfterCompletion()
    {
        var (fake, model, time) = await Ready(); using var owned = model; fake.Stage = VirtualMachineImageImportStage.Importing;
        model.Confirm(true); await model.SubmitAsync(); Assert.Equal(1, time.ActiveTimers);
        fake.Stage = VirtualMachineImageImportStage.Complete; time.Advance(TimeSpan.FromSeconds(2));
        await fake.ReadObserved.Task.WaitAsync(TimeSpan.FromSeconds(5));
        for (var i = 0; i < 100 && !model.CanNew; i++) await Task.Delay(10);
        Assert.True(model.CanNew); Assert.Equal(1, fake.Imports); Assert.Equal(1, fake.Reviews); Assert.Equal(0, time.ActiveTimers);
    }
    [Fact]
    public async Task AuthenticationStopsPollingAndManualReview()
    {
        var (fake, model, time) = await Ready(); using var owned = model; fake.Error = MutationErrorCategory.Authentication; fake.Stage = VirtualMachineImageImportStage.Importing;
        model.Confirm(true); await model.SubmitAsync(); await model.RefreshAsync();
        Assert.False(model.CanRefresh); Assert.Equal(0, fake.Reviews); Assert.Equal(0, time.ActiveTimers); Assert.NotNull(model.ActiveRequest);
    }
    [Fact]
    public async Task ClosingCancelsPendingCallAndDiscardsLateSuccess()
    {
        var (fake, model, _) = await Ready(); var pending = new TaskCompletionSource<VirtualMachineImageImportResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        fake.Delayed = pending.Task; model.Confirm(true); var submitting = model.SubmitAsync();
        model.Dispose(); Assert.True(fake.Token.IsCancellationRequested);
        pending.SetResult(fake.Result()); await submitting; Assert.Null(model.Result); Assert.False(model.CanSubmit);
    }
    [Fact]
    public async Task MissingReceiptIsNotPolledOrResubmittedAndRecoveryOnlyReads()
    {
        var (fake, model, time) = await Ready(); using var owned = model; fake.Stage = VirtualMachineImageImportStage.VerifyReceipt;
        model.Confirm(true); await model.SubmitAsync(); Assert.Equal(0, time.ActiveTimers);
        await model.RefreshAsync(); Assert.Equal(1, fake.Imports); Assert.Equal(1, fake.Reviews);
        var proxy = (IVirtualMachineManagerRepository)(object)fake;
        using var reopened = new VirtualMachineImageImportViewModel(proxy, new ManualRefreshTimeProvider());
        await reopened.RefreshAsync(); await reopened.SelectRecoveryAsync(Assert.Single(reopened.Recoveries));
        Assert.Equal(1, fake.Imports); Assert.Equal(2, fake.Reviews); Assert.False(reopened.CanSubmit);
    }
    public class Fake : DispatchProxy
    {
        private static readonly Guid Profile = Guid.Parse("11111111-1111-1111-1111-111111111111");
        public bool Writable = true, Empty;
        public int Imports, Reviews;
        public VirtualMachineImageImportStage Stage = VirtualMachineImageImportStage.Complete;
        public MutationErrorCategory? Error;
        public VirtualMachineImageImportRequest? Request;
        public CancellationToken Token;
        public Task<VirtualMachineImageImportResult>? Delayed;
        public TaskCompletionSource ReadObserved { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
        {
            "get_ProfileId" => Profile, "get_CanImportImages" => Writable,
            "LoadImageImportStoragesAsync" => Task.FromResult<IReadOnlyList<VirtualizationResourceSummary>>(Empty ? [] : [new("store", "Storage", VirtualizationResourceKind.Storage, VirtualizationResourceHealth.Healthy)]),
            "GetImageImportRecoveriesAsync" => Task.FromResult<IReadOnlyList<VirtualMachineImageImportRequest>>(Request is null ? [] : [Request with { RiskConfirmed = false }]),
            "ImportImageAsync" => Import((VirtualMachineImageImportRequest)args![0]!, (CancellationToken)args[1]!),
            "ReviewImageImportAsync" => Review(), _ => throw new NotSupportedException(method.Name)
        };
        private Task<VirtualMachineImageImportResult> Import(VirtualMachineImageImportRequest request, CancellationToken token)
        { Imports++; Request = request; Token = token; return Delayed ?? Task.FromResult(Result()); }
        private Task<VirtualMachineImageImportResult?> Review() { Reviews++; ReadObserved.TrySetResult(); return Task.FromResult<VirtualMachineImageImportResult?>(Result()); }
        public VirtualMachineImageImportResult Result() => new(Request!.RequestId, Stage,
            new(1, Stage == VirtualMachineImageImportStage.Complete ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
                "virtualMachineImageImport", true, true, Stage == VirtualMachineImageImportStage.Complete ? new(1, 0, 0) : new(0, 0, 1), Error));
    }
}
