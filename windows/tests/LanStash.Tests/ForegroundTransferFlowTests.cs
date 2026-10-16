using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class ForegroundTransferFlowTests
{
    [Fact]
    public async Task SharedBatchControlPausesEveryActiveMemberAndReviewUpdatesOnlyOriginalBatch()
    {
        using var coordinator = new ForegroundTransferCoordinator(); coordinator.ActivateProfile("original");
        var control = new ForegroundTransferControl(); var release = new TaskCompletionSource<MutationResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var parent = Guid.NewGuid(); var child = Guid.NewGuid();
        var parentRun = coordinator.RunUploadAsync(new("original", "/sample", "batch", 3, parent), (_, _) => release.Task, control: control);
        var childRun = coordinator.RunUploadAsync(new("original", "/sample", "a", 3, child), (_, _) => release.Task, control: control);
        coordinator.UpdateDownloadPlan("original", parent, 3, [new("a", false, ForegroundTransferItemState.ResultNeedsReview, child)]);
        Assert.False(coordinator.SetPaused("other", parent, true));
        Assert.True(coordinator.SetPaused("original", child, true));
        Assert.All(coordinator.GetActivities("original"), item => Assert.Equal(ForegroundTransferState.Paused, item.State));
        Assert.True(coordinator.SetPaused("original", parent, false));
        Assert.All(coordinator.GetActivities("original"), item => Assert.Equal(ForegroundTransferState.Running, item.State));
        var unknown = new MutationResult(1, MutationResultStatus.SubmittedButUnverified, "uploadFile", true, true, new(0, 0, 1));
        release.SetResult(unknown); await Task.WhenAll(parentRun, childRun);
        var success = new MutationResult(1, MutationResultStatus.ConfirmedSuccess, "uploadFile", true, false, new(1, 0, 0));
        coordinator.ApplyUploadReview("other", child, success);
        Assert.All(coordinator.GetActivities("original"), item => Assert.Equal(ForegroundTransferState.ResultNeedsReview, item.State));
        coordinator.ApplyUploadReview("original", child, unknown);
        Assert.All(coordinator.GetActivities("original"), item => Assert.Equal(ForegroundTransferState.ResultNeedsReview, item.State));
        coordinator.ApplyUploadReview("original", child, success);
        Assert.All(coordinator.GetActivities("original"), item => Assert.Equal(ForegroundTransferState.Completed, item.State));
        Assert.Equal(ForegroundTransferItemState.Completed, coordinator.GetActivities("original").Single(item => item.Id == parent).ItemResults.Single().State);
    }

    [Fact]
    public async Task PausedDownloadRetainsBytesAndVersionWithoutRestart()
    {
        var repository = new Repository(); var control = new ForegroundTransferControl();
        var destination = new Destination(); var first = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var length = SafeFileDownloadService.ChunkSize + 3L;
        var download = new SafeFileDownloadService().DownloadAsync(repository, "/share/a", length, destination,
            new ProgressSink(value => { if (value.BytesTransferred == SafeFileDownloadService.ChunkSize) { control.Pause(); first.SetResult(); } }), control: control);
        await first.Task.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.False(download.IsCompleted); Assert.False(destination.Committed); Assert.Single(repository.Ranges);
        control.Resume(); await download.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal(2, repository.Ranges.Count); Assert.Equal(SafeFileDownloadService.ChunkSize, repository.Ranges[1].Offset);
        Assert.Equal("\"version-1\"", repository.Ranges[1].Version); Assert.Equal(length, destination.Bytes);
        Assert.True(destination.Committed); Assert.False(destination.Aborted);
    }

    [Theory]
    [InlineData(0)][InlineData(4)]
    public async Task CancelPausedDownloadNeverPublishesTarget(int length)
    {
        var repository = new Repository(); var control = new ForegroundTransferControl(); control.Pause();
        var destination = new Destination(); using var cancel = new CancellationTokenSource();
        var work = new SafeFileDownloadService().DownloadAsync(repository, "/share/a", length, destination, cancellationToken: cancel.Token, control: control);
        Assert.False(work.IsCompleted); cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => work);
        Assert.Empty(repository.Ranges); Assert.False(destination.Committed); Assert.True(destination.Aborted); Assert.True(destination.Disposed);
    }

    [Fact]
    public async Task PausingAfterLastChunkAlsoDelaysCommit()
    {
        var control = new ForegroundTransferControl(); var destination = new Destination();
        var download = new SafeFileDownloadService().DownloadAsync(new Repository(), "/share/a", 3, destination,
            new ProgressSink(value => { if (value.BytesTransferred == 3) control.Pause(); }), control: control);
        Assert.False(destination.Committed); Assert.False(download.IsCompleted);
        control.Resume(); await download; Assert.True(destination.Committed);
    }

    [Fact]
    public async Task UploadPauseKeepsSameStreamPositionAndCancellationStopsWaiting()
    {
        var control = new ForegroundTransferControl(); using var source = new MemoryStream([1, 2, 3, 4]);
        await using var stream = new ForegroundTransferReadStream(source, control); var buffer = new byte[2];
        Assert.Equal(2, await stream.ReadAsync(buffer)); control.Pause();
        using var cancel = new CancellationTokenSource(); var blocked = stream.ReadAsync(buffer, cancel.Token).AsTask();
        Assert.False(blocked.IsCompleted); Assert.Equal(2, source.Position); cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => blocked); Assert.Equal(2, source.Position);
        control.Resume(); Assert.Equal(2, await stream.ReadAsync(buffer)); Assert.Equal(new byte[] { 3, 4 }, buffer);
    }

    [Fact]
    public async Task CoordinatorControlsOnlyOwnedActivityAndAcceptsCompletionWhilePaused()
    {
        using var coordinator = new ForegroundTransferCoordinator(); coordinator.ActivateProfile("a");
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var control = new ForegroundTransferControl(); var id = Guid.NewGuid();
        var work = coordinator.RunAsync(new("a", "/share/a", "a", 20, id), (_, _) => finish.Task, control: control);
        Assert.False(coordinator.SetPaused("b", id, true)); Assert.True(coordinator.SetPaused("a", id, true));
        Assert.True(control.IsPaused); Assert.Equal(ForegroundTransferState.Paused, Assert.Single(coordinator.GetActivities("a")).State);
        finish.SetResult(); await work;
        var completed = Assert.Single(coordinator.GetActivities("a")); Assert.Equal(ForegroundTransferState.Completed, completed.State);
        Assert.False(completed.CanPause); Assert.False(coordinator.SetPaused("a", id, false));
    }

    [Fact]
    public async Task ArchiveUnknownTotalKeepsActualByteCountAndDoesNotReplay()
    {
        using var coordinator = new ForegroundTransferCoordinator(); coordinator.ActivateProfile("a");
        var destination = new Destination(); var control = new ForegroundTransferControl(); var archive = new Archive();
        var first = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var work = coordinator.RunAsync(new("a", "/share", "selection.zip", 0), async (progress, token) =>
            await new SafeFolderArchiveDownloadService().DownloadAsync(archive, ["/share/a", "/share/b"], destination, token,
                new ProgressSink(value => { progress.Report(value); if (value.BytesTransferred == 3) { control.Pause(); first.SetResult(); } }), control), control: control);
        await first.Task.WaitAsync(TimeSpan.FromSeconds(3)); Assert.False(work.IsCompleted); Assert.Equal(3, destination.Bytes);
        control.Resume(); await work; Assert.Equal(1, archive.Calls);
        var row = Assert.Single(coordinator.GetActivities("a")); Assert.Equal(7, row.BytesTransferred); Assert.Equal(0, row.TotalBytes);
        Assert.Equal(ForegroundTransferState.Completed, row.State);
    }

    [Fact]
    public async Task SpeedUsesElapsedBytesAndResetsOnPause()
    {
        using var coordinator = new ForegroundTransferCoordinator(); coordinator.ActivateProfile("a"); var id = Guid.NewGuid();
        var sampled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var work = coordinator.RunAsync(new("a", "/share/a", "a", 200, id), async (progress, token) =>
        { await Task.Delay(280, token); progress.Report(new(100, 200)); sampled.SetResult(); await finish.Task; }, control: new());
        await sampled.Task; Assert.True(Assert.Single(coordinator.GetActivities("a")).BytesPerSecond > 0);
        coordinator.SetPaused("a", id, true); Assert.Equal(0, Assert.Single(coordinator.GetActivities("a")).BytesPerSecond);
        coordinator.SetPaused("a", id, false); finish.SetResult(); await work;
        Assert.Equal(0, Assert.Single(coordinator.GetActivities("a")).BytesPerSecond);
    }

    [Fact]
    public async Task PlanIncludesEveryPageAndEmptyDirectoryBeforeAnyDownload()
    {
        var repository = new Repository(); var folder = Item("/share/folder", true); var empty = Item("/share/folder/empty", true);
        var files = Enumerable.Range(0, 511).Select(i => Item($"/share/folder/file-{i:D4}")).ToArray();
        repository.Add(folder, [empty, .. files]); repository.Add(empty, []);
        var plan = await ForegroundFolderDownloadPlan.CreateAsync(repository, [folder], new(), default);
        Assert.Equal(513, plan.Entries.Count); Assert.Equal(511 * 3, plan.TotalBytes);
        Assert.Contains(plan.Entries, e => e.RelativePath == "folder/empty"); Assert.Contains(repository.Pages, p => p.Offset == 500);
        Assert.Empty(repository.Ranges); Assert.Equal(0, repository.Writes);
    }

    [Theory]
    [InlineData("bad-page")][InlineData("repeat")][InlineData("empty-page")][InlineData("changed-total")][InlineData("outside")]
    public async Task IncompleteDirectoryNeverBecomesAUsablePlan(string defect)
    {
        var repository = new Repository(); var folder = Item("/share/folder", true); repository.Add(folder, [Item(folder.Path + "/a"), Item(folder.Path + "/b")]);
        repository.PageOverride = (path, offset) => defect switch
        {
            "bad-page" => new([Item(path + "/a")], 1, 1),
            "repeat" => new([Item(path + "/a")], 2, offset),
            "empty-page" => new([], 1, 0),
            "changed-total" => new([Item(path + (offset == 0 ? "/a" : "/b"))], offset == 0 ? 2 : 3, offset),
            _ => new([Item("/other/a")], 1, 0),
        };
        await Assert.ThrowsAsync<InvalidDataException>(() => ForegroundFolderDownloadPlan.CreateAsync(repository, [folder], new(), default));
        Assert.Empty(repository.Ranges); Assert.Equal(0, repository.Writes);
    }

    [Theory]
    [InlineData("con.txt")][InlineData("a:b")][InlineData("trailing.")][InlineData("trailing ")][InlineData("COM¹.txt")][InlineData("LPT³")]
    public async Task InvalidWindowsNameCannotProduceOutput(string name)
    {
        var repository = new Repository(); var folder = Item("/share/folder", true); repository.Add(folder, [Item(folder.Path + "/" + name)]);
        await Assert.ThrowsAsync<ForegroundDownloadException>(() => ForegroundFolderDownloadPlan.CreateAsync(repository, [folder], new(), default));
        Assert.Empty(repository.Ranges);
    }

    [Theory]
    [InlineData(false)][InlineData(true)]
    public async Task CaseCollisionAndOverlappingSelectionAreRejected(bool overlap)
    {
        var repository = new Repository(); var folder = Item("/share/folder", true); var child = Item(folder.Path + "/a");
        repository.Add(folder, [child, Item(folder.Path + "/A")]);
        if (overlap) await Assert.ThrowsAsync<InvalidDataException>(() => ForegroundFolderDownloadPlan.CreateAsync(repository, [folder, child], new(), default));
        else await Assert.ThrowsAsync<ForegroundDownloadException>(() => ForegroundFolderDownloadPlan.CreateAsync(repository, [folder], new(), default));
    }

    [Theory]
    [InlineData(".")][InlineData("..")]
    public async Task DirectoryTraversalEntryIsRejected(string name)
    {
        var repository = new Repository(); var folder = Item("/share/folder", true); repository.Add(folder, [Item(folder.Path + "/" + name)]);
        await Assert.ThrowsAsync<InvalidDataException>(() => ForegroundFolderDownloadPlan.CreateAsync(repository, [folder], new(), default));
        Assert.Empty(repository.Ranges);
    }

    [Theory]
    [InlineData("size")][InlineData("kind")][InlineData("time")][InlineData("link")][InlineData("missing")]
    public async Task ChangedSourceIsRejectedIncludingEmptyFiles(string change)
    {
        var repository = new Repository(); var item = Item("/share/empty") with { Size = 0 }; repository.Add(item, []);
        repository.MetadataOverride = original => change switch
        {
            "size" => new(original with { Size = 1 }, null, null), "kind" => new(original with { IsDirectory = true }, null, null),
            "time" => new(original with { ModifiedAt = DateTimeOffset.UtcNow }, null, null), "link" => new(original, "symlink", null), _ => null,
        };
        await Assert.ThrowsAsync<InvalidDataException>(() => ForegroundFolderDownloadPlan.CreateAsync(repository, [item], new(), default));
        Assert.Empty(repository.Ranges);
    }

    [Fact]
    public async Task PausedPlanCanBeCancelledBeforeListingAnything()
    {
        var repository = new Repository(); var control = new ForegroundTransferControl(); control.Pause(); using var cancel = new CancellationTokenSource();
        var work = ForegroundFolderDownloadPlan.CreateAsync(repository, [Item("/share/a", true)], control, cancel.Token);
        cancel.Cancel(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => work); Assert.Empty(repository.Pages);
    }

    [Theory]
    [InlineData("../escape")][InlineData("/absolute")][InlineData("folder/../escape")][InlineData("folder/a:b")]
    public void LocalResolutionRejectsEscape(string relative)
    {
        Assert.Throws<InvalidDataException>(() => ForegroundDownloadDirectoryLease.Resolve(Path.GetTempPath(), relative));
    }

    [Fact]
    public void DirectoryIdentityAllowsFilePublishAndRejectsParentReplacement()
    {
        var root = Path.Combine(Path.GetTempPath(), "LanStash-download-test-" + Guid.NewGuid().ToString("N"));
        var child = Path.Combine(root, "child"); Directory.CreateDirectory(child);
        try
        {
            using (var lease = ForegroundDownloadDirectoryLease.Acquire(child))
            {
                File.WriteAllText(Path.Combine(child, "sample.txt"), "synthetic");
                File.Move(Path.Combine(child, "sample.txt"), Path.Combine(child, "renamed.txt"));
                lease.Validate();
                Assert.Equal("synthetic", File.ReadAllText(Path.Combine(child, "renamed.txt")));
                Directory.Move(child, Path.Combine(root, "moved"));
                Directory.CreateDirectory(child);
                Assert.Throws<IOException>(() => lease.Validate());
                Assert.Empty(Directory.EnumerateFileSystemEntries(child));
            }
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static FileItem Item(string path, bool directory = false) => new(path, path[(path.LastIndexOf('/') + 1)..], directory, directory ? 0 : 3, null, null, false, false);
    private sealed class ProgressSink(Action<ForegroundTransferProgress> report) : IProgress<ForegroundTransferProgress>
    { public void Report(ForegroundTransferProgress value) => report(value); }
    private sealed class Destination : ITransactionalDownloadDestination
    {
        public long Bytes; public bool Committed, Aborted, Disposed;
        public ValueTask WriteAsync(ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken = default) { Bytes += bytes.Length; return ValueTask.CompletedTask; }
        public ValueTask CommitAsync(CancellationToken cancellationToken = default) { Committed = true; return ValueTask.CompletedTask; }
        public ValueTask AbortAsync(CancellationToken cancellationToken = default) { Aborted = true; return ValueTask.CompletedTask; }
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
    private sealed class Archive : IFileArchiveReader
    {
        public int Calls;
        public async Task StreamArchiveAsync(IReadOnlyList<string> paths, Func<ReadOnlyMemory<byte>, CancellationToken, ValueTask> write, CancellationToken token = default)
        { Calls++; await write(new byte[3], token); await write(new byte[4], token); }
    }
    private sealed class Repository : IDsmRepository
    {
        private readonly Dictionary<string, FileItem> _items = [];
        private readonly Dictionary<string, FileItem[]> _children = [];
        public List<(long Offset, string? Version)> Ranges = [];
        public List<(string Path, int Offset)> Pages = [];
        public int Writes;
        public Func<string, int, FilePage>? PageOverride;
        public Func<FileItem, FileEntryMetadata?>? MetadataOverride;
        public IReadOnlyList<AppModule> AvailableModules => [];
        public void Add(FileItem item, FileItem[] children) { _items[item.Path] = item; _children[item.Path] = children; foreach (var child in children) _items[child.Path] = child; }
        public Task<FileEntryMetadata?> ReadFileMetadataAsync(string path, CancellationToken token = default)
        {
            var item = _items.GetValueOrDefault(path) ?? Item(path);
            return Task.FromResult(MetadataOverride is not null ? MetadataOverride(item) : new FileEntryMetadata(item, null, null));
        }
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, FileListOptions options, CancellationToken cancellationToken = default)
        { Pages.Add((path, offset)); var children = _children.GetValueOrDefault(path) ?? []; return Task.FromResult(PageOverride?.Invoke(path, offset) ?? new(children.Skip(offset).Take(limit).ToArray(), children.Length, offset)); }
        public Task<FileRangeReadResult> ReadFileRangeResultAsync(string remotePath, long offset, long length, string? expectedContentVersion = null, long? expectedTotalLength = null, CancellationToken cancellationToken = default)
        { Ranges.Add((offset, expectedContentVersion)); return Task.FromResult(new FileRangeReadResult(206, offset, length, offset, length, expectedTotalLength ?? length, length, new byte[checked((int)length)], "\"version-1\"", true)); }
        public Task<FilePage> ListFilesAsync(string path, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<IReadOnlyList<FileItem>> SearchFilesAsync(string path, string query, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task CreateFolderAsync(string parentPath, string name, CancellationToken cancellationToken = default) { Writes++; throw new NotSupportedException(); }
        public Task RenameAsync(string path, string newName, CancellationToken cancellationToken = default) { Writes++; throw new NotSupportedException(); }
        public Task DeleteFilesAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken = default) { Writes++; throw new NotSupportedException(); }
        public Task<NasSettingsSnapshot> LoadNasSettingsAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
