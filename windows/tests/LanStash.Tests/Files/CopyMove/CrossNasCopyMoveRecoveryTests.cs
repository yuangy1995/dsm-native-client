using LanStash.App.Features.Files.CopyMove;
using LanStash.Domain;

namespace LanStash.Tests.Files.CopyMove;

public sealed class CrossNasCopyMoveRecoveryTests
{
    private static readonly Guid SourceId = Guid.NewGuid(), TargetId = Guid.NewGuid();
    private static readonly FileItem File = new("/share/item", "item", false, 3, DateTimeOffset.UnixEpoch, null, true, true);
    private static readonly NasProfile Target = new(TargetId, "Target", "target.invalid", null, "synthetic");

    [Fact]
    public async Task UnknownHasReadOnlyRefreshAndCannotSubmitAgain()
    {
        var repository = new Repository(); using var model = Model(repository);
        await Choose(model); await model.SubmitAsync(); await model.SubmitAsync();
        Assert.Equal(CrossNasCopyMoveState.Recoverable, model.State); Assert.True(model.CanRefresh); Assert.Equal(1, repository.Copies);
        repository.Review = Outcome(MutationResultStatus.ConfirmedSuccess);
        await model.RefreshAsync(); Assert.Equal(CrossNasCopyMoveState.Completed, model.State);
        Assert.Equal(1, repository.Copies); Assert.Equal(1, repository.Reads);
    }

    [Fact]
    public async Task CancellationWaitsForOriginalOutcomeInsteadOfLeavingDialogTransferring()
    {
        var repository = new Repository { WaitForCancel = true }; using var model = Model(repository);
        await Choose(model); var transfer = model.SubmitAsync();
        await repository.Started.Task.WaitAsync(TimeSpan.FromSeconds(3)); model.Cancel();
        await transfer.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal(CrossNasCopyMoveState.Recoverable, model.State); Assert.True(model.CanRefresh);
        Assert.Equal(1, repository.Copies);
    }

    [Fact]
    public async Task ReopenedHistoryUsesOriginalIdentityAndOnlyReads()
    {
        var repository = new Repository(); using var model = Model(repository);
        await model.LoadHistoryAsync(); await model.RestoreAsync(Assert.Single(model.History));
        Assert.Equal(0, repository.Copies); Assert.Equal(1, repository.Reads);
        Assert.Equal(repository.Id, model.Outcome!.OperationId); Assert.Equal("/backup", model.DestinationPath);
    }

    [Fact]
    public async Task ExplicitContinueUsesRemainingStepInsteadOfStartingNewCopy()
    {
        var repository = new Repository { Review = Outcome(MutationResultStatus.ConfirmedFailure) with { CanContinue = true } };
        using var model = Model(repository); await model.LoadHistoryAsync(); await model.RestoreAsync(Assert.Single(model.History));
        Assert.True(model.CanContinue); await model.ContinueAsync();
        Assert.Equal(0, repository.Copies); Assert.Equal(1, repository.Continues);
        Assert.Equal(CrossNasCopyMoveState.Completed, model.State);
    }

    [Fact]
    public async Task LateTargetLeaseIsDisposedAfterPageCloses()
    {
        var completion = new TaskCompletionSource<IFileCopyMoveFolderSource?>(TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new Repository(); var model = Model(repository, (_, _) => completion.Task);
        var pending = model.SelectTargetAndLoadAsync(Target); model.Dispose();
        var lease = new Folders(); completion.SetResult(lease); await pending;
        Assert.Equal(1, lease.Disposals); Assert.Equal(0, lease.Loads); Assert.Equal(0, repository.Copies);
    }

    [Fact]
    public async Task SameFolderPathOnIndependentNasRemainsSelectable()
    {
        var repository = new Repository(); using var model = new CrossNasCopyMoveViewModel(repository, SourceId,
            File with { Path = "/share/folder", Name = "folder", IsDirectory = true }, FileCopyMoveOperation.Copy, [Target],
            (_, _) => Task.FromResult<IFileCopyMoveFolderSource?>(new Folders()));
        await model.SelectTargetAndLoadAsync(Target);
        Assert.Contains(model.Folders, item => item.Path == "/share/folder/child");
    }

    [Fact]
    public async Task OriginalOperationStillRunningRemainsRefreshableAndCannotBeStartedAgain()
    {
        var repository = new Repository { Review = Outcome(MutationResultStatus.ConfirmedFailure) with { IsRunning = true } };
        using var model = Model(repository); await model.LoadHistoryAsync(); await model.RestoreAsync(Assert.Single(model.History));
        Assert.Equal(CrossNasCopyMoveState.Recoverable, model.State); Assert.True(model.CanRefresh); Assert.False(model.CanSubmit);
        await model.SubmitAsync(); Assert.Equal(0, repository.Copies);
    }

    [Fact]
    public async Task GlobalHistoryCanOpenCompletedSourceDeletionWithoutSelectingOriginalFile()
    {
        var repository = new Repository { Review = Outcome(MutationResultStatus.ConfirmedSuccess) with
        {
            SourceDeletion = new(new(1, MutationResultStatus.ConfirmedSuccess, "crossNasDeleteSources", true, false, new(1, 0, 0)),
                [new(File.Path, false, CrossNasSourceDeletionState.Deleted)])
        } };
        using var history = new LanStash.App.Features.Files.FileOperationRecoveryViewModel(repository, SourceId, new FileCopyMoveReviewBlocker());
        await history.RefreshAsync();
        var saved = Assert.Single(history.Items); Assert.NotNull(saved.CrossNas); Assert.True(history.CanReview);
        await history.ReviewSelectedAsync(); Assert.Equal(0, repository.Reads);
        using var model = Model(repository); await model.LoadHistoryAsync(includeCompleted: true);
        await model.RestoreAsync(Assert.Single(model.History));
        Assert.Equal(CrossNasCopyMoveState.Completed, model.State);
        Assert.Equal(1, repository.Reads); Assert.Equal(0, repository.Copies); Assert.Equal(0, repository.Deletes);
    }

    [Fact]
    public async Task RestartedUnstartedBatchHasOnlyRefreshUntilOriginalReadOnlyRecoveryFinishes()
    {
        var repository = new Repository { Review = Outcome(MutationResultStatus.ConfirmedFailure) with { RequiresReadOnlyRecovery = true } };
        using var model = Model(repository); await model.LoadHistoryAsync(); await model.RestoreAsync(Assert.Single(model.History));
        Assert.True(model.CanRefresh); Assert.False(model.CanContinue); Assert.False(model.CanSubmit);
        await model.SubmitAsync(); Assert.Equal(0, repository.Copies);
    }

    [Fact]
    public async Task HistoryWithPreSubmissionCancellationCannotUseNewCopyButton()
    {
        var repository = new Repository { Review = new(new(1, MutationResultStatus.CancelledBeforeSubmission, "crossNasCopy", false, false, new(0, 0, 0)), File.Path, "/backup/item") };
        using var model = Model(repository); await model.LoadHistoryAsync(); await model.RestoreAsync(Assert.Single(model.History));
        Assert.False(model.CanSubmit); await model.SubmitAsync(); Assert.Equal(0, repository.Copies);
    }

    private static CrossNasCopyMoveViewModel Model(Repository repository, Func<Guid, CancellationToken, Task<IFileCopyMoveFolderSource?>>? factory = null) =>
        new(repository, SourceId, File, FileCopyMoveOperation.Copy, [Target], factory ?? ((_, _) => Task.FromResult<IFileCopyMoveFolderSource?>(new Folders())));

    [Fact]
    public async Task SourceDeletionRequiresSeparateConfirmationAndRefreshNeverReplaysIt()
    {
        var repository = new Repository { Review = Outcome(MutationResultStatus.ConfirmedSuccess) with { CanDeleteSources = true } };
        using var model = Model(repository); await model.LoadHistoryAsync(); await model.RestoreAsync(Assert.Single(model.History));
        Assert.Equal(CrossNasCopyMoveState.SourceDeletionReady, model.State); Assert.Equal(0, repository.Deletes);
        await model.ConfirmSourceDeletionAsync(); Assert.Equal(0, repository.Deletes);
        model.RequestSourceDeletionConfirmation(); model.CancelSourceDeletionConfirmation();
        Assert.Equal(0, repository.Deletes); Assert.True(model.CanDeleteSources);
        model.RequestSourceDeletionConfirmation(); await model.ConfirmSourceDeletionAsync();
        Assert.Equal(1, repository.Deletes); Assert.Equal(CrossNasCopyMoveState.Recoverable, model.State);
        await model.ConfirmSourceDeletionAsync(); await model.RefreshAsync();
        Assert.Equal(1, repository.Deletes); Assert.Equal(0, repository.Copies);
    }
    private static async Task Choose(CrossNasCopyMoveViewModel model)
    { await model.SelectTargetAndLoadAsync(Target); await model.LoadFoldersAsync("/backup", true); }
    private static CrossNasCopyMoveOutcome Outcome(MutationResultStatus status) => new(new(1, status, "crossNasCopy", true,
        status == MutationResultStatus.SubmittedButUnverified, new(status == MutationResultStatus.ConfirmedSuccess ? 1 : 0, 0,
            status == MutationResultStatus.SubmittedButUnverified ? 1 : 0)), File.Path, "/backup/item");
    private sealed class Folders : IFileCopyMoveFolderSource, IDisposable
    {
        public Guid ProfileId => TargetId;
        public int Disposals, Loads;
        public Task<IReadOnlyList<FileCopyMoveFolder>> LoadFoldersAsync(string path, CancellationToken cancellationToken)
        { Loads++; return Task.FromResult<IReadOnlyList<FileCopyMoveFolder>>([new("/backup", "backup", true), new("/share/folder/child", "child", true)]); }
        public bool IsReadOnlyPath(string path) => false;
        public void Dispose() => Disposals++;
    }
    private sealed class Repository : IFileCopyMoveRepository
    {
        public Guid Id { get; } = Guid.NewGuid();
        public int Copies, Reads, Continues, Deletes;
        public bool WaitForCancel;
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CrossNasCopyMoveOutcome Review = Outcome(MutationResultStatus.SubmittedButUnverified);
        public Guid ProfileId => SourceId;
        public FileCopyMoveAvailability Availability => new(true, true, 3);
        public CrossNasCopyMoveAvailability CrossNasAvailability => new(true, false);
        public Task<FileCopyMoveOutcome> CopyMoveAsync(FileCopyMoveRequest request, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public async Task<CrossNasCopyMoveOutcome> CrossNasCopyMoveAsync(CrossNasCopyMoveRequest request, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        {
            Copies++; Started.TrySetResult();
            if (WaitForCancel) { try { await Task.Delay(Timeout.Infinite, cancellationToken); } catch (OperationCanceledException) { } }
            return Outcome(MutationResultStatus.SubmittedButUnverified) with { OperationId = Id };
        }
        public Task<IReadOnlyList<CrossNasTransferSummary>> GetCrossNasTransfersAsync(CancellationToken cancellationToken = default) =>
            Task.FromResult<IReadOnlyList<CrossNasTransferSummary>>([new(Id, SourceId, TargetId, File.Path, "/backup", File.Name, false, 3, Review with { OperationId = Id })]);
        public Task<CrossNasCopyMoveOutcome?> ReviewCrossNasTransferAsync(Guid operationId, CancellationToken cancellationToken = default)
        { Assert.Equal(Id, operationId); Reads++; return Task.FromResult<CrossNasCopyMoveOutcome?>(Review with { OperationId = Id }); }
        public Task<CrossNasCopyMoveOutcome?> ContinueCrossNasTransferAsync(Guid operationId, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        { Assert.Equal(Id, operationId); Continues++; return Task.FromResult<CrossNasCopyMoveOutcome?>(Outcome(MutationResultStatus.ConfirmedSuccess) with { OperationId = Id }); }
        public Task<CrossNasCopyMoveOutcome?> DeleteCrossNasSourcesAsync(Guid operationId, bool confirmed, CancellationToken cancellationToken = default)
        {
            Assert.Equal(Id, operationId); Assert.True(confirmed); Deletes++;
            Review = Outcome(MutationResultStatus.ConfirmedSuccess) with { OperationId = Id, SourceDeletion = new(
                new(1, MutationResultStatus.SubmittedButUnverified, "crossNasDeleteSources", true, true, new(0, 0, 1)),
                [new(File.Path, false, CrossNasSourceDeletionState.ResultUnavailable)]) };
            return Task.FromResult<CrossNasCopyMoveOutcome?>(Review);
        }
    }
}
