using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.CopyMove;

public sealed partial class CrossNasTransferFlowTests
{
    [Fact]
    public async Task RestartUsesSavedReceiptAndDigestWithFreshConnectionsWithoutUploadingAgain()
    {
        var store = new MemoryJournal(); using var pair = new Pair(23, store); pair.TargetApi.Corrupt = true;
        var original = await pair.Copy(); var restarted = Restart(pair, store);
        var history = Assert.Single(await restarted.Source.GetCrossNasTransfersAsync());
        Assert.True(history.Outcome.RequiresReadOnlyRecovery); Assert.False(history.Outcome.CanContinue);
        var result = await restarted.Source.ReviewCrossNasTransferAsync(original.OperationId);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result!.Result.Status);
        Assert.False(result.RequiresReadOnlyRecovery); Assert.Equal(0, restarted.TargetApi.Uploads);
        Assert.Equal(1, pair.TargetApi.Uploads); Assert.NotEmpty(restarted.TargetApi.Ranges);
        Assert.DoesNotContain("synthetic-session", System.Text.Encoding.UTF8.GetString(store.Records.Single().Value));
        Assert.DoesNotContain("source.invalid", System.Text.Encoding.UTF8.GetString(store.Records.Single().Value));
    }

    [Fact]
    public async Task RestartWithLostReceiptKeepsUnknownAndPreventsNewOperationOnSameDestination()
    {
        var store = new MemoryJournal(); using var pair = new Pair(23, store);
        pair.TargetApi.UploadStatus = FileUploadTransportStatus.SubmittedButUnverified;
        var first = await pair.Copy(); var restarted = Restart(pair, store);
        var history = Assert.Single(await restarted.Source.GetCrossNasTransfersAsync());
        var reviewed = await restarted.Source.ReviewCrossNasTransferAsync(history.Id);
        var duplicate = await restarted.Source.CrossNasCopyMoveAsync(pair.Request with { OperationId = Guid.NewGuid() });
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, reviewed!.Result.Status);
        Assert.Equal(first.OperationId, duplicate.OperationId); Assert.Equal(0, restarted.TargetApi.Uploads);
        Assert.Empty(restarted.TargetApi.Ranges);
    }

    [Fact]
    public async Task RestartRequiresReadOnlyReviewThenExplicitlyContinuesOnlyUnstartedItems()
    {
        var store = new MemoryJournal(); using var pair = new Pair(0, store); pair.Folder();
        using var cancellation = new CancellationTokenSource(); pair.TargetApi.OnCreate = cancellation.Cancel;
        var first = await pair.Copy(cancellation.Token);
        Assert.Equal(1, pair.TargetApi.Creates); Assert.Equal(0, pair.TargetApi.Uploads);
        var restarted = Restart(pair, store); var saved = Assert.Single(await restarted.Source.GetCrossNasTransfersAsync());
        Assert.False(saved.Outcome.CanContinue);
        await restarted.Source.ContinueCrossNasTransferAsync(first.OperationId);
        Assert.Equal(0, restarted.TargetApi.Creates);
        var reviewed = await restarted.Source.ReviewCrossNasTransferAsync(first.OperationId);
        Assert.True(reviewed!.CanContinue);
        var completed = await restarted.Source.ContinueCrossNasTransferAsync(first.OperationId);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, completed!.Result.Status);
        Assert.Equal(1, restarted.TargetApi.Creates); Assert.Equal(2, restarted.TargetApi.Uploads);
        Assert.Equal(4, completed.Result.Counts.Succeeded);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task RestartNeverReplaysDeleteAndRequiresOriginalReceiptEvenWhenSourceIsGone(bool accepted)
    {
        var store = new MemoryJournal(); using var pair = new Pair(23, store); pair.Source.CrossNasSourceDeletionEnabled = true;
        var copied = await pair.Copy(); pair.SourceApi.ThrowDeleteRead = true;
        pair.SourceApi.DeleteStatus = accepted ? FileMutationTransportStatus.ResponseReceived : FileMutationTransportStatus.SubmittedButUnverified;
        await pair.Source.DeleteCrossNasSourcesAsync(copied.OperationId, true);
        Assert.Empty(pair.SourceApi.Files); var restarted = Restart(pair, store); restarted.Source.CrossNasSourceDeletionEnabled = true;
        var history = Assert.Single(await restarted.Source.GetCrossNasTransfersAsync());
        Assert.NotNull(history.Outcome.SourceDeletion); Assert.False(history.Outcome.CanDeleteSources);
        var reviewed = await restarted.Source.ReviewCrossNasTransferAsync(history.Id);
        Assert.Equal(accepted ? MutationResultStatus.ConfirmedSuccess : MutationResultStatus.SubmittedButUnverified,
            reviewed!.SourceDeletion!.Result.Status);
        await restarted.Source.DeleteCrossNasSourcesAsync(history.Id, true);
        Assert.Empty(restarted.SourceApi.Deletes); Assert.Equal(accepted ? 1 : 0, restarted.SourceApi.DeleteReads);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
    }

    [Fact]
    public async Task StorageFailureBeforeSubmissionMakesZeroWritesAndBlocksOtherWriters()
    {
        var store = new MemoryJournal { Reject = _ => true }; using var pair = new Pair(23, store);
        var result = await pair.Copy(); Assert.False(result.Result.Submitted); Assert.Equal(0, pair.TargetApi.Uploads);
        Assert.False(pair.Source.CrossNasAvailability.CanCrossCopy);
        var target = DsmRepository.CrossNasRepositoryResolver(pair.TargetApi.Profile.Id)!;
        using var content = new MemoryStream([1]);
        var upload = await target.UploadFileAsync(new(content, 1, "/backup", "other.bin"));
        Assert.Equal(MutationErrorCategory.Conflict, upload.ErrorCategory); Assert.Equal(0, pair.TargetApi.Permissions);
        Assert.Empty(store.Records);
    }

    [Fact]
    public async Task FailureSavingAcceptedReceiptCannotBecomeSuccessAfterRestart()
    {
        var store = new MemoryJournal { Reject = record => record["Items"]![0]!["UploadAccepted"]!.GetValue<bool>() };
        using var pair = new Pair(23, store); var result = await pair.Copy();
        Assert.Equal(1, pair.TargetApi.Uploads); Assert.NotEqual(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.True(result.RecoveryStorageUnavailable);
        var restarted = Restart(pair, store); var history = Assert.Single(await restarted.Source.GetCrossNasTransfersAsync());
        var reviewed = await restarted.Source.ReviewCrossNasTransferAsync(history.Id);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, reviewed!.Result.Status);
        Assert.Empty(restarted.TargetApi.Ranges); Assert.Equal(0, restarted.TargetApi.Uploads);
    }

    [Theory]
    [InlineData("json")]
    [InlineData("version")]
    [InlineData("path")]
    public async Task InvalidRecordsRemainIntactAndCannotBeOverwritten(string corruption)
    {
        var store = new MemoryJournal(); using var pair = new Pair(23, store); await pair.Copy();
        var cloned = store.Clone(); var id = pair.Request.OperationId;
        if (corruption == "json") cloned.Records[id] = [0, 1, 2];
        else
        {
            var record = JsonNode.Parse(cloned.Records[id])!;
            if (corruption == "version") record["Version"] = 2;
            else record["Items"]![0]!["Source"]!["Item"]!["Path"] = "/share/../other";
            cloned.Records[id] = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(record);
        }
        var before = cloned.Records[id].ToArray(); var repository = pair.SourceApi.Repository(cloned);
        await repository.InitializeCrossNasRecoveryAsync();
        await Assert.ThrowsAsync<IOException>(() => repository.GetCrossNasTransfersAsync());
        var rejected = await repository.CrossNasCopyMoveAsync(pair.Request with { OperationId = Guid.NewGuid() });
        Assert.False(rejected.Result.Submitted); Assert.Equal(before, cloned.Records[id]); Assert.Equal(0, cloned.Saves);
    }

    [Fact]
    public async Task RebuiltTargetCannotBypassPendingCopyOrDeleteGuards()
    {
        var store = new MemoryJournal(); using var pair = new Pair(23, store); pair.TargetApi.Corrupt = true;
        var first = await pair.Copy(); var restarted = Restart(pair, store);
        await restarted.Source.InitializeCrossNasRecoveryAsync();
        using var content = new MemoryStream([8, 9]);
        var blocked = await restarted.Target.UploadFileAsync(new(content, 2, "/backup", "item.bin", overwrite: true));
        Assert.Equal(MutationErrorCategory.Conflict, blocked.ErrorCategory); Assert.Equal(0, restarted.TargetApi.Permissions);
        await restarted.Source.ReviewCrossNasTransferAsync(first.OperationId);
        restarted.Source.CrossNasSourceDeletionEnabled = true; restarted.SourceApi.ThrowDeleteRead = true;
        await restarted.Source.DeleteCrossNasSourcesAsync(first.OperationId, true);
        var newTargetApi = new Api(pair.TargetApi.Profile) { Files = pair.TargetApi.Files };
        var newTarget = newTargetApi.Repository(restarted.Store);
        using var replacement = new MemoryStream([7]);
        var protectedCopy = await newTarget.UploadFileAsync(new(replacement, 1, "/backup", "item.bin", overwrite: true));
        Assert.Equal(MutationErrorCategory.Conflict, protectedCopy.ErrorCategory); Assert.Equal(0, newTargetApi.Permissions);
        Assert.Equal(0, newTargetApi.Uploads);
    }

    [Fact]
    public async Task SavedTaskCannotBeClaimedByAnotherAccountOnSameProfile()
    {
        var store = new MemoryJournal(); using var pair = new Pair(23, store); pair.TargetApi.Corrupt = true; await pair.Copy();
        var api = new Api(pair.SourceApi.Profile with { Username = "different-synthetic-account" }) { Files = pair.SourceApi.Files };
        var other = api.Repository(store.Clone());
        Assert.Empty(await other.GetCrossNasTransfersAsync());
        Assert.Null(await other.ReviewCrossNasTransferAsync(pair.Request.OperationId)); Assert.Empty(api.Ranges);
    }

    [Fact]
    public async Task OperationIdentifierCannotOverwriteAnotherAccountsPersistedTask()
    {
        var store = new MemoryJournal(); using var pair = new Pair(23, store); await pair.Copy();
        var before = store.Records[pair.Request.OperationId].ToArray();
        var api = new Api(pair.SourceApi.Profile with { Username = "different-synthetic-account" }) { Files = pair.SourceApi.Files };
        var other = api.Repository(store);
        var rejected = await other.CrossNasCopyMoveAsync(pair.Request);
        Assert.Equal(MutationErrorCategory.Conflict, rejected.Result.ErrorCategory);
        Assert.Equal("file.cross-nas.operation-owner-mismatch", rejected.Result.DiagnosticTag);
        Assert.Equal(before, store.Records[pair.Request.OperationId]); Assert.Equal(1, pair.TargetApi.Uploads);
    }

    [Fact]
    public async Task ChangedEndpointCannotBypassPendingDestinationProtectionOrRevealOriginalTask()
    {
        var store = new MemoryJournal(); using var pair = new Pair(23, store); pair.TargetApi.Corrupt = true; await pair.Copy();
        var changed = new Api(pair.TargetApi.Profile with { Host = "new-route.invalid", Username = "different-synthetic-account" }) { Files = pair.TargetApi.Files };
        var repository = changed.Repository(store.Clone()); await repository.InitializeCrossNasRecoveryAsync();
        Assert.Empty(await repository.GetCrossNasTransfersAsync());
        using var content = new MemoryStream([1]);
        var blocked = await repository.UploadFileAsync(new(content, 1, "/backup", "item.bin", overwrite: true));
        Assert.Equal(MutationErrorCategory.Conflict, blocked.ErrorCategory); Assert.Equal(0, changed.Permissions); Assert.Equal(0, changed.Uploads);
    }

    private static (DsmRepository Source, DsmRepository Target, Api SourceApi, Api TargetApi, MemoryJournal Store) Restart(Pair pair, MemoryJournal store)
    {
        var sourceApi = new Api(pair.SourceApi.Profile) { Files = pair.SourceApi.Files };
        var targetApi = new Api(pair.TargetApi.Profile) { Files = pair.TargetApi.Files };
        var nextStore = store.Clone(); var source = sourceApi.Repository(nextStore); var target = targetApi.Repository(nextStore);
        DsmRepository.RegisterRepository(targetApi.Profile.Id, target);
        return (source, target, sourceApi, targetApi, nextStore);
    }
    private sealed class MemoryJournal : IProtectedTaskStore
    {
        public Dictionary<Guid, byte[]> Records { get; } = [];
        public int Saves;
        public Func<JsonNode, bool>? Reject;
        public Task<IReadOnlyDictionary<Guid, byte[]>> LoadAsync() =>
            Task.FromResult<IReadOnlyDictionary<Guid, byte[]>>(Records.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray()));
        public Task SaveAsync(Guid id, byte[] record)
        {
            if (Reject?.Invoke(JsonNode.Parse(record)!) == true) throw new IOException("合成持久化失败。");
            Saves++; Records[id] = record.ToArray(); return Task.CompletedTask;
        }
        public MemoryJournal Clone()
        {
            var result = new MemoryJournal(); foreach (var pair in Records) result.Records.Add(pair.Key, pair.Value.ToArray()); return result;
        }
    }
}
