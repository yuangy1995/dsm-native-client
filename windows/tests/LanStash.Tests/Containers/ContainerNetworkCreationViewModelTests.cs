using System.Reflection;
using LanStash.App.Features.Containers;
using LanStash.Domain;

namespace LanStash.Tests.Containers;

public sealed class ContainerNetworkCreationViewModelTests
{
    private static async Task<(Fake Fake, ContainerNetworkCreationViewModel Model)> Ready()
    {
        var repository = DispatchProxy.Create<IContainerManagerRepository, Fake>(); var fake = (Fake)repository;
        var model = new ContainerNetworkCreationViewModel(); await model.ActivateAsync(repository); model.ChangeDraft(new("synthetic")); return (fake, model);
    }
    [Fact]
    public async Task ConfirmationIsBoundToExactDraftAndSuccessfulNameCannotRepeat()
    {
        var (fake, model) = await Ready(); using var owned = model;
        await model.SubmitAsync(); Assert.Equal(0, fake.Writes);
        Assert.True(model.Confirm(true)); model.ChangeDraft(model.Draft with { Name = "changed" });
        await model.SubmitAsync(); Assert.Equal(0, fake.Writes);
        Assert.True(model.Confirm(true)); await model.SubmitAsync(); await model.SubmitAsync(); Assert.Equal(1, fake.Writes);
        Assert.True(model.WasSuccessful); Assert.False(model.Confirm(true)); Assert.True(model.IsNameBlocked);
        model.ChangeDraft(new("another")); Assert.True(model.CanConfirm);
    }
    [Fact]
    public async Task ReadOnlyInvalidAndRevokedCapabilitiesDoNotSubmit()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Writable = false; Assert.True(model.CanEdit); Assert.False(model.Confirm(true));
        fake.Writable = true; model.ChangeDraft(new("bad name")); Assert.NotNull(model.ValidationMessage); Assert.False(model.Confirm(true));
        model.ChangeDraft(new("valid")); model.Confirm(true); fake.Writable = false;
        await model.SubmitAsync(); Assert.Equal(0, fake.Writes);
    }
    [Fact]
    public async Task UnknownNameRemainsBlockedDuringConfigurationEditsAndReloadDoesNotReplay()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Unknown = true;
        model.Confirm(true); await model.SubmitAsync(); Assert.Single(model.Pending);
        model.ChangeDraft(model.Draft with { DisableMasquerade = true }); Assert.False(model.Confirm(true));
        await model.ReloadAsync(); Assert.Single(model.Pending); Assert.Equal(1, fake.Writes);
        fake.Resolve = true; await model.ReloadAsync(); Assert.Empty(model.Pending); Assert.True(model.WasSuccessful);
        Assert.True(model.IsNameBlocked); Assert.Equal(1, fake.Writes);
    }
    [Fact]
    public async Task AdvancedOptionsUnknownIsNotSuccess()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Unknown = true; fake.OptionsUnknown = true;
        model.ChangeDraft(new("synthetic", DisableMasquerade: true)); model.Confirm(true); await model.SubmitAsync();
        Assert.False(model.WasSuccessful); Assert.Equal("container.network.created-options-unverified", model.LastResult!.DiagnosticTag);
        Assert.Single(model.Pending); Assert.False(model.CanSubmit);
    }
    [Fact]
    public async Task ConcurrentSubmissionAndProfileChangeCannotReuseConfirmationOrLateFeedback()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var completed = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = completed.Task;
        model.Confirm(true); var saving = model.SubmitAsync(); await model.SubmitAsync(); await model.ReloadAsync(); Assert.Equal(1, fake.Writes);
        await model.ActivateAsync(DispatchProxy.Create<IContainerManagerRepository, Fake>()); Assert.True(fake.Token.IsCancellationRequested);
        completed.SetResult(Success()); await saving; Assert.Null(model.LastResult); Assert.Equal("", model.Draft.Name);
    }
    [Fact]
    public async Task FailedPreparationDoesNotEnableSubmission()
    {
        var repository = DispatchProxy.Create<IContainerManagerRepository, Fake>(); var fake = (Fake)repository; fake.FailLoad = true;
        using var model = new ContainerNetworkCreationViewModel(); await model.ActivateAsync(repository);
        Assert.NotNull(model.ErrorMessage); Assert.False(model.CanEdit); Assert.False(model.CanConfirm);
        fake.FailLoad = false; await model.ReloadAsync(); model.ChangeDraft(new("valid")); Assert.True(model.CanConfirm);
    }
    private static MutationResult Success() => new(1, MutationResultStatus.ConfirmedSuccess, "createContainerNetwork", true, false, new(1, 0, 0));
    private static MutationResult Unknown(bool options = false) => new(1, MutationResultStatus.SubmittedButUnverified, "createContainerNetwork", true, true, new(0, 0, 1),
        diagnosticTag: options ? "container.network.created-options-unverified" : "container.network.create.unverified");
    public class Fake : DispatchProxy
    {
        public bool Writable { get; set; } = true; public bool Unknown { get; set; } public bool OptionsUnknown { get; set; } public bool Resolve { get; set; } public bool FailLoad { get; set; }
        public int Writes { get; private set; } public CancellationToken Token { get; private set; }
        public List<ContainerNetworkCreationRecovery> Pending { get; } = [];
        public Task<MutationResult>? WriteTask { get; set; }
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_ProfileId": return Guid.Parse("11111111-1111-1111-1111-111111111111");
                case "get_CanCreateNetworks": return Writable;
                case "PrepareNetworkManagementAsync": return FailLoad ? Task.FromException(new IOException("合成状态核查失败")) : Task.CompletedTask;
                case "GetNetworkCreationRecoveriesAsync": return Task.FromResult<IReadOnlyList<ContainerNetworkCreationRecovery>>(Pending.ToArray());
                case "ReviewNetworkCreationAsync": if (Resolve) Pending.Clear(); return Task.FromResult<MutationResult?>(Resolve ? Success() : ContainerNetworkCreationViewModelTests.Unknown(OptionsUnknown));
                case "CreateNetworkAsync":
                    var request = (ContainerNetworkCreateRequest)args![0]!; Writes++; Token = (CancellationToken)args[1]!;
                    if (WriteTask is not null) return WriteTask;
                    if (Unknown) { Pending.Add(new(request.Configuration.Name)); return Task.FromResult(ContainerNetworkCreationViewModelTests.Unknown(OptionsUnknown)); }
                    return Task.FromResult(Success());
                default: throw new NotSupportedException(method.Name);
            }
        }
    }
}
