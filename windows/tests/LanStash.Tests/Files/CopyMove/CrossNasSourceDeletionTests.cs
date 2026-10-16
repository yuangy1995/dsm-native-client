using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.CopyMove;

public sealed partial class CrossNasTransferFlowTests
{
    [Fact]
    public async Task SourceDeletionIsClosedByDefaultAndRequiresIndependentConfirmation()
    {
        using var pair = new Pair(3); var copy = await pair.Copy();
        Assert.False(pair.Source.CrossNasAvailability.CanCrossMove); Assert.False(copy.CanDeleteSources);
        Assert.Null((await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true))!.SourceDeletion);
        Assert.Empty(pair.SourceApi.Deletes);
        pair.Source.CrossNasSourceDeletionEnabled = true;
        var read = await pair.Source.ReviewCrossNasTransferAsync(copy.OperationId);
        Assert.True(read!.CanDeleteSources);
        await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, false);
        Assert.Empty(pair.SourceApi.Deletes);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ConfirmedDeletionRemovesOnlyVerifiedFilesThenEmptyDirectories(bool folder)
    {
        using var pair = new Pair(3); if (folder) pair.Folder();
        pair.Source.CrossNasSourceDeletionEnabled = true;
        pair.Request = pair.Request with { Operation = CrossNasCopyMoveOperation.Move };
        var copy = await pair.Copy(); Assert.True(copy.CanDeleteSources); Assert.Empty(pair.SourceApi.Deletes);
        var result = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result!.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.SourceDeletion!.Result.Status);
        Assert.All(result.Items, item => Assert.Equal(CrossNasTransferItemState.Copied, item.State));
        Assert.All(result.SourceDeletion.Items, item => Assert.Equal(CrossNasSourceDeletionState.Deleted, item.State));
        Assert.False(result.CanDeleteSources); Assert.False(result.IsRunning);
        Assert.Equal(folder ? 4 : 1, pair.SourceApi.Deletes.Count);
        if (folder) Assert.Equal(new[] { "/share/folder/a.bin", "/share/folder/b.bin", "/share/folder/empty", "/share/folder" }, pair.SourceApi.Deletes);
        await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        await pair.Source.ReviewCrossNasTransferAsync(copy.OperationId);
        Assert.Equal(folder ? 4 : 1, pair.SourceApi.Deletes.Count);
        Assert.Equal(folder ? 2 : 1, pair.TargetApi.Uploads);
    }

    [Theory]
    [InlineData("source-content")]
    [InlineData("target-content")]
    [InlineData("permission")]
    [InlineData("source-link")]
    [InlineData("target-account")]
    public async Task ChangedContentPermissionOrIdentityPreventsAllDeletion(string changed)
    {
        using var pair = new Pair(3); pair.Source.CrossNasSourceDeletionEnabled = true;
        var copy = await pair.Copy();
        if (changed == "source-content") pair.SourceApi.Files["/share/item.bin"].Bytes[0] ^= 1;
        if (changed == "target-content") pair.TargetApi.Files["/backup/item.bin"].Bytes[0] ^= 1;
        if (changed == "permission") pair.SourceApi.Files["/share/item.bin"].CanDelete = false;
        if (changed == "source-link") pair.SourceApi.Files["/share/item.bin"].Type = "symlink";
        if (changed == "target-account") DsmRepository.RegisterRepository(pair.TargetApi.Profile.Id,
            new Api(pair.TargetApi.Profile with { Username = "different" }).Repository());
        var result = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.Empty(pair.SourceApi.Deletes); Assert.False(result!.CanDeleteSources);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.SourceDeletion!.Result.Status);
        Assert.NotNull(result.SourceDeletion.Result.ErrorCategory);
    }

    [Fact]
    public async Task AddedSourceChildBeforeDeleteStopsWholePlan()
    {
        using var pair = new Pair(3); pair.Folder(); pair.Source.CrossNasSourceDeletionEnabled = true;
        var copy = await pair.Copy(); pair.SourceApi.Add("/share/folder/new.bin", [7]);
        var result = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.Empty(pair.SourceApi.Deletes); Assert.Equal(MutationErrorCategory.Conflict, result!.SourceDeletion!.Result.ErrorCategory);
    }

    [Fact]
    public async Task NewlyCreatedChildPreventsNonRecursiveParentDeletion()
    {
        using var pair = new Pair(3); pair.Folder(); pair.Source.CrossNasSourceDeletionEnabled = true;
        var copy = await pair.Copy();
        pair.SourceApi.OnDelete = () =>
        {
            if (pair.SourceApi.Deletes.Count == 1) pair.SourceApi.Add("/share/folder/new.bin", [7]);
        };
        var result = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.DoesNotContain("/share/folder", pair.SourceApi.Deletes);
        Assert.True(pair.SourceApi.Files.ContainsKey("/share/folder/new.bin"));
        Assert.Equal(MutationErrorCategory.Conflict, result!.SourceDeletion!.Result.ErrorCategory);
    }

    [Fact]
    public async Task LostDeletionReceiptCannotClaimAbsenceOrReplay()
    {
        using var pair = new Pair(3); pair.Source.CrossNasSourceDeletionEnabled = true;
        var copy = await pair.Copy(); pair.SourceApi.DeleteStatus = FileMutationTransportStatus.SubmittedButUnverified;
        var result = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.False(pair.SourceApi.Files.ContainsKey("/share/item.bin"));
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result!.SourceDeletion!.Result.Status);
        var review = await pair.Source.ReviewCrossNasTransferAsync(copy.OperationId);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, review!.SourceDeletion!.Result.Status);
        await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.Single(pair.SourceApi.Deletes); Assert.Equal(0, pair.SourceApi.DeleteReads);
    }

    [Fact]
    public async Task AcceptedDeleteReadFailureRecoversByOriginalTaskWithoutResend()
    {
        using var pair = new Pair(3); pair.Source.CrossNasSourceDeletionEnabled = true;
        var copy = await pair.Copy(); pair.SourceApi.ThrowDeleteRead = true;
        var first = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first!.SourceDeletion!.Result.Status);
        pair.SourceApi.ThrowDeleteRead = false;
        var reopened = pair.SourceApi.Repository();
        var result = await reopened.ReviewCrossNasTransferAsync(copy.OperationId);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result!.SourceDeletion!.Result.Status);
        Assert.Single(pair.SourceApi.Deletes); Assert.Equal(2, pair.SourceApi.DeleteReads);
    }

    [Theory]
    [InlineData("running")]
    [InlineData("present")]
    [InlineData("bad-page")]
    [InlineData("failed")]
    public async Task CompletionNeedsOwnSuccessfulTaskAndCompleteAbsenceRead(string kind)
    {
        using var pair = new Pair(3); pair.Source.CrossNasSourceDeletionEnabled = true;
        var copy = await pair.Copy();
        pair.SourceApi.DeleteTaskStatus = kind == "running" ? FileRecycleTaskTransportStatus.Running :
            kind == "failed" ? FileRecycleTaskTransportStatus.ConfirmedFailure : FileRecycleTaskTransportStatus.Finished;
        pair.SourceApi.RemoveOnDelete = kind != "present";
        pair.SourceApi.OnDelete = () => pair.SourceApi.InvalidPage = kind == "bad-page";
        var result = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.NotEqual(MutationResultStatus.ConfirmedSuccess, result!.SourceDeletion!.Result.Status);
        await pair.Source.ReviewCrossNasTransferAsync(copy.OperationId);
        Assert.Single(pair.SourceApi.Deletes);
    }

    [Fact]
    public async Task CancellationKeepsCompletedFactsAndExplicitContinueDeletesOnlyRemaining()
    {
        using var pair = new Pair(3); pair.Folder(); pair.Source.CrossNasSourceDeletionEnabled = true;
        var copy = await pair.Copy(); using var cancellation = new CancellationTokenSource();
        pair.SourceApi.OnDelete = () => cancellation.Cancel();
        var stopped = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true, cancellation.Token);
        Assert.Single(pair.SourceApi.Deletes); Assert.False(stopped!.CanDeleteSources);
        pair.SourceApi.OnDelete = null;
        var reviewed = await pair.Source.ReviewCrossNasTransferAsync(copy.OperationId);
        Assert.True(reviewed!.CanDeleteSources); Assert.Equal(1, reviewed.SourceDeletion!.Result.Counts.Succeeded);
        Assert.Single(pair.SourceApi.Deletes);
        var finished = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, finished!.SourceDeletion!.Result.Status);
        Assert.Equal(4, pair.SourceApi.Deletes.Distinct().Count()); Assert.Equal(4, pair.SourceApi.Deletes.Count);
        Assert.Equal(2, pair.TargetApi.Uploads);
    }

    [Fact]
    public async Task ConcurrentDeleteClicksReuseOriginalOperation()
    {
        using var pair = new Pair(3); pair.Source.CrossNasSourceDeletionEnabled = true;
        var copy = await pair.Copy(); pair.SourceApi.HoldDelete = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var pending = pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        await pair.SourceApi.DeleteStarted.Task.WaitAsync(TimeSpan.FromSeconds(3));
        var duplicate = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.True(duplicate!.IsRunning); Assert.Single(pair.SourceApi.Deletes);
        pair.SourceApi.HoldDelete.SetResult();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await pending.WaitAsync(TimeSpan.FromSeconds(3)))!.SourceDeletion!.Result.Status);
    }

    [Fact]
    public async Task SourceAbsenceReadIncludesEveryParentPage()
    {
        using var pair = new Pair(3); pair.Source.CrossNasSourceDeletionEnabled = true;
        var copy = await pair.Copy();
        for (var index = 0; index < 501; index++) pair.SourceApi.Add("/share/neighbor-" + index, []);
        var result = await pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result!.SourceDeletion!.Result.Status);
        Assert.Contains(500, pair.SourceApi.PageOffsets);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ActiveAndUnknownSourceDeletionBlockAncestorRenameMoveRecycleAndTargetUpload(bool unknown)
    {
        using var pair = new Pair(3); pair.Source.CrossNasSourceDeletionEnabled = true;
        pair.SourceApi.Files.Clear(); pair.SourceApi.Add("/share/folder/item.bin", [1, 2, 3]);
        pair.Request = pair.Request with { SourcePath = "/share/folder/item.bin" };
        var copy = await pair.Copy();
        if (unknown) pair.SourceApi.DeleteStatus = FileMutationTransportStatus.SubmittedButUnverified;
        else pair.SourceApi.HoldDelete = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var deleting = pair.Source.DeleteCrossNasSourcesAsync(copy.OperationId, true);
        await pair.SourceApi.DeleteStarted.Task.WaitAsync(TimeSpan.FromSeconds(3));
        if (unknown) await deleting;
        var rename = await pair.Source.RenameAsync(new(new(pair.SourceApi.Profile.Id, "/share/folder", "folder", true, 0, null, true), "changed"));
        Assert.Equal("file.rename.target-busy", rename.Result.DiagnosticTag);
        var move = await pair.Source.CopyMoveAsync(new(new(pair.SourceApi.Profile.Id, "/share/folder", "folder", true, 0, null,
            true, true, false, false, false), "/other", FileCopyMoveOperation.Move, true, false, false, false));
        Assert.Equal("file.copy-move.target-busy", move.Result.DiagnosticTag);
        var recycle = await pair.Source.MoveToRecycleAsync(new(new(pair.SourceApi.Profile.Id, "/share/folder", "folder", true, 0, null,
            true, true, false, false, false), new("/share", "/share/#recycle")));
        Assert.Equal("file.recycle.move.target-busy", recycle.Result.DiagnosticTag);
        using (var stream = new MemoryStream([4, 5, 6]))
        {
            var targetUpload = await pair.TargetApi.Repository().UploadFileAsync(new(stream, 3, "/backup", "item.bin", true));
            Assert.False(targetUpload.Submitted); Assert.Equal(MutationErrorCategory.Conflict, targetUpload.ErrorCategory);
        }
        if (!unknown)
        {
            pair.SourceApi.HoldDelete!.SetResult(); await deleting.WaitAsync(TimeSpan.FromSeconds(3));
        }
        Assert.Single(pair.SourceApi.Deletes); Assert.Equal(1, pair.TargetApi.Uploads);
    }
}
