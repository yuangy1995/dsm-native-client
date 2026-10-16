using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Office;

public sealed class OfficeMutationOwnershipTests
{
    [Theory]
    [InlineData("move")] [InlineData("recycle")] [InlineData("extract")] [InlineData("compress")]
    public async Task OtherExecutorsCannotTakeAnActiveOfficeTargetOrItsParent(string operation)
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var session = await server.BeginAsync(repo);
        var reads = server.Reads;
        var result = await MutateAsync(repo, session.Baseline.Metadata.Item, operation);
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.False(result.Submitted);
        Assert.Equal(reads, server.Reads); Assert.Equal(0, server.Uploads);
    }

    [Theory]
    [InlineData("move")] [InlineData("recycle")] [InlineData("extract")]
    public async Task PreparationReservationClosesTheGapBeforeInitialCheckpoint(string operation)
    {
        using var server = new OfficeTestServer(); var repo = server.Repository();
        var baseline = await repo.ReadOfficeRemoteAsync(server.RemotePath);
        server.HoldMd5 = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var creating = repo.CreateOfficeSessionAsync(Guid.NewGuid(), Path.Combine(Path.GetTempPath(), "synthetic-preparation.docx"),
            baseline, OfficeTestServer.Fingerprint(server.Bytes));
        await server.Md5Held.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Empty(await repo.GetOfficeSessionsAsync());
        var result = await MutateAsync(server.Repository(), baseline.Metadata.Item, operation);
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory); Assert.False(result.Submitted);
        server.HoldMd5.SetResult(); Assert.Equal(OfficeEditingState.Ready, (await creating).State);
        Assert.Equal(0, server.Uploads);
    }

    [Fact]
    public async Task AlreadyRunningMovePreventsOfficeSessionFromStarting()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var baseline = await repo.ReadOfficeRemoteAsync(server.RemotePath);
        server.HoldList = new(TaskCreationOptions.RunContinuationsAsynchronously); using var cancellation = new CancellationTokenSource();
        var moving = MutateAsync(repo, baseline.Metadata.Item, "move", cancellation.Token);
        await server.ListHeld.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await Assert.ThrowsAsync<InvalidOperationException>(() => repo.CreateOfficeSessionAsync(Guid.NewGuid(),
            Path.Combine(Path.GetTempPath(), "synthetic-busy.docx"), baseline, OfficeTestServer.Fingerprint(server.Bytes)));
        Assert.Empty(await repo.GetOfficeSessionsAsync());
        cancellation.Cancel(); server.HoldList.TrySetResult(); await moving;
        Assert.Equal(0, server.Uploads);
    }

    [Fact]
    public async Task CancelledPreparationReleasesOnlyItsOwnProvisionalReservation()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var baseline = await repo.ReadOfficeRemoteAsync(server.RemotePath);
        server.HoldMd5 = new(TaskCreationOptions.RunContinuationsAsynchronously); using var cancellation = new CancellationTokenSource();
        var creating = repo.CreateOfficeSessionAsync(Guid.NewGuid(), Path.Combine(Path.GetTempPath(), "synthetic-cancel.docx"),
            baseline, OfficeTestServer.Fingerprint(server.Bytes), cancellation.Token);
        await server.Md5Held.Task.WaitAsync(TimeSpan.FromSeconds(5)); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => creating);
        Assert.False(repo.HasOfficeSessionWithin(server.RemotePath)); Assert.Empty(await repo.GetOfficeSessionsAsync());
        server.HoldMd5.TrySetResult(); Assert.Equal(OfficeEditingState.Ready, (await server.BeginAsync(repo)).State);
    }

    private static async Task<MutationResult> MutateAsync(DsmRepository repo, FileItem item, string operation, CancellationToken token = default)
    {
        if (operation == "move") return (await repo.CopyMoveAsync(new(new(repo.ProfileId, item.Path, item.Name,
            false, item.Size, item.ModifiedAt, true, true, false, false, false), "/other", FileCopyMoveOperation.Move, true, false, false, false), token)).Result;
        if (operation == "recycle") return (await repo.MoveToRecycleAsync(new(new(repo.ProfileId, item.Path, item.Name,
            false, item.Size, item.ModifiedAt, true, true, false, false, false), new("/sample", "/sample/#recycle")), token)).Result;
        if (operation == "extract") return (await repo.ExtractAsync(new(repo.ProfileId,
            new(new("/archive/data.zip", "data.zip", false, 128, item.ModifiedAt, null, true, true)), "/sample"), token)).Result;
        return (await repo.CompressAsync(new(repo.ProfileId, [new(item)], "copy.zip"), token)).Result;
    }
}
