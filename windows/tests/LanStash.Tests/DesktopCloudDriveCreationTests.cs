using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveCreationTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-creation-tests-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic", DesktopDriveScope.Folder("/share"),
        DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, string> _paths = new(StringComparer.OrdinalIgnoreCase);
    private string LocalRoot => Path.Combine(_root, "drive");
    private DesktopCloudDriveSyncStore Store => new(Path.Combine(_root, "journal"));

    [Fact]
    public async Task NewFileIsUploadedOnceWithoutOverwriteAndCreationIntentSurvivesRestart()
    {
        var repository = await ReadyAsync();
        var local = await WriteAsync("new.txt", "new content");
        await RegisterAsync(local, default);
        Assert.False((await Store.ReadLocalCreationsAsync(_mapping))["/share/new.txt"]);
        await using var session = Session(repository);
        Assert.False(await session.ProcessPathAsync(local));
        Assert.False(await session.ProcessPathAsync(local));
        Assert.Equal(["upload:/share/new.txt"], repository.Writes);
        Assert.False(repository.LastOverwrite);
        Assert.Equal("new content", Encoding.UTF8.GetString(repository.Entries["/share/new.txt"]!));
        Assert.Empty(await Store.ReadLocalCreationsAsync(_mapping));
        Assert.Equal(CloudDriveChangeKind.SaveFile, Assert.Single(await Store.ReadChangesAsync(_mapping)).Kind);
    }

    [Fact]
    public async Task NestedDirectoriesAreCreatedBeforeTheirChildFile()
    {
        var repository = await ReadyAsync();
        var local = await WriteAsync(Path.Combine("parent", "child", "new.txt"), "nested");
        await using var session = Session(repository);
        Assert.False(await session.ProcessPathAsync(local));
        Assert.Equal(["mkdir:/share/parent", "mkdir:/share/parent/child", "upload:/share/parent/child/new.txt"], repository.Writes);
        var records = await Store.ReadChangesAsync(_mapping);
        Assert.Equal(2, records.Count(item => item.Kind == CloudDriveChangeKind.CreateDirectory));
        Assert.All(records, item => Assert.Equal(CloudDriveChangePhase.Verified, item.Phase));
    }

    [Fact]
    public async Task UnknownDirectoryNeedsExplicitReadOnlyAcceptanceBeforeChildrenCanUpload()
    {
        var repository = await ReadyAsync(); repository.LoseDirectoryResponse = true;
        var local = await WriteAsync(Path.Combine("parent", "new.txt"), "nested");
        await using var session = Session(repository);
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ProcessPathAsync(local));
        var records = await Store.ReadChangesAsync(_mapping);
        var parent = Assert.Single(records, item => item.Kind == CloudDriveChangeKind.CreateDirectory);
        Assert.Equal(CloudDriveChangePhase.Prepared, Assert.Single(records, item => item.Kind == CloudDriveChangeKind.SaveFile).Phase);
        Assert.Equal(CloudDriveChangePhase.Submitted, parent.Phase);
        var coordinator = new CloudDriveWritebackCoordinator(_mapping, repository, Store);
        var child = Assert.Single(records, item => item.Kind == CloudDriveChangeKind.SaveFile);
        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.SubmitAsync(child.Id));
        Assert.Equal(["mkdir:/share/parent"], repository.Writes);
        await using (var frozen = await Store.OpenContentAsync(_mapping, child.Id))
        using (var reader = new StreamReader(frozen)) Assert.Equal("nested", await reader.ReadToEndAsync());
        Assert.Equal(CloudDriveChangePhase.Submitted, (await coordinator.ReviewAsync(parent.Id)).Phase);
        Assert.Equal(CloudDriveChangePhase.Verified, (await coordinator.ReviewAsync(parent.Id, acceptDirectory: true)).Phase);
        Assert.False(await session.ProcessPathAsync(local));
        Assert.Equal(["mkdir:/share/parent", "upload:/share/parent/new.txt"], repository.Writes);
    }

    [Fact]
    public async Task UnknownFileCreationIsReadBackWithoutDuplicateUpload()
    {
        var repository = await ReadyAsync(); repository.LoseFileResponse = true;
        var local = await WriteAsync("new.txt", "new content");
        await using (var first = Session(repository)) Assert.False(await first.ProcessPathAsync(local));
        Assert.Equal(CloudDriveChangePhase.Submitted, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
        await using (var restarted = Session(repository)) Assert.False(await restarted.ProcessPathAsync(local));
        Assert.Equal(["upload:/share/new.txt"], repository.Writes);
        Assert.Equal(CloudDriveChangePhase.Verified, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task AcceptingParentResultWakesChildrenWithoutAnotherEditOrRestart()
    {
        var repository = await ReadyAsync(); repository.LoseDirectoryResponse = true;
        await WriteAsync(Path.Combine("parent", "new.txt"), "nested");
        var waiting = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var saved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var session = Session(repository,
            error => { if (error?.Message == "cloud.sync.parent_pending") waiting.TrySetResult(); },
            (path, change) => { if (change.Kind == CloudDriveChangeKind.SaveFile) saved.TrySetResult(); return true; });
        session.Start(() => _paths.Keys.ToArray());
        await waiting.Task.WaitAsync(TimeSpan.FromSeconds(10));
        var parent = Assert.Single(await Store.ReadChangesAsync(_mapping), item => item.Kind == CloudDriveChangeKind.CreateDirectory);
        await new CloudDriveWritebackCoordinator(_mapping, repository, Store).ReviewAsync(parent.Id, acceptDirectory: true);
        session.NotifyChanged(Path.Combine(LocalRoot, "parent"));
        await saved.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(["mkdir:/share/parent", "upload:/share/parent/new.txt"], repository.Writes);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ExistingNasTargetIsNeverAdoptedOrOverwritten(bool directory)
    {
        var repository = await ReadyAsync();
        repository.Entries["/share/occupied"] = directory ? null : Encoding.UTF8.GetBytes("remote content");
        var local = Path.Combine(LocalRoot, "occupied");
        if (directory) Directory.CreateDirectory(local); else await File.WriteAllTextAsync(local, "local content");
        await using var session = Session(repository);
        Assert.False(await session.ProcessPathAsync(local));
        Assert.Empty(repository.Writes);
        Assert.Equal(CloudDriveChangePhase.Conflict, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task ParentPermissionFailureDoesNotCreateDirectoryOrUploadChildren()
    {
        var repository = await ReadyAsync(); repository.Writable = false;
        var local = await WriteAsync(Path.Combine("parent", "new.txt"), "nested");
        await using var session = Session(repository);
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ProcessPathAsync(local));
        Assert.Empty(repository.Writes);
        var records = await Store.ReadChangesAsync(_mapping);
        Assert.Equal(CloudDriveChangePhase.Rejected, Assert.Single(records, item => item.Kind == CloudDriveChangeKind.CreateDirectory).Phase);
        Assert.Equal(CloudDriveChangePhase.Prepared, Assert.Single(records, item => item.Kind == CloudDriveChangeKind.SaveFile).Phase);
    }

    [Fact]
    public async Task NewLiteralPercentNameIsNotDecodedIntoAnAlias()
    {
        var repository = await ReadyAsync(); var local = await WriteAsync("literal%2Fname.txt", "content");
        await using var session = Session(repository);
        await session.ProcessPathAsync(local);
        Assert.True(repository.Entries.ContainsKey("/share/literal%2Fname.txt"));
        Assert.False(repository.Entries.ContainsKey("/share/literal/name.txt"));
    }

    [Fact]
    public async Task KnownNasAliasIsNotReclassifiedAsNewWithoutItsBaseline()
    {
        await ReadyAsync();
        var names = await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/a:b"]);
        var local = await WriteAsync(names["/share/a:b"], "replacement");
        Assert.Equal("/share/a:b", await Store.RegisterLocalCreationAsync(_mapping, LocalRoot, local, ["/share/a:b"]));
        Assert.Empty(await Store.ReadLocalCreationsAsync(_mapping));
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.PrepareLocalCreationAsync(_mapping, "/share/a:b", local, LocalRoot));
    }

    [Fact]
    public async Task NewKindsAndIntentsSurviveSavedCopyReleaseSchemaUpgrade()
    {
        var repository = await ReadyAsync(); var local = await WriteAsync("empty", "");
        await using var session = Session(repository); await session.ProcessPathAsync(local);
        var path = Path.Combine(_root, "journal", _mapping.Id.ToString("N"), "state.json");
        var state = JsonNode.Parse(await File.ReadAllTextAsync(path))!.AsObject();
        Assert.Equal(9, state["Version"]!.GetValue<int>());
        Assert.True(Assert.Single(await Store.ReadChangesAsync(_mapping)).ContentReleased);
        Assert.NotNull(state["LocalCreations"]); Assert.NotNull(state["EmptyFileBaselines"]);
        state["Changes"]![0]!.AsObject().Remove("Kind"); await File.WriteAllTextAsync(path, state.ToJsonString());
        var damaged = await File.ReadAllTextAsync(path);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.ReadChangesAsync(_mapping));
        Assert.Equal(damaged, await File.ReadAllTextAsync(path));
    }

    [Fact]
    public async Task StartupScanFindsOrdinaryFilesCreatedWhileAppWasClosed()
    {
        var repository = await ReadyAsync(); await WriteAsync(Path.Combine("offline", "new.txt"), "offline edit");
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var errors = new System.Collections.Concurrent.ConcurrentQueue<Exception>();
        await using (var session = Session(repository, error => { if (error is not null) errors.Enqueue(error); }, (path, change) =>
        {
            if (change.Kind == CloudDriveChangeKind.SaveFile) done.TrySetResult(); return true;
        }))
        {
            session.Start(() => _paths.Keys.ToArray());
            await done.Task.WaitAsync(TimeSpan.FromSeconds(10));
        }
        Assert.Empty(errors);
        Assert.Equal(["mkdir:/share/offline", "upload:/share/offline/new.txt"], repository.Writes);
    }

    private async Task<Repository> ReadyAsync()
    {
        Directory.CreateDirectory(LocalRoot); _paths[LocalRoot] = "/share";
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        return new Repository(_mapping.ProfileId);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AllSharesCanCreateWithinKnownShareAndRetainsVersionTenAfterAcknowledgement(bool nested)
    {
        var mapping = _mapping with { Scope = DesktopDriveScope.AllShares };
        Directory.CreateDirectory(LocalRoot);
        var share = Path.Combine(LocalRoot, "share"); Directory.CreateDirectory(share);
        var repository = new Repository(mapping.ProfileId);
        await Store.SetWritebackEnabledAsync(mapping, true, true);
        await Store.RegisterLocalNamesAsync(mapping, new Dictionary<string, string>(), ["/share"]);
        var parent = nested ? Path.Combine(share, "new-folder") : share; Directory.CreateDirectory(parent);
        var local = Path.Combine(parent, "all-shares.txt"); await File.WriteAllTextAsync(local, "all shares edit");
        var paths = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { [share] = "/share" };
        await using var session = new CloudDriveWritebackSession(mapping, LocalRoot, repository, Store,
            path => paths.GetValueOrDefault(path), _ => { }, (_, _) => true, (_, _) => true,
            registerNewPath: async (path, token) =>
            {
                var remote = await Store.RegisterLocalCreationAsync(mapping, LocalRoot, path, paths.Values.ToArray(), token);
                foreach (var created in (await Store.ReadLocalCreationsAsync(mapping, token)).Keys)
                    paths[Path.Combine(LocalRoot, created.TrimStart('/').Replace('/', Path.DirectorySeparatorChar))] = created;
                return remote;
            });
        Assert.False(await session.ProcessPathAsync(local));
        var remoteFile = nested ? "/share/new-folder/all-shares.txt" : "/share/all-shares.txt";
        Assert.Equal(nested ? new[] { "mkdir:/share/new-folder", "upload:" + remoteFile } : ["upload:" + remoteFile], repository.Writes);
        Assert.False(repository.LastOverwrite);
        Assert.Equal("all shares edit", Encoding.UTF8.GetString(repository.Entries[remoteFile]!));
        var changes = await Store.ReadChangesAsync(mapping);
        Assert.Equal(nested ? 2 : 1, changes.Count); Assert.All(changes, change => Assert.True(change.ContentReleased));
        var state = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(_root, "journal", mapping.Id.ToString("N"), "state.json")))!;
        Assert.Equal(10, state["Version"]!.GetValue<int>());
        await Store.SetWritebackEnabledAsync(mapping, false, true);
        Assert.False(await Store.IsWritebackEnabledAsync(mapping));
    }

    [Fact]
    public async Task AllSharesCannotCreateOrInventAShareAtTheMountRoot()
    {
        var mapping = _mapping with { Scope = DesktopDriveScope.AllShares };
        Directory.CreateDirectory(LocalRoot); var unregisteredShare = Path.Combine(LocalRoot, "unknown"); Directory.CreateDirectory(unregisteredShare);
        var file = Path.Combine(unregisteredShare, "file.txt"); await File.WriteAllTextAsync(file, "local only");
        await Store.SetWritebackEnabledAsync(mapping, true, true);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.RegisterLocalCreationAsync(mapping, LocalRoot, unregisteredShare, []));
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.RegisterLocalCreationAsync(mapping, LocalRoot, file, []));
        Assert.Empty(await Store.ReadLocalCreationsAsync(mapping)); Assert.Empty(await Store.ReadChangesAsync(mapping));
        Assert.Equal("local only", await File.ReadAllTextAsync(file));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task SavedFilesUpdateCacheAndStatsFailureDoesNotUploadAgain(bool failFirstUpdate)
    {
        var repository = await ReadyAsync(); var local = await WriteAsync("counted.txt", "saved content"); var modified = true;
        var reports = new List<(string Path, long Length, bool Saved)>();
        await using var session = new CloudDriveWritebackSession(_mapping, LocalRoot, repository, Store,
            path => _paths.GetValueOrDefault(path), _ => { }, (_, _) => modified,
            (_, _) => { modified = false; return true; }, RegisterAsync,
            cacheChanged: (path, length, saved, _) =>
            {
                reports.Add((path, length, saved));
                if (failFirstUpdate && reports.Count == 1) throw new IOException("合成统计写入失败");
                return Task.CompletedTask;
            });
        if (failFirstUpdate) await Assert.ThrowsAsync<IOException>(() => session.ProcessPathAsync(local));
        else Assert.False(await session.ProcessPathAsync(local));
        Assert.True(Assert.Single(await Store.ReadChangesAsync(_mapping)).ContentReleased);
        Assert.False(await session.ProcessPathAsync(local));
        Assert.Equal(new[] { ("/share/counted.txt", 13L, true), ("/share/counted.txt", 13L, false) }, reports);
        Assert.Equal(["upload:/share/counted.txt"], repository.Writes);
    }

    [Fact]
    public async Task ObservedRenamePrecedesScanAndUploadsEditToRelocatedExistingFile()
    {
        var repository = await ReadyAsync();
        var source = Path.Combine(LocalRoot, "original.txt"); var target = await WriteAsync("renamed.txt", "edited content");
        _paths[source] = "/share/original.txt"; repository.Entries["/share/original.txt"] = [];
        await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/original.txt"]);
        await Store.BindEmptyFileBaselineAsync(_mapping, "/share/original.txt", DateTimeOffset.UnixEpoch);
        var catalog = new DesktopCloudDriveStore(Path.Combine(_root, "catalog.json")); await catalog.SaveAsync([_mapping]);
        var identity = Assert.Single(await catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/original.txt"])).Key;
        var bound = false; var registered = 0;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var errors = new System.Collections.Concurrent.ConcurrentQueue<Exception>();
        await using (var session = new CloudDriveWritebackSession(_mapping, LocalRoot, repository, Store,
            path => _paths.GetValueOrDefault(path), error => { if (error is not null) errors.Enqueue(error); },
            (_, _) => true, (_, _) => { done.TrySetResult(); return true; },
            registerNewPath: (path, token) => { Interlocked.Increment(ref registered); return RegisterAsync(path, token); },
            renamedLocalPath: (oldPath, newPath, _) =>
            {
                Assert.Equal(source, oldPath); Assert.Equal(target, newPath); bound = true; return Task.CompletedTask;
            },
            resolveExistingPath: async (path, token) =>
            {
                Assert.True(bound); Assert.Equal(target, path);
                if (_paths.TryGetValue(path, out var existing)) return existing;
                var operation = await new CloudDriveRelocationCoordinator(_mapping, repository, Store)
                    .StartAsync(identity, "/share/original.txt", "/share/renamed.txt", "renamed.txt", true, token);
                await new CloudDriveRelocationCompletion(_mapping, Store, catalog, _ => bound).CompleteAsync(operation.Id, token);
                _paths.TryRemove(source, out _); _paths[target] = "/share/renamed.txt";
                return "/share/renamed.txt";
            }))
        {
            session.NotifyRenamed(source, target);
            session.Start(() => _paths.Keys.Where(path => path != LocalRoot).ToArray());
            await done.Task.WaitAsync(TimeSpan.FromSeconds(10));
        }
        Assert.Empty(errors); Assert.Equal(0, registered);
        Assert.Equal(["rename:/share/renamed.txt", "upload:/share/renamed.txt"], repository.Writes);
        Assert.True(repository.LastOverwrite); Assert.False(repository.Entries.ContainsKey("/share/original.txt"));
        Assert.Equal("edited content", Encoding.UTF8.GetString(repository.Entries["/share/renamed.txt"]!));
        Assert.Equal(CloudDriveChangePhase.Verified, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
        Assert.Empty(await Store.ReadLocalCreationsAsync(_mapping));
    }

    [Fact]
    public async Task FailedRenameBindingCannotFallThroughToNewFileUpload()
    {
        var repository = await ReadyAsync(); var target = await WriteAsync("renamed.txt", "protected edit");
        var failed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var registered = 0;
        await using (var session = new CloudDriveWritebackSession(_mapping, LocalRoot, repository, Store,
            _ => null, error => { if (error is not null) failed.TrySetResult(); },
            registerNewPath: (path, token) => { Interlocked.Increment(ref registered); return RegisterAsync(path, token); },
            renamedLocalPath: (_, _, _) => throw new InvalidDataException("合成身份拒绝")))
        {
            session.NotifyRenamed(Path.Combine(LocalRoot, "original.txt"), target); session.Start(() => []);
            await failed.Task.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.False(await session.ProcessPathAsync(target));
        }
        Assert.Equal(0, registered); Assert.Empty(repository.Writes); Assert.Empty(await Store.ReadChangesAsync(_mapping));
        Assert.Equal("protected edit", await File.ReadAllTextAsync(target));
    }

    [Fact]
    public async Task ConsecutiveRenamesKeepOriginalSourceAndBusyRetryPrecedesNewFileRegistration()
    {
        var repository = await ReadyAsync(); var target = await WriteAsync("final.txt", "edit");
        var original = Path.Combine(LocalRoot, "original.txt"); var intermediate = Path.Combine(LocalRoot, "middle.txt");
        var calls = 0; var bound = false;
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using (var session = new CloudDriveWritebackSession(_mapping, LocalRoot, repository, Store, _ => null, _ => { },
            registerNewPath: (_, _) => { Assert.True(bound); done.TrySetResult(); return Task.FromResult<string?>(null); },
            renamedLocalPath: (source, destination, _) =>
            {
                Assert.Equal(original, source); Assert.Equal(target, destination);
                if (Interlocked.Increment(ref calls) == 1) throw new IOException("合成占用", unchecked((int)0x80070020));
                bound = true; return Task.CompletedTask;
            }))
        {
            session.NotifyRenamed(original, intermediate); session.NotifyRenamed(intermediate, target);
            session.Start(() => []); await done.Task.WaitAsync(TimeSpan.FromSeconds(10));
        }
        Assert.Equal(2, calls); Assert.Empty(repository.Writes);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public async Task DeletedEventsDistinguishMissingFilesFromReplacementSavesAndRenames(bool replaced, bool renamed)
    {
        var repository = await ReadyAsync(); var original = Path.Combine(LocalRoot, "original.txt");
        if (replaced) await File.WriteAllTextAsync(original, "replacement");
        var sentinel = Path.Combine(LocalRoot, "sentinel.txt");
        var observed = new List<string>(); var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using (var session = new CloudDriveWritebackSession(_mapping, LocalRoot, repository, Store, _ => null, _ => { },
            renamedLocalPath: (_, _, _) => Task.CompletedTask,
            deletedLocalPath: (path, _) => { observed.Add(path); if (path == sentinel) done.TrySetResult(); return Task.CompletedTask; }))
        {
            if (renamed) session.NotifyRenamed(original, Path.Combine(LocalRoot, "renamed.txt"));
            session.NotifyDeleted(original); session.NotifyDeleted(sentinel); session.Start(() => []);
            await done.Task.WaitAsync(TimeSpan.FromSeconds(10));
        }
        Assert.Equal(!replaced && !renamed, observed.Contains(original));
        Assert.Empty(repository.Writes);
    }
    private async Task<string> WriteAsync(string relative, string contents)
    {
        var path = Path.Combine(LocalRoot, relative); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllTextAsync(path, contents); return path;
    }
    private async Task<string?> RegisterAsync(string local, CancellationToken token)
    {
        var remote = await Store.RegisterLocalCreationAsync(_mapping, LocalRoot, local, _paths.Values.ToArray(), token);
        var names = await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), [], token);
        foreach (var path in (await Store.ReadLocalCreationsAsync(_mapping, token)).Keys)
        {
            var parent = "/share"; var physical = LocalRoot;
            foreach (var part in path[7..].Split('/')) { parent += "/" + part; physical = Path.Combine(physical, names[parent]); }
            _paths[physical] = path;
        }
        return remote;
    }
    private CloudDriveWritebackSession Session(Repository repository, Action<Exception?>? changed = null,
        Func<string, CloudDrivePendingChange, bool>? acknowledge = null) =>
        new(_mapping, LocalRoot, repository, Store, path => _paths.GetValueOrDefault(path), changed ?? (_ => { }),
            (_, _) => true, acknowledge ?? ((path, change) => change.Kind == CloudDriveChangeKind.CreateDirectory ||
                Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))) == change.ContentHash), RegisterAsync);

    private sealed class Repository(Guid profileId) : IDsmRepository, IFilePreviewRepository, IFileMutationRepository
    {
        public Guid ProfileId => profileId;
        public IReadOnlyList<AppModule> AvailableModules => [AppModule.Files];
        public FileMutationAvailability FileMutationAvailability => new(true, true, 2);
        internal readonly Dictionary<string, byte[]?> Entries = new(StringComparer.Ordinal) { ["/share"] = null };
        internal readonly List<string> Writes = [];
        internal bool Writable = true, LoseDirectoryResponse, LoseFileResponse, LastOverwrite;
        private FileItem Item(string path) => new(path, path[(path.LastIndexOf('/') + 1)..], Entries[path] is null,
            Entries[path]?.LongLength ?? 0, DateTimeOffset.UnixEpoch, null, Writable, Writable);
        public Task<FileEntryMetadata?> ReadFileMetadataAsync(string path, CancellationToken token = default) =>
            Task.FromResult<FileEntryMetadata?>(Entries.ContainsKey(path) ? new(Item(path), Entries[path] is null ? "dir" : "file", path == "/share" ? "shared_folder" : "normal") : null);
        public async Task<MutationResult> UploadFileAsync(FileUploadRequest request, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        {
            var path = request.FolderPath + "/" + request.FileName;
            Assert.True(Entries.TryGetValue(request.FolderPath, out var parent) && parent is null);
            LastOverwrite = request.Overwrite; Writes.Add("upload:" + path);
            using var output = new MemoryStream(); await request.Content.CopyToAsync(output, cancellationToken); Entries[path] = output.ToArray();
            if (LoseFileResponse) throw new IOException("合成回执丢失");
            return Result("uploadFile", false);
        }
        public Task<FileMutationOutcome> CreateFolderAsync(CreateFolderRequest request, CancellationToken cancellationToken = default)
        {
            Assert.Equal(ProfileId, request.ProfileId);
            var path = request.ParentPath + "/" + request.Name;
            Assert.True(Entries.TryGetValue(request.ParentPath, out var parent) && parent is null);
            Writes.Add("mkdir:" + path); Entries.Add(path, null);
            return Task.FromResult(new FileMutationOutcome(Result("createFolder", LoseDirectoryResponse), Item(path)));
        }
        private static MutationResult Result(string operation, bool unknown) => new(1,
            unknown ? MutationResultStatus.SubmittedButUnverified : MutationResultStatus.ConfirmedSuccess, operation, true, unknown,
            new(unknown ? 0 : 1, 0, unknown ? 1 : 0));
        public Task<FileRangeReadResult> ReadFileRangeResultAsync(string path, long offset, long length, string? expectedContentVersion = null,
            long? expectedTotalLength = null, CancellationToken cancellationToken = default)
        {
            var bytes = Entries[path]!; var version = "\"" + Convert.ToHexString(SHA256.HashData(bytes)) + "\"";
            if (expectedContentVersion is not null) Assert.Equal(expectedContentVersion, version);
            return Task.FromResult(new FileRangeReadResult(206, offset, length, offset, length, bytes.LongLength, length,
                bytes.AsSpan((int)offset, (int)length).ToArray(), version, true));
        }
        public Task<FileMutationOutcome> RenameAsync(RenameFileItemRequest request, CancellationToken token = default)
        {
            Assert.Equal(ProfileId, request.Target.ProfileId);
            var destination = request.Target.Path[..request.Target.Path.LastIndexOf('/')] + "/" + request.NewName;
            var content = Entries[request.Target.Path]; Entries.Add(destination, content); Entries.Remove(request.Target.Path);
            Writes.Add("rename:" + destination);
            return Task.FromResult(new FileMutationOutcome(Result("rename", false), Item(destination)));
        }
        public Task CreateFolderAsync(string path, string name, CancellationToken token = default) => throw new NotSupportedException();
        public Task RenameAsync(string path, string name, CancellationToken token = default) => throw new NotSupportedException();
        public Task DeleteFilesAsync(IReadOnlyList<string> paths, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FilePage> ListFilesAsync(string path, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, CancellationToken token = default) => throw new NotSupportedException();
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, FileListOptions options, CancellationToken token = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(string path, long offset, long length, CancellationToken token = default) => throw new NotSupportedException();
        public Task<IReadOnlyList<FileItem>> SearchFilesAsync(string path, string query, CancellationToken token = default) => throw new NotSupportedException();
        public Task<NasSettingsSnapshot> LoadNasSettingsAsync(CancellationToken token = default) => throw new NotSupportedException();
        public FileMD5Availability MD5Availability => new(false);
        public FileTextEditAvailability GetTextEditAvailability() => throw new NotSupportedException();
        public Task<string> CalculateMD5Async(string path, CancellationToken token = default) => throw new NotSupportedException();
        public Task<string> FormatTextContentAsync(string text, TextFormatKind kind, CancellationToken token = default) => throw new NotSupportedException();
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
