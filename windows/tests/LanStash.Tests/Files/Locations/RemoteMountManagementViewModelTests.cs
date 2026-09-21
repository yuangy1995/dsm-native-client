using System.Reflection;
using System.Text.Json;
using LanStash.App.Features.Files.Locations;
using LanStash.Domain;

namespace LanStash.Tests.Files.Locations;

public sealed class RemoteMountManagementViewModelTests
{
    private static async Task<(Fake Fake, RemoteMountManagementViewModel Model)> Ready()
    {
        var repository = DispatchProxy.Create<IFileLocationsRepository, Fake>(); var fake = (Fake)repository;
        var model = new RemoteMountManagementViewModel(); await model.ActivateAsync(repository); model.ChangeDraft(Setup); return (fake, model);
    }
    private static readonly RemoteMountSetup Setup = new("server.invalid", "share", "/share/mount", "synthetic-user");

    [Fact]
    public async Task ExactConfirmationRequiredAndCompletedOperationCannotRepeat()
    {
        var (fake, model) = await Ready(); using var owned = model;
        await model.SubmitAsync(null); Assert.Empty(fake.Writes);
        Assert.True(model.Confirm(true)); model.ChangeDraft(Setup with { MountPoint = "/share/changed" });
        await model.SubmitAsync(null); Assert.Empty(fake.Writes);
        Assert.True(model.Confirm(true)); await model.SubmitAsync(" synthetic secret "); await model.SubmitAsync(null);
        Assert.Single(fake.Writes); Assert.Equal(" synthetic secret ", fake.Writes[0].Desired!.Password);
        Assert.Equal(RemoteMountStage.Complete, model.Progress!.Stage); Assert.False(model.CanConfirm);
        Assert.DoesNotContain("synthetic secret", JsonSerializer.Serialize(model.Draft));
        Assert.DoesNotContain("synthetic secret", JsonSerializer.Serialize(model.Progress));
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ReadOnlyOrFailedInventoryCannotSubmit(bool failedLoad)
    {
        var repository = DispatchProxy.Create<IFileLocationsRepository, Fake>(); var fake = (Fake)repository;
        fake.Writable = false; fake.FailLoad = failedLoad;
        using var model = new RemoteMountManagementViewModel(); await model.ActivateAsync(repository); model.ChangeDraft(Setup);
        Assert.False(model.Confirm(true)); await model.SubmitAsync(null); Assert.Empty(fake.Writes);
        if (failedLoad) Assert.NotNull(model.ErrorMessage);
    }
    [Fact]
    public async Task CapabilityRevocationInvalidatesExistingConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model;
        model.Confirm(true); fake.Writable = false; await model.SubmitAsync(null); Assert.Empty(fake.Writes);
    }
    [Fact]
    public async Task NfsConfigurationAndRemoteTargetAreEditableButInvalidOptionsCannotSubmit()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Seed(); await model.ReloadAsync(); model.SelectConnection(fake.Rows[0]);
        model.ChangeDraft(new("nfs.invalid", "export", "/share/new", Protocol: FileRemoteProtocol.Nfs,
            NfsVersion: RemoteMountNfsVersion.V4, NfsTransport: RemoteMountNfsTransport.Udp));
        Assert.False(model.Confirm(true)); Assert.NotNull(model.ValidationMessage);
        model.ChangeDraft(model.Draft with { NfsTransport = RemoteMountNfsTransport.Tcp }); Assert.True(model.Confirm(true));
        await model.SubmitAsync("must-not-send"); var request = Assert.Single(fake.Writes);
        Assert.Equal("/share/new", request.Desired!.MountPoint); Assert.Equal(RemoteMountNfsVersion.V4, request.Desired.NfsVersion);
        Assert.Null(request.Desired.Password); Assert.Equal(fake.Rows[0], request.Baseline);
    }
    [Fact]
    public async Task DisconnectUsesFrozenBaselineAndNeverIncludesPasswordOrDesiredDraft()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Seed(); await model.ReloadAsync(); model.SelectConnection(fake.Rows[0]); model.SetAction(RemoteMountAction.Disconnect);
        Assert.False(model.CanEdit); Assert.False(model.NeedsPassword); Assert.True(model.Confirm(true));
        await model.SubmitAsync("must-not-send"); var request = Assert.Single(fake.Writes);
        Assert.Null(request.Desired); Assert.Equal(fake.Rows[0], request.Baseline);
    }
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ReopeningPendingOperationRestoresOnlyNonPasswordFields(bool changedTarget)
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.Seed(); await model.ReloadAsync(); model.SelectConnection(fake.Rows[0]);
        if (changedTarget) model.ChangeDraft(model.Draft with { MountPoint = "/share/new" });
        fake.NextStage = changedTarget ? RemoteMountStage.ReadyToDisconnectPrevious : RemoteMountStage.ReadyToConnect;
        model.Confirm(true); await model.SubmitAsync("first-secret");
        using var reopened = new RemoteMountManagementViewModel(); await reopened.ActivateAsync((IFileLocationsRepository)fake);
        Assert.Equal(fake.NextStage, reopened.Progress!.Stage); Assert.False(reopened.CanEdit); Assert.False(reopened.CanSubmit);
        Assert.Equal(!changedTarget, reopened.NeedsPassword); Assert.DoesNotContain("first-secret", JsonSerializer.Serialize(reopened.Draft));
        fake.NextStage = RemoteMountStage.Complete; Assert.True(reopened.Confirm(true)); await reopened.SubmitAsync("reentered-secret");
        Assert.Equal(2, fake.Writes.Count); Assert.Equal(fake.Writes[0].RequestId, fake.Writes[1].RequestId);
        Assert.Equal(changedTarget ? null : "reentered-secret", fake.Writes[1].Desired!.Password);
        Assert.Equal(1, fake.Continues);
    }
    [Fact]
    public async Task UnknownResultAllowsOnlyReviewAndBlocksOverlappingNewDraft()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.NextStage = RemoteMountStage.VerifyingConnection;
        model.Confirm(true); await model.SubmitAsync(null);
        Assert.False(model.CanEdit); Assert.False(model.CanConfirm); Assert.True(model.CanReview);
        await model.SubmitAsync(null); await model.ReloadAsync(); Assert.Single(fake.Writes);
        model.NewConnection(); model.ChangeDraft(Setup with { MountPoint = "/share/mount/child" }); Assert.False(model.Confirm(true));
        model.SelectPending(model.Pending[0]); fake.NextStage = RemoteMountStage.Complete; await model.ReviewAsync();
        Assert.Equal(1, fake.Reviews); Assert.Single(fake.Writes); Assert.Empty(model.Pending);
    }
    [Fact]
    public async Task ReviewNeverPerformsTheNextWriteOrRetainsConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Seed(); await model.ReloadAsync(); model.SelectConnection(fake.Rows[0]);
        fake.NextStage = RemoteMountStage.VerifyingDisconnection; model.Confirm(true); await model.SubmitAsync("secret");
        fake.NextStage = RemoteMountStage.ReadyToConnect; await model.ReviewAsync();
        Assert.True(model.CanConfirm); Assert.False(model.CanSubmit); Assert.Single(fake.Writes);
    }
    [Fact]
    public async Task PendingReadFailureDoesNotCreateNewRequestOnRepeatedClick()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.ThrowWrite = true;
        model.Confirm(true); await model.SubmitAsync(null); await model.SubmitAsync(null);
        Assert.Single(fake.Writes); Assert.Single(model.Pending); Assert.True(model.CanReview); Assert.False(model.CanConfirm);
        fake.MissingReview = true; await model.ReviewAsync(); Assert.NotNull(model.ErrorMessage); Assert.False(model.CanConfirm);
        await model.ReloadAsync(); model.NewConnection(); model.ChangeDraft(Setup);
        Assert.Single(model.Pending); Assert.False(model.Confirm(true)); await model.SubmitAsync(null); Assert.Single(fake.Writes);
    }
    [Fact]
    public async Task FilteringAwaySelectionClearsConfirmationAndShowsNoMatches()
    {
        var (fake, model) = await Ready(); using var owned = model; fake.Seed(); await model.ReloadAsync(); model.SelectConnection(fake.Rows[0]); model.Confirm(true);
        model.SetFilter("does-not-match"); Assert.Empty(model.FilteredConnections); Assert.Null(model.SelectedConnection); Assert.False(model.CanSubmit);
    }
    [Fact]
    public async Task DisappearedPreferredTargetShowsConflictInsteadOfSelectingAnotherConnection()
    {
        var repository = DispatchProxy.Create<IFileLocationsRepository, Fake>(); var fake = (Fake)repository; fake.Seed();
        using var model = new RemoteMountManagementViewModel(); await model.ActivateAsync(repository, "/share/missing", RemoteMountAction.Disconnect);
        Assert.NotNull(model.ErrorMessage); Assert.Null(model.SelectedConnection); Assert.False(model.CanConfirm);
    }
    [Fact]
    public async Task ConcurrentClickAndDeactivateCannotPublishLateWriteResult()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var gate = new TaskCompletionSource<RemoteMountProgress>(TaskCreationOptions.RunContinuationsAsynchronously); fake.WriteTask = gate.Task;
        model.Confirm(true); var submitting = model.SubmitAsync("secret"); await model.SubmitAsync("secret"); Assert.Single(fake.Writes);
        model.Deactivate(); Assert.True(fake.Token.IsCancellationRequested);
        gate.SetResult(fake.Result(fake.Writes[0])); await submitting;
        Assert.Null(model.Progress); Assert.Empty(model.Pending); Assert.Equal("", model.Draft.Server); Assert.False(model.CanConfirm);
    }

    public class Fake : DispatchProxy
    {
        public Guid Id { get; } = Guid.NewGuid();
        public List<RemoteMountConnection> Rows { get; } = [];
        public List<RemoteMountProgress> Pending { get; } = [];
        public List<RemoteMountMutationRequest> Writes { get; } = [];
        public bool Writable = true, FailLoad, ThrowWrite, MissingReview;
        public int Continues, Reviews;
        public RemoteMountStage NextStage = RemoteMountStage.Complete;
        public CancellationToken Token;
        public Task<RemoteMountProgress>? WriteTask;
        public void Seed() => Rows.Add(new(Id, "/share/mount", "//server.invalid/share", FileRemoteProtocol.Cifs, false));
        public RemoteMountProgress Result(RemoteMountMutationRequest request)
        {
            var complete = NextStage == RemoteMountStage.Complete; var ready = NextStage is RemoteMountStage.ReadyToConnect or RemoteMountStage.ReadyToDisconnectPrevious;
            return new(request.RequestId, request.Action, request.Desired?.MountPoint ?? request.Baseline!.MountPoint, request.Baseline?.MountPoint, NextStage,
                new(1, complete ? MutationResultStatus.ConfirmedSuccess : ready ? MutationResultStatus.PartialSuccess : MutationResultStatus.SubmittedButUnverified,
                    "remoteMount", true, true, new(complete || ready ? 1 : 0, 0, complete ? 0 : 1)),
                new(request.Baseline, request.Desired is null ? null : RemoteMountSetup.FromDraft(request.Desired)));
        }
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_ProfileId": return Id;
                case "get_CanManageRemoteMountWorkflow": return Writable;
                case "LoadRemoteMountInventoryAsync": return FailLoad ? Task.FromException<RemoteMountInventory>(new IOException()) : Task.FromResult(new RemoteMountInventory(Id, true, Rows.ToArray()));
                case "GetRemoteMountOperationsAsync": return Task.FromResult<IReadOnlyList<RemoteMountProgress>>(Pending.ToArray());
                case "StartRemoteMountOperationAsync":
                case "ContinueRemoteMountOperationAsync":
                    if (method.Name.StartsWith("Continue", StringComparison.Ordinal)) Continues++;
                    var request = (RemoteMountMutationRequest)args![0]!; Token = (CancellationToken)args[1]!; Writes.Add(request);
                    if (WriteTask is not null) return WriteTask;
                    if (ThrowWrite) return Task.FromException<RemoteMountProgress>(new IOException());
                    var result = Result(request); Pending.RemoveAll(item => item.RequestId == request.RequestId);
                    if (result.Stage != RemoteMountStage.Complete) Pending.Add(result); return Task.FromResult(result);
                case "ReviewRemoteMountOperationAsync":
                    Reviews++; if (MissingReview) return Task.FromResult<RemoteMountProgress?>(null);
                    var reviewed = Result(Writes.Last()); Pending.Clear(); if (reviewed.Stage != RemoteMountStage.Complete) Pending.Add(reviewed);
                    return Task.FromResult<RemoteMountProgress?>(reviewed);
                default: throw new NotSupportedException(method.Name);
            }
        }
    }
}
