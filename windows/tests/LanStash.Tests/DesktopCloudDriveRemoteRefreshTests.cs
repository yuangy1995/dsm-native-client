using System.Text.Json.Nodes;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveRemoteRefreshTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-refresh-tests-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic",
        DesktopDriveScope.Folder("/share"), DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private const string Remote = "/share/file.bin";
    private static readonly CloudDriveContentVersion Old = new(Remote, "\"old\"", 4);
    private DesktopCloudDriveSyncStore Store => new(_root);
    private static FileItem Item(long size = 8) => new(Remote, "file.bin", false, size, DateTimeOffset.UtcNow, null, false, false);

    [Fact]
    public async Task DirectoryReadIncludesAllPagesBeforeReturningTargets()
    {
        var offsets = new List<int>();
        var all = await CloudDriveRemoteRefresh.ReadDirectoryAsync("/share", (offset, _) =>
        {
            offsets.Add(offset);
            return Task.FromResult(new FilePage([Item() with { Path = "/share/file" + offset }], 3, offset));
        }, CancellationToken.None);
        Assert.Equal([0, 1, 2], offsets); Assert.Equal(3, all.Count);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public async Task DirectoryDriftTruncationAndWrongTargetsCannotMasqueradeAsComplete(int mode)
    {
        await Assert.ThrowsAsync<InvalidDataException>(() => CloudDriveRemoteRefresh.ReadDirectoryAsync("/share", (offset, _) =>
        {
            if (offset == 0) return Task.FromResult(new FilePage([Item()], 2, 0));
            return Task.FromResult(mode switch
            {
                0 => new FilePage([], 2, 1),
                1 => new FilePage([Item()], 3, 1),
                2 => new FilePage([Item()], 2, 0),
                3 => new FilePage([Item()], 2, 1),
                _ => new FilePage([Item() with { Path = "/foreign/file" }], 2, 1)
            });
        }, CancellationToken.None));
    }

    [Fact]
    public async Task DirectoryCancellationDoesNotFetchNextPage()
    {
        using var cancellation = new CancellationTokenSource(); var calls = 0;
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => CloudDriveRemoteRefresh.ReadDirectoryAsync("/share", (offset, _) =>
        {
            calls++; cancellation.Cancel(); return Task.FromResult(new FilePage([Item()], 2, 0));
        }, cancellation.Token));
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task NewVersionIsPublishedOnlyAfterLocalInvalidation()
    {
        await Store.BindVersionAsync(_mapping, Old);
        var reader = new Reader(); var updated = false;
        var candidate = await CloudDriveRemoteRefresh.RefreshAsync(_mapping, Item(), reader, Store,
            async (value, invalidate, _) =>
            {
                Assert.Equal("\"new\"", value.Version!.Version); Assert.True(invalidate);
                var json = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(_root, _mapping.Id.ToString("N"), "state.json")))!;
                Assert.Equal(Old.Version, json["Versions"]![0]!["Version"]!.GetValue<string>());
                updated = true;
            });
        Assert.True(updated); Assert.Equal(1, reader.Reads);
        Assert.Equal(candidate.Version, await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Fact]
    public async Task ConcurrentLocalReadWaitsUntilVersionTransactionFinishes()
    {
        await Store.BindVersionAsync(_mapping, Old);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var next = new CloudDriveContentVersion(Remote, "\"new\"", 8);
        var refresh = Store.RefreshVersionAsync(_mapping, Remote, Old, next,
            async _ => { entered.SetResult(); await release.Task; });
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var read = Store.ReadVersionAsync(_mapping, Remote);
        try { Assert.False(read.IsCompleted); }
        finally { release.SetResult(); }
        await refresh;
        Assert.Equal(next, await read);
    }

    [Fact]
    public async Task NativeFailurePreservesOldVersionAndCanBeRetried()
    {
        await Store.BindVersionAsync(_mapping, Old);
        await Assert.ThrowsAsync<IOException>(() => CloudDriveRemoteRefresh.RefreshAsync(_mapping, Item(), new Reader(), Store,
            (_, _, _) => Task.FromException(new IOException("合成原生失效失败"))));
        Assert.Equal(Old, await Store.ReadVersionAsync(_mapping, Remote));
        var retried = await CloudDriveRemoteRefresh.RefreshAsync(_mapping, Item(), new Reader(), Store, (_, _, _) => Task.CompletedTask);
        Assert.Equal(retried.Version, await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Fact]
    public async Task CancellationAfterNativeUpdateDoesNotPublishUncommittedVersion()
    {
        await Store.BindVersionAsync(_mapping, Old);
        using var cancellation = new CancellationTokenSource();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => CloudDriveRemoteRefresh.RefreshAsync(_mapping, Item(), new Reader(), Store,
            (_, _, _) => { cancellation.Cancel(); return Task.CompletedTask; }, cancellation.Token));
        Assert.Equal(Old, await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    public async Task PendingSaveBlocksLocalInvalidation(int phaseValue)
    {
        var phase = (CloudDriveChangePhase)phaseValue;
        await Store.BindVersionAsync(_mapping, Old);
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        var source = Path.Combine(_root, "edit.txt"); await File.WriteAllTextAsync(source, "edit");
        var change = await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, source, Old.Version);
        if (phase == CloudDriveChangePhase.Submitted) await Store.TryMarkSubmittedAsync(_mapping, change.Id);
        if (phase == CloudDriveChangePhase.Conflict) await Store.MarkConflictAsync(_mapping, change.Id);
        var updates = 0;
        await Assert.ThrowsAsync<InvalidOperationException>(() => CloudDriveRemoteRefresh.RefreshAsync(_mapping, Item(), new Reader(), Store,
            (_, _, _) => { updates++; return Task.CompletedTask; }));
        Assert.Equal(0, updates); Assert.Equal(Old, await Store.ReadVersionAsync(_mapping, Remote));
        Assert.Equal(phase, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task ConcurrentVersionChangeDuringProbeRejectsStaleRefresh()
    {
        await Store.BindVersionAsync(_mapping, Old);
        var other = new CloudDriveContentVersion(Remote, "\"other\"", 8);
        var reader = new Reader { BeforeRead = () => Store.RefreshVersionAsync(_mapping, Remote, Old, other, _ => Task.CompletedTask) };
        var updates = 0;
        await Assert.ThrowsAsync<InvalidDataException>(() => CloudDriveRemoteRefresh.RefreshAsync(_mapping, Item(), reader, Store,
            (_, _, _) => { updates++; return Task.CompletedTask; }));
        Assert.Equal(0, updates); Assert.Equal(other, await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Fact]
    public async Task UnchangedContentUpdatesMetadataWithoutInvalidatingCache()
    {
        var same = new CloudDriveContentVersion(Remote, "\"new\"", 8); await Store.BindVersionAsync(_mapping, same);
        var calls = 0;
        await CloudDriveRemoteRefresh.RefreshAsync(_mapping, Item(), new Reader(), Store,
            (_, invalidate, _) => { calls++; Assert.False(invalidate); return Task.CompletedTask; });
        Assert.Equal(1, calls); Assert.Equal(same, await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Fact]
    public async Task EmptyRemoteFileInvalidatesOldContentWithoutInventingEtag()
    {
        await Store.BindVersionAsync(_mapping, Old); var reader = new Reader(); var calls = 0;
        var result = await CloudDriveRemoteRefresh.RefreshAsync(_mapping, Item(0), reader, Store,
            (candidate, invalidate, _) => { Assert.True(invalidate); Assert.Null(candidate.Version); calls++; return Task.CompletedTask; });
        Assert.Null(result.Version); Assert.Equal(0, reader.Reads); Assert.Equal(1, calls);
        Assert.Null(await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Theory]
    [InlineData("W/\"weak\"")]
    [InlineData("\"bad value\"")]
    [InlineData("no-quotes")]
    public async Task WeakOrMalformedVersionNeverTouchesLocalData(string version)
    {
        await Store.BindVersionAsync(_mapping, Old);
        var updates = 0;
        await Assert.ThrowsAsync<InvalidDataException>(() => CloudDriveRemoteRefresh.RefreshAsync(_mapping, Item(), new Reader { Version = version }, Store,
            (_, _, _) => { updates++; return Task.CompletedTask; }));
        Assert.Equal(0, updates); Assert.Equal(Old, await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Theory]
    [InlineData(200, 8, 0)]
    [InlineData(206, 9, 0)]
    [InlineData(206, 8, 1)]
    public async Task RangeResponseMustMatchFreshFileMetadata(int status, long total, long start)
    {
        var reader = new Reader { Status = status, Total = total, ResponseStart = start };
        await Assert.ThrowsAsync<InvalidDataException>(() => CloudDriveRemoteRefresh.ReadCandidateAsync(Item(), reader));
        Assert.Equal(0, reader.Bytes[0]);
    }

    [Fact]
    public async Task UnknownTargetsAndCancellationNeverProbeRemoteData()
    {
        var reader = new Reader();
        await Assert.ThrowsAsync<InvalidDataException>(() => CloudDriveRemoteRefresh.ReadCandidateAsync(Item() with { IsDirectory = true }, reader));
        await Assert.ThrowsAsync<InvalidDataException>(() => CloudDriveRemoteRefresh.ReadCandidateAsync(Item() with { Path = "/share/../file.bin" }, reader));
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => CloudDriveRemoteRefresh.ReadCandidateAsync(Item(), reader, cancelled.Token));
        Assert.Equal(0, reader.Reads);
    }

    private sealed class Reader : IFileRangeReader
    {
        internal int Reads;
        internal string Version = "\"new\"";
        internal int Status = 206;
        internal long Total = 8, ResponseStart;
        internal byte[] Bytes = [42];
        internal Func<Task>? BeforeRead;
        public async Task<FileRangeReadResult> ReadFileRangeResultAsync(string remotePath, long offset, long length,
            string? expectedContentVersion = null, long? expectedTotalLength = null, CancellationToken cancellationToken = default)
        {
            Reads++; Assert.Equal(Remote, remotePath); Assert.Equal(0, offset); Assert.Equal(1, length);
            Assert.Null(expectedContentVersion); Assert.Null(expectedTotalLength);
            if (BeforeRead is not null) await BeforeRead();
            return new(Status, offset, length, ResponseStart, 1, Total, 1, Bytes, Version, true);
        }
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
