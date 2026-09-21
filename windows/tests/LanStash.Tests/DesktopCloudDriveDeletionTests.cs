using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveDeletionTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-deletion-tests-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic", DesktopDriveScope.Folder("/share"),
        DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private DesktopCloudDriveSyncStore Store => new(_root);
    private CloudDriveDeletionCoordinator Coordinator(Repository repository) => new(_mapping, repository, Store);

    [Fact]
    public async Task DeletionDefaultsOffAndRequiresSeparateExplicitConsent()
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        Assert.False(await Store.IsDeletionEnabledAsync(_mapping));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.SetDeletionEnabledAsync(_mapping, true, false));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(new(_mapping.ProfileId)).PrepareAsync("identity", "/share/file"));
        await Store.SetDeletionEnabledAsync(_mapping, true, true);
        Assert.True(await new DesktopCloudDriveSyncStore(_root).IsDeletionEnabledAsync(_mapping));
        await Store.SetWritebackEnabledAsync(_mapping, false, true);
        Assert.False(await Store.IsDeletionEnabledAsync(_mapping));
    }

    [Fact]
    public async Task AllSharesDeletesOnlyInsideSharesAndKeepsBothRootsProtected()
    {
        var mapping = _mapping with { Scope = DesktopDriveScope.AllShares }; var repository = new Repository(mapping.ProfileId);
        await Store.SetWritebackEnabledAsync(mapping, true, true); await Store.SetDeletionEnabledAsync(mapping, true, true);
        var coordinator = new CloudDriveDeletionCoordinator(mapping, repository, Store);
        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.PrepareAsync("root", "/"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.PrepareAsync("share", "/share"));
        Assert.Equal(0, repository.Deletes);
        var prepared = await coordinator.PrepareAsync("file", "/share/file");
        Assert.Equal(CloudDriveDeletionPhase.ServerVerified, (await coordinator.ConfirmAsync(prepared, true)).Phase);
        Assert.Equal(1, repository.Deletes); Assert.True(repository.Items.ContainsKey("/share"));
    }

    [Fact]
    public async Task ConfirmedDeletionIsSubmittedOnceAndNeedsSeparateLocalCompletion()
    {
        var repository = await ReadyAsync();
        var prepared = await Coordinator(repository).PrepareAsync("original", "/share/file");
        Assert.Equal(0, repository.Deletes);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).ConfirmAsync(prepared, false));
        var result = await Coordinator(repository).ConfirmAsync(prepared, true);
        Assert.Equal(CloudDriveDeletionPhase.ServerVerified, result.Phase); Assert.Equal(1, repository.Deletes);
        Assert.Equal(result, await Coordinator(repository).ConfirmAsync(result, true));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.SetDeletionEnabledAsync(_mapping, false, true));
        Assert.Equal(result, Assert.Single(await new DesktopCloudDriveSyncStore(_root).ReadDeletionOperationsAsync(_mapping)));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LostResponseNeverReplaysAndSameNameRecreationIsNotDeleted(bool recreate)
    {
        var repository = await ReadyAsync(); repository.ThrowAfterDelete = true;
        var operation = await Coordinator(repository).PrepareAsync("original", "/share/file");
        operation = await Coordinator(repository).ConfirmAsync(operation, true);
        Assert.Equal(CloudDriveDeletionPhase.Submitted, operation.Phase);
        if (recreate) repository.Items["/share/file"] = new(false, "new content");
        Assert.Equal(operation, await Coordinator(repository).ConfirmAsync(operation, true));
        var result = await Coordinator(repository).ReviewAsync(operation.Id);
        Assert.Equal(recreate ? CloudDriveDeletionPhase.Submitted : CloudDriveDeletionPhase.ServerVerified, result.Phase);
        Assert.Equal(1, repository.Deletes);
    }

    [Theory]
    [InlineData("metadata")]
    [InlineData("content")]
    [InlineData("permission")]
    public async Task ChangedTargetIsRejectedBeforeSubmission(string change)
    {
        var repository = await ReadyAsync(); var operation = await Coordinator(repository).PrepareAsync("original", "/share/file");
        repository.Items["/share/file"] = change switch
        {
            "metadata" => new(false, "base", Time: DateTimeOffset.UnixEpoch.AddSeconds(2)),
            "content" => new(false, "next"),
            _ => new(false, "base", Deletable: false),
        };
        await Assert.ThrowsAnyAsync<Exception>(() => Coordinator(repository).ConfirmAsync(operation, true));
        Assert.Equal(0, repository.Deletes); Assert.Equal(CloudDriveDeletionPhase.Prepared, Assert.Single(await Store.ReadDeletionOperationsAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task DirectoryChecksAllPagesBeforeAnyDelete()
    {
        var repository = await ReadyAsync(); repository.Items["/share/folder"] = new(true);
        for (var index = 0; index < 201; index++) repository.Items[$"/share/folder/{index:D3}"] = new(false, "child");
        repository.Items["/share/folder/200"] = new(false, "child", Deletable: false);
        var operation = await Coordinator(repository).PrepareAsync("folder", "/share/folder");
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => Coordinator(repository).ConfirmAsync(operation, true));
        Assert.Equal(new[] { 0, 200 }, repository.Offsets); Assert.Equal(0, repository.Deletes);
        repository.Items["/share/folder/200"] = new(false, "child");
        Assert.Equal(CloudDriveDeletionPhase.ServerVerified, (await Coordinator(repository).ConfirmAsync(operation, true)).Phase);
        Assert.Equal(1, repository.Deletes);
    }

    [Fact]
    public async Task FolderRequestCombinesUnsubmittedChildRequestsAndInvalidatesOldConfirmation()
    {
        var repository = await ReadyAsync(); repository.Items["/share/folder"] = new(true);
        repository.Items["/share/folder/child"] = new(false, "child");
        var child = await Coordinator(repository).PrepareAsync("child", "/share/folder/child");
        var folder = await Coordinator(repository).PrepareAsync("folder", "/share/folder");
        var records = await Store.ReadDeletionOperationsAsync(_mapping);
        Assert.Equal(folder, Assert.Single(records, item => item.IsPending));
        Assert.Equal(CloudDriveDeletionPhase.Abandoned, records.Single(item => item.Id == child.Id).Phase);
        await Assert.ThrowsAsync<InvalidDataException>(() => Coordinator(repository).ConfirmAsync(child, true));
        Assert.Equal(0, repository.Deletes);
        Assert.Equal(CloudDriveDeletionPhase.ServerVerified, (await Coordinator(repository).ConfirmAsync(folder, true)).Phase);
        Assert.Equal(1, repository.Deletes);
    }

    [Fact]
    public async Task FolderRequestCannotAbsorbChildWhoseDeletionOutcomeIsUnknown()
    {
        var repository = await ReadyAsync(); repository.Items["/share/folder"] = new(true);
        repository.Items["/share/folder/child"] = new(false, "child"); repository.ThrowAfterDelete = true;
        var child = await Coordinator(repository).PrepareAsync("child", "/share/folder/child");
        child = await Coordinator(repository).ConfirmAsync(child, true);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).PrepareAsync("folder", "/share/folder"));
        Assert.Equal(child, Assert.Single(await Store.ReadDeletionOperationsAsync(_mapping))); Assert.Equal(1, repository.Deletes);
    }

    [Theory]
    [InlineData("symbolic_link", "normal")]
    [InlineData("file", "remote")]
    [InlineData("dir", "shared_folder")]
    public async Task UnsafeChildBlocksDirectoryDeletion(string type, string mount)
    {
        var repository = await ReadyAsync(); repository.Items["/share/folder"] = new(true);
        repository.Items["/share/folder/child"] = new(type == "dir", "", Type: type, Mount: mount);
        var operation = await Coordinator(repository).PrepareAsync("folder", "/share/folder");
        await Assert.ThrowsAsync<UnauthorizedAccessException>(() => Coordinator(repository).ConfirmAsync(operation, true));
        Assert.Equal(0, repository.Deletes);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PendingOrKeptLocalContentPreventsDeletion(bool kept)
    {
        var repository = await ReadyAsync(); var path = Path.Combine(_root, "edit"); await File.WriteAllTextAsync(path, "local edit");
        var change = await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), "/share/file", path, null);
        if (kept) await Store.KeepLocallyAsync(_mapping, change.Id, true);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).PrepareAsync("original", "/share/file"));
        Assert.Empty(await Store.ReadDeletionOperationsAsync(_mapping)); Assert.Equal(0, repository.Deletes);
        await using var content = await Store.OpenContentAsync(_mapping, change.Id); using var reader = new StreamReader(content);
        Assert.Equal("local edit", await reader.ReadToEndAsync());
    }

    [Fact]
    public async Task PreparedDeletionReservesPathUntilExplicitAbandonment()
    {
        var repository = await ReadyAsync(); var operation = await Coordinator(repository).PrepareAsync("original", "/share/file");
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.BindVersionAsync(_mapping, new("/share/file", "\"new\"", 4)));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.SetWritebackEnabledAsync(_mapping, false, true));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.TryRemoveLocalProjectionAsync(_mapping, "/share/file", _ => Task.FromResult(true)));
        await Coordinator(repository).AbandonAsync(operation, true);
        await Store.BindVersionAsync(_mapping, new("/share/file", "\"new\"", 4));
        Assert.Equal(0, repository.Deletes);
    }

    [Fact]
    public async Task SubmittedDeletionCannotBeAbandonedOrCompletedWithoutReadback()
    {
        var repository = await ReadyAsync(); repository.ThrowAfterDelete = true;
        var operation = await Coordinator(repository).PrepareAsync("original", "/share/file"); operation = await Coordinator(repository).ConfirmAsync(operation, true);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).AbandonAsync(operation, true));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.UpdateDeletionOperationAsync(_mapping, operation, operation with { Phase = CloudDriveDeletionPhase.Completed }));
        repository.FailReads = true;
        await Assert.ThrowsAsync<IOException>(() => Coordinator(repository).ReviewAsync(operation.Id));
        Assert.Equal(CloudDriveDeletionPhase.Submitted, Assert.Single(await Store.ReadDeletionOperationsAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task VersionEightMissingDeletionFieldsCannotResetToReadOnly()
    {
        await ReadyAsync(); var path = Path.Combine(_root, _mapping.Id.ToString("N"), "state.json");
        var state = JsonNode.Parse(await File.ReadAllTextAsync(path))!.AsObject(); Assert.Equal(8, state["Version"]!.GetValue<int>());
        state.Remove("DeletionEnabled"); await File.WriteAllTextAsync(path, state.ToJsonString());
        var damaged = await File.ReadAllTextAsync(path);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.IsDeletionEnabledAsync(_mapping));
        Assert.Equal(damaged, await File.ReadAllTextAsync(path));
    }

    [Fact]
    public async Task MissingDeleteCapabilityCannotCreateOrSubmitDeletion()
    {
        var repository = await ReadyAsync(); repository.DeleteAvailable = false;
        await Assert.ThrowsAsync<NotSupportedException>(() => Coordinator(repository).PrepareAsync("original", "/share/file"));
        Assert.Empty(await Store.ReadDeletionOperationsAsync(_mapping));
        repository.DeleteAvailable = true;
        var operation = await Coordinator(repository).PrepareAsync("original", "/share/file");
        repository.DeleteAvailable = false;
        await Assert.ThrowsAsync<NotSupportedException>(() => Coordinator(repository).ConfirmAsync(operation, true));
        Assert.Equal(0, repository.Deletes);
    }

    [Fact]
    public async Task EmptyFileBaselineChangePreventsPreparingDeletion()
    {
        var repository = await ReadyAsync(); repository.Items["/share/file"] = new(false, "", Time: DateTimeOffset.UnixEpoch.AddSeconds(2));
        await Store.BindEmptyFileBaselineAsync(_mapping, "/share/file", DateTimeOffset.UnixEpoch);
        await Assert.ThrowsAsync<InvalidDataException>(() => Coordinator(repository).PrepareAsync("original", "/share/file"));
        Assert.Empty(await Store.ReadDeletionOperationsAsync(_mapping));
    }

    [Theory]
    [InlineData("/share")]
    [InlineData("/")]
    [InlineData("/other/file")]
    [InlineData("/share/#recycle/file")]
    [InlineData("/share/folder/../file")]
    public async Task ScopeAndProtectedPathsAreRejectedWithoutWrites(string path)
    {
        var repository = await ReadyAsync();
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).PrepareAsync("original", path));
        Assert.Empty(await Store.ReadDeletionOperationsAsync(_mapping)); Assert.Equal(0, repository.Deletes);
    }

    [Fact]
    public async Task RepositoryFromAnotherProfileCannotPrepareDeletion()
    {
        await ReadyAsync(); var repository = new Repository(Guid.NewGuid());
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).PrepareAsync("original", "/share/file"));
        Assert.Empty(await Store.ReadDeletionOperationsAsync(_mapping)); Assert.Equal(0, repository.Deletes);
    }

    [Fact]
    public async Task RelocationAndCreationCannotBypassDeletionReservationsOrDowngradeSchema()
    {
        var repository = await ReadyAsync();
        await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/file", "/share/other"]);
        var operation = await Coordinator(repository).PrepareAsync("original", "/share/file");
        var relocation = new CloudDriveRelocationOperation(Guid.NewGuid(), "other", "/share/other", "/share/file", "file", false, 4,
            DateTimeOffset.UnixEpoch, [new("/share/other", "/share/file", false)], 0, CloudDriveRelocationPhase.Prepared, DateTimeOffset.UtcNow);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.AddRelocationOperationAsync(_mapping, relocation));
        var localRoot = Path.Combine(_root, "drive"); Directory.CreateDirectory(localRoot);
        var localFile = Path.Combine(localRoot, "file"); await File.WriteAllTextAsync(localFile, "new");
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.RegisterLocalCreationAsync(_mapping, localRoot, localFile, []));
        await Coordinator(repository).AbandonAsync(operation, true);
        await Store.AddRelocationOperationAsync(_mapping, relocation);
        Assert.True(await Store.IsDeletionEnabledAsync(_mapping));
        Assert.Equal(CloudDriveDeletionPhase.Abandoned, Assert.Single(await Store.ReadDeletionOperationsAsync(_mapping)).Phase);
        Assert.Equal(8, JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(_root, _mapping.Id.ToString("N"), "state.json")))!["Version"]!.GetValue<int>());
    }

    private async Task<Repository> ReadyAsync()
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true); await Store.SetDeletionEnabledAsync(_mapping, true, true);
        return new(_mapping.ProfileId);
    }
    private sealed record Entry(bool Directory, string Content = "", bool Deletable = true, DateTimeOffset? Time = null, string? Type = null, string Mount = "normal");
    private sealed class Repository(Guid profileId) : IDsmRepository, IFilePreviewRepository, IFileRecycleRepository
    {
        public Guid ProfileId => profileId;
        public IReadOnlyList<AppModule> AvailableModules => [AppModule.Files];
        internal Dictionary<string, Entry> Items = new(StringComparer.Ordinal) { ["/share"] = new(true, Mount: "shared_folder"), ["/share/file"] = new(false, "base") };
        internal int Deletes;
        internal bool ThrowAfterDelete, FailReads;
        internal bool DeleteAvailable = true;
        public FileRecycleAvailability Availability => new(DeleteAvailable, false, DeleteAvailable ? 2 : null);
        internal List<int> Offsets = [];
        private FileItem Item(string path) { var entry = Items[path]; return new(path, path[(path.LastIndexOf('/') + 1)..], entry.Directory,
            entry.Directory ? 0 : Encoding.UTF8.GetByteCount(entry.Content), entry.Time ?? DateTimeOffset.UnixEpoch, null, true, entry.Deletable); }
        public Task<FileEntryMetadata?> ReadFileMetadataAsync(string path, CancellationToken token = default)
        {
            if (FailReads) throw new IOException("合成读取失败");
            return Task.FromResult<FileEntryMetadata?>(Items.TryGetValue(path, out var entry) ? new(Item(path), entry.Type ?? (entry.Directory ? "dir" : "file"), entry.Mount) : null);
        }
        public Task DeleteFilesAsync(IReadOnlyList<string> paths, CancellationToken token = default)
        {
            Deletes++; var root = Assert.Single(paths);
            foreach (var key in Items.Keys.Where(key => DesktopDrivePath.IsAncestorOrSame(root, key)).ToArray()) Items.Remove(key);
            if (ThrowAfterDelete) throw new IOException("合成回执丢失"); return Task.CompletedTask;
        }
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, CancellationToken token = default)
        {
            Offsets.Add(offset); var children = Items.Keys.Where(key => key[..Math.Max(1, key.LastIndexOf('/'))] == path).Order(StringComparer.Ordinal).ToArray();
            return Task.FromResult(new FilePage(children.Skip(offset).Take(limit).Select(Item).ToArray(), children.Length, offset));
        }
        public Task<FileRangeReadResult> ReadFileRangeResultAsync(string path, long offset, long length, string? expectedContentVersion = null,
            long? expectedTotalLength = null, CancellationToken cancellationToken = default)
        {
            var bytes = Encoding.UTF8.GetBytes(Items[path].Content); var version = "\"" + Convert.ToHexString(SHA256.HashData(bytes)) + "\"";
            return Task.FromResult(new FileRangeReadResult(206, offset, length, offset, length, bytes.LongLength, length, bytes.AsSpan((int)offset, (int)length).ToArray(), version, true));
        }
        public Task<FilePage> ListFilesAsync(string path, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, FileListOptions options, CancellationToken token = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(string path, long offset, long length, CancellationToken token = default) => throw new NotSupportedException();
        public Task<IReadOnlyList<FileItem>> SearchFilesAsync(string path, string query, CancellationToken token = default) => throw new NotSupportedException();
        public Task CreateFolderAsync(string path, string name, CancellationToken token = default) => throw new NotSupportedException();
        public Task RenameAsync(string path, string name, CancellationToken token = default) => throw new NotSupportedException();
        public Task<NasSettingsSnapshot> LoadNasSettingsAsync(CancellationToken token = default) => throw new NotSupportedException();
        public FileMD5Availability MD5Availability => new(false);
        public FileTextEditAvailability GetTextEditAvailability() => throw new NotSupportedException();
        public Task<string> CalculateMD5Async(string path, CancellationToken token = default) => throw new NotSupportedException();
        public Task<string> FormatTextContentAsync(string text, TextFormatKind kind, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FileRecycleOutcome> MoveToRecycleAsync(MoveToRecycleRequest request, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FileRecycleOutcome> RestoreFromRecycleAsync(RestoreFromRecycleRequest request, CancellationToken token = default) => throw new NotSupportedException();
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
