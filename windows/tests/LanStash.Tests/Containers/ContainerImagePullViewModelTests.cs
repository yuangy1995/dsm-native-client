using System.Reflection;
using LanStash.App.Features.Containers;
using LanStash.Domain;

namespace LanStash.Tests.Containers;

public sealed class ContainerImagePullViewModelTests
{
    private static async Task<(Fake Fake, ContainerImagePullViewModel Model)> Ready()
    {
        var repository = DispatchProxy.Create<IContainerManagerRepository, Fake>(); var fake = (Fake)repository;
        var model = new ContainerImagePullViewModel(); await model.ActivateAsync(repository); model.SetTarget("synthetic/web", "stable");
        return (fake, model);
    }
    [Fact]
    public async Task ConfirmationIsBoundToTargetAndRepeatedClicksDoNotStartAgain()
    {
        var (fake, model) = await Ready(); using var owned = model;
        await model.SubmitAsync(); Assert.Equal(0, fake.Starts);
        model.Confirm(true); model.SetTarget("synthetic/web", "latest"); Assert.False(model.CanSubmit);
        model.Confirm(true); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(1, fake.Starts); Assert.Equal("latest", fake.LastRequest!.Tag); Assert.False(model.CanConfirm);
        Assert.True(model.HasPollableTasks); Assert.True(model.NeedsParentRefresh);
    }
    [Fact]
    public async Task AutomaticReviewKeepsUnsubmittedConfirmationAndDoesNotReplay()
    {
        var (fake, model) = await Ready(); using var owned = model;
        model.Confirm(true); await model.SubmitAsync(); model.SetTarget("synthetic/other", "stable"); model.Confirm(true);
        var reviews = fake.Reviews; await model.ReviewAsync(automatic: true);
        Assert.Equal(reviews + 1, fake.Reviews); Assert.True(model.HasConfirmation); Assert.True(model.CanSubmit); Assert.Equal(1, fake.Starts);
        await model.ReviewAsync(); Assert.False(model.HasConfirmation);
    }
    [Fact]
    public async Task CompletionStopsAutomaticPollingAndAllowsFreshConfirmation()
    {
        var (fake, model) = await Ready(); using var owned = model;
        model.Confirm(true); await model.SubmitAsync(); fake.Stage = ContainerImagePullStage.Ready;
        await model.ReviewAsync(automatic: true); var reads = fake.Reviews;
        await model.ReviewAsync(automatic: true);
        Assert.Equal(reads, fake.Reviews); Assert.False(model.HasPollableTasks); Assert.True(model.CanConfirm); Assert.False(model.CanSubmit);
        Assert.Equal(ContainerImagePullStage.Ready, Assert.Single(model.Items).Result.Stage);
    }
    [Fact]
    public async Task MissingReceiptAndUnexpectedExceptionBlockResubmitWithoutAutomaticPolling()
    {
        var (fake, model) = await Ready(); using var owned = model;
        fake.StartTask = Task.FromException<ContainerImagePullResult>(new IOException("合成回执丢失"));
        model.Confirm(true); await model.SubmitAsync(); var reads = fake.Reviews;
        await model.ReviewAsync(automatic: true); await model.SubmitAsync();
        Assert.Equal(ContainerImagePullStage.AwaitingReceipt, Assert.Single(model.Items).Result.Stage);
        Assert.False(model.CanConfirm); Assert.Equal(1, fake.Starts); Assert.Equal(reads, fake.Reviews);
    }
    [Fact]
    public async Task ReopeningLoadsRecoveryWithoutStartingNewTask()
    {
        var (fake, model) = await Ready(); model.Confirm(true); await model.SubmitAsync(); model.Dispose();
        using var reopened = new ContainerImagePullViewModel(); await reopened.ActivateAsync((IContainerManagerRepository)(object)fake);
        reopened.SetTarget("synthetic/web", "stable"); Assert.False(reopened.CanConfirm);
        Assert.Single(reopened.Items); Assert.Equal(1, fake.Starts); Assert.True(fake.Reviews > 0);
    }

    [Fact]
    public async Task CachedAuthenticationErrorDoesNotDisableSuccessfulReconnectedReview()
    {
        var (fake, model) = await Ready(); model.Confirm(true); await model.SubmitAsync(); model.Dispose();
        fake.CachedAuthenticationFailure = true;
        using var reopened = new ContainerImagePullViewModel(); await reopened.ActivateAsync((IContainerManagerRepository)(object)fake);
        Assert.False(reopened.RequiresReconnect); Assert.True(reopened.HasPollableTasks);
        Assert.Equal(ContainerImagePullStage.Downloading, Assert.Single(reopened.Items).Result.Stage);
        Assert.Equal(1, fake.Starts);
    }
    [Fact]
    public async Task ProfileChangeCancelsOldWaitAndIgnoresLateCompletion()
    {
        var (fake, model) = await Ready(); using var owned = model;
        var completion = new TaskCompletionSource<ContainerImagePullResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        fake.StartTask = completion.Task; model.Confirm(true); var starting = model.SubmitAsync();
        var request = fake.LastRequest!; var token = fake.LastToken;
        await model.ActivateAsync(DispatchProxy.Create<IContainerManagerRepository, Fake>());
        Assert.True(token.IsCancellationRequested); completion.SetResult(Fake.Result(request, ContainerImagePullStage.Ready)); await starting;
        Assert.Empty(model.Items); Assert.False(model.CanConfirm); Assert.False(model.NeedsParentRefresh);
    }
    [Fact]
    public async Task DisposingCancelsLocalWaitButDoesNotSendNasCancellation()
    {
        var (fake, model) = await Ready();
        var completion = new TaskCompletionSource<ContainerImagePullResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        fake.StartTask = completion.Task; model.Confirm(true); var starting = model.SubmitAsync(); var token = fake.LastToken;
        model.Dispose(); Assert.True(token.IsCancellationRequested); completion.SetResult(Fake.Result(fake.LastRequest!, ContainerImagePullStage.Downloading)); await starting;
        Assert.False(model.IsBusy); Assert.Empty(model.Items); Assert.True(model.NeedsParentRefresh); Assert.Equal(1, fake.Starts);
    }
    [Fact]
    public async Task RevokedCapabilityDoesNotSendConfirmedRequest()
    {
        var (fake, model) = await Ready(); using var owned = model;
        model.Confirm(true); fake.Writable = false; await model.SubmitAsync(); Assert.Equal(0, fake.Starts); Assert.False(model.CanSubmit);
    }
    public class Fake : DispatchProxy
    {
        private readonly Guid _profile = Guid.NewGuid();
        public bool Writable { get; set; } = true;
        public bool CachedAuthenticationFailure { get; set; }
        public int Starts { get; private set; }
        public int Reviews { get; private set; }
        public ContainerImagePullStage Stage { get; set; } = ContainerImagePullStage.Downloading;
        public ContainerImagePullRequest? LastRequest { get; private set; }
        public CancellationToken LastToken { get; private set; }
        public Task<ContainerImagePullResult>? StartTask { get; set; }
        private ContainerImagePullResult? _pending;
        protected override object? Invoke(MethodInfo? method, object?[]? args)
        {
            switch (method!.Name)
            {
                case "get_ProfileId": return _profile;
                case "get_CanPullImages": return Writable;
                case "GetImagePullRecoveriesAsync": return Task.FromResult<IReadOnlyList<ContainerImagePullResult>>(_pending is null ? [] :
                    [CachedAuthenticationFailure ? _pending with { Outcome = new(1, MutationResultStatus.SubmittedButUnverified,
                        "pullContainerImage", true, true, new(0, 0, 1), MutationErrorCategory.Authentication) } : _pending]);
                case "PullImageAsync":
                    Starts++; LastRequest = (ContainerImagePullRequest)args![0]!; LastToken = (CancellationToken)args[1]!;
                    if (StartTask is not null) return StartTask;
                    _pending = Result(LastRequest, Stage); return Task.FromResult(_pending);
                case "ReviewImagePullAsync":
                    Reviews++; if (_pending is null) return Task.FromResult<ContainerImagePullResult?>(null);
                    var result = Result(LastRequest!, Stage); _pending = Stage == ContainerImagePullStage.Ready ? null : result;
                    return Task.FromResult<ContainerImagePullResult?>(result);
                default: throw new NotSupportedException(method.Name);
            }
        }
        public static ContainerImagePullResult Result(ContainerImagePullRequest request, ContainerImagePullStage stage) => new(request.RequestId, request.Repository, request.Tag, stage, 25,
            new(1, stage == ContainerImagePullStage.Ready ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
                "pullContainerImage", true, true, stage == ContainerImagePullStage.Ready ? new(1, 0, 0) : new(0, 0, 1)));
    }
}
