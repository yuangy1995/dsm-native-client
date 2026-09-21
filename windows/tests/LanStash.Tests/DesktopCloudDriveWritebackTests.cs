using System.Text;
using System.Security.Cryptography;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveWritebackTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-writeback-tests-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic",
        DesktopDriveScope.Folder("/share"), DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private const string Remote = "/share/item.bin";
    private DesktopCloudDriveSyncStore Store => new(_root);

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task NewAndExistingFilesRequireReadbackHashBeforeCompletion(bool existing)
    {
        var repository = new Repository(_mapping.ProfileId) { Bytes = existing ? Encoding.UTF8.GetBytes("old") : null };
        var change = await PrepareAsync(existing);
        var result = await Coordinator(repository).SubmitAsync(change.Id);
        Assert.Equal(CloudDriveChangePhase.Verified, result.Phase);
        Assert.Equal(1, repository.Uploads); Assert.Equal(existing, repository.LastOverwrite);
        Assert.Equal("new content", Encoding.UTF8.GetString(repository.Bytes!));
        Assert.True(repository.VerificationReads > 0);
        Assert.Equal(CloudDriveChangePhase.Verified, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        Assert.Equal(1, repository.Uploads);
    }

    [Fact]
    public async Task ChangedRemoteVersionStopsBeforeUpload()
    {
        var change = await PrepareAsync(true);
        var repository = new Repository(_mapping.ProfileId) { Bytes = Encoding.UTF8.GetBytes("elsewhere"), Version = "\"changed\"" };
        var result = await Coordinator(repository).SubmitAsync(change.Id);
        Assert.Equal(CloudDriveChangePhase.Conflict, result.Phase); Assert.Equal(0, repository.Uploads);
    }

    [Fact]
    public async Task NewFileCollisionIsNotOverwritten()
    {
        var change = await PrepareAsync(false);
        var repository = new Repository(_mapping.ProfileId) { Bytes = Encoding.UTF8.GetBytes("someone else's file") };
        Assert.Equal(CloudDriveChangePhase.Conflict, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        Assert.Equal(0, repository.Uploads);
    }

    [Fact]
    public async Task ParentPermissionDenialNeverSubmits()
    {
        var change = await PrepareAsync(false); var repository = new Repository(_mapping.ProfileId) { ParentWritable = false };
        Assert.Equal(CloudDriveChangePhase.Rejected, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        Assert.Equal(0, repository.Uploads);
    }

    [Fact]
    public async Task UnknownUploadSurvivesRestartAndOnlyReadsOnNextAttempt()
    {
        var change = await PrepareAsync(false); var repository = new Repository(_mapping.ProfileId) { LoseResponse = true };
        Assert.Equal(CloudDriveChangePhase.Submitted, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        Assert.Equal(CloudDriveChangePhase.Verified, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        Assert.Equal(1, repository.Uploads);
    }

    [Fact]
    public async Task SuccessfulReceiptWithDifferentBytesIsStillUnverified()
    {
        var change = await PrepareAsync(false); var repository = new Repository(_mapping.ProfileId) { CorruptResult = true };
        Assert.Equal(CloudDriveChangePhase.Submitted, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        Assert.Equal(CloudDriveChangePhase.Submitted, (await Coordinator(repository).ReviewAsync(change.Id)).Phase);
        Assert.Equal(1, repository.Uploads);
    }

    [Fact]
    public async Task ExplicitFailureIsNotUpgradedByCoincidentallyMatchingRemoteBytes()
    {
        var change = await PrepareAsync(false); var repository = new Repository(_mapping.ProfileId) { RejectUpload = true };
        Assert.Equal(CloudDriveChangePhase.Rejected, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        repository.Bytes = Encoding.UTF8.GetBytes("new content");
        Assert.Equal(CloudDriveChangePhase.Rejected, (await Coordinator(repository).ReviewAsync(change.Id)).Phase);
        Assert.Equal(1, repository.Uploads);
    }

    [Fact]
    public async Task EmptyNewFileCanBeVerifiedWithoutFabricatingEtag()
    {
        var change = await PrepareAsync(false, ""); var repository = new Repository(_mapping.ProfileId);
        Assert.Equal(CloudDriveChangePhase.Verified, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        Assert.Null(await Store.ReadVersionAsync(_mapping, Remote));
        Assert.Equal(0, repository.VerificationReads);
    }

    [Fact]
    public async Task ConcurrentCoordinatorsDoNotSendTheSameOperationTwice()
    {
        var change = await PrepareAsync(false);
        var repository = new Repository(_mapping.ProfileId) { HoldUpload = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var first = Coordinator(repository).SubmitAsync(change.Id);
        await repository.UploadStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var second = Coordinator(repository).SubmitAsync(change.Id);
        Assert.False(second.IsCompleted);
        repository.HoldUpload.SetResult();
        Assert.All(await Task.WhenAll(first, second), result => Assert.Equal(CloudDriveChangePhase.Verified, result.Phase));
        Assert.Equal(1, repository.Uploads);
    }

    [Fact]
    public async Task ExistingEmptyFileUsesFrozenTimeAndIsNotTreatedAsCreation()
    {
        var change = await PrepareEmptyExistingAsync();
        var repository = new Repository(_mapping.ProfileId) { Bytes = [], ModifiedAt = DateTimeOffset.UnixEpoch };
        Assert.Equal(CloudDriveChangePhase.Verified, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        Assert.True(repository.LastOverwrite); Assert.Equal(1, repository.Uploads);
        Assert.Equal(DateTimeOffset.UnixEpoch, (await Store.ReadChangesAsync(_mapping)).Single().EmptyBaseModifiedAt);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task ChangedEmptyBaselineStopsBeforeOverwrite(bool changedTime)
    {
        var change = await PrepareEmptyExistingAsync();
        var repository = new Repository(_mapping.ProfileId)
        { Bytes = changedTime ? [] : [1], ModifiedAt = changedTime ? DateTimeOffset.UnixEpoch.AddSeconds(1) : DateTimeOffset.UnixEpoch };
        Assert.Equal(CloudDriveChangePhase.Conflict, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        Assert.Equal(0, repository.Uploads);
    }

    [Theory]
    [InlineData("link", "normal", false)]
    [InlineData("dir", "cifs", true)]
    [InlineData("symlink", "normal", true)]
    [InlineData(null, "normal", true)]
    public async Task SpecialOrUnverifiedPathCannotBeWritten(string? type, string mount, bool parent)
    {
        var change = await PrepareAsync(true);
        var repository = new Repository(_mapping.ProfileId) { Bytes = Encoding.UTF8.GetBytes("old") };
        if (parent) repository.DirectoryKinds["/share"] = (type, mount); else repository.FileType = type;
        Assert.Equal(CloudDriveChangePhase.Rejected, (await Coordinator(repository).SubmitAsync(change.Id)).Phase);
        Assert.Equal(0, repository.Uploads); Assert.Equal(0, repository.VerificationReads);
    }

    [Fact]
    public async Task AncestorsAboveSelectedRootAreAlsoChecked()
    {
        var mapping = _mapping with { Scope = DesktopDriveScope.Folder("/share/outer/inner") };
        await Store.SetWritebackEnabledAsync(mapping, true, true);
        var source = Path.Combine(_root, "edit"); await File.WriteAllTextAsync(source, "synthetic");
        var change = await Store.PrepareSaveAsync(mapping, Guid.NewGuid(), "/share/outer/inner/item.bin", source, null);
        var repository = new Repository(mapping.ProfileId);
        repository.DirectoryKinds["/share/outer"] = ("dir", "remote");
        var result = await new CloudDriveWritebackCoordinator(mapping, repository, Store).SubmitAsync(change.Id);
        Assert.Equal(CloudDriveChangePhase.Rejected, result.Phase);
        Assert.Equal(new[] { "/share/outer/inner", "/share/outer" }, repository.MetadataPaths);
        Assert.Equal(0, repository.Uploads);
    }

    private async Task<CloudDrivePendingChange> PrepareEmptyExistingAsync()
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        var source = Path.Combine(_root, "edit"); await File.WriteAllTextAsync(source, "new content");
        return await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, source, null, emptyBaseModifiedAt: DateTimeOffset.UnixEpoch);
    }

    [Fact]
    public async Task V3MissingEmptyBaselineCannotBecomeANewFileOperation()
    {
        var change = await PrepareEmptyExistingAsync();
        var statePath = Path.Combine(_root, _mapping.Id.ToString("N"), "state.json");
        var state = System.Text.Json.Nodes.JsonNode.Parse(await File.ReadAllTextAsync(statePath))!;
        state["Changes"]![0]!.AsObject().Remove("EmptyBaseModifiedAt");
        await File.WriteAllTextAsync(statePath, state.ToJsonString());
        var repository = new Repository(_mapping.ProfileId);
        await Assert.ThrowsAsync<InvalidDataException>(() => Coordinator(repository).SubmitAsync(change.Id));
        Assert.Equal(0, repository.Uploads);
    }

    [Fact]
    public async Task RecycleTargetsCannotBePreparedForWriteback()
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        var source = Path.Combine(_root, "edit"); await File.WriteAllTextAsync(source, "synthetic");
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), "/share/#recycle/item.bin", source, null));
        Assert.Empty(await Store.ReadChangesAsync(_mapping));
    }

    [Fact]
    public async Task WrongProfileCannotReadOrUploadStagedContent()
    {
        var change = await PrepareAsync(false); var repository = new Repository(Guid.NewGuid());
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).SubmitAsync(change.Id));
        Assert.Equal(0, repository.Lists); Assert.Equal(0, repository.Uploads);
    }

    [Fact]
    public async Task SessionCapturesMappedEditUploadsAndAcknowledgesWithoutDuplicateReplay()
    {
        var (repository, local, session) = await SessionAsync();
        await using (session)
        {
            Assert.False(await session.ProcessPathAsync(local));
            Assert.False(await session.ProcessPathAsync(local));
            Assert.Equal(1, repository.Uploads);
            var saved = Assert.Single(await Store.ReadChangesAsync(_mapping));
            Assert.Equal(CloudDriveChangePhase.Verified, saved.Phase);
            Assert.Equal("\"saved\"", saved.SavedVersion?.Version);
        }
    }

    [Fact]
    public async Task EditDuringUploadIsCapturedAgainInsteadOfAcknowledgingOlderBytes()
    {
        var (repository, local, session) = await SessionAsync();
        await using (session)
        {
            repository.HoldUpload = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var first = session.ProcessPathAsync(local);
            await repository.UploadStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await File.WriteAllTextAsync(local, "newer local content");
            repository.HoldUpload.SetResult();
            Assert.True(await first);
            Assert.Equal("new content", Encoding.UTF8.GetString(repository.Bytes!));
            Assert.False(await session.ProcessPathAsync(local));
            Assert.Equal("newer local content", Encoding.UTF8.GetString(repository.Bytes!));
            Assert.Equal(2, repository.Uploads);
            Assert.Equal(2, (await Store.ReadChangesAsync(_mapping)).Count);
        }
    }

    [Fact]
    public async Task RestartedSessionReviewsUnknownUploadWithoutSendingAgain()
    {
        var (repository, local, first) = await SessionAsync();
        repository.LoseResponse = true;
        await using (first) Assert.False(await first.ProcessPathAsync(local));
        Assert.Equal(CloudDriveChangePhase.Submitted, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
        await using var second = MakeSession(repository, local);
        Assert.False(await second.ProcessPathAsync(local));
        Assert.Equal(1, repository.Uploads);
        Assert.Equal(CloudDriveChangePhase.Verified, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task NativeAcknowledgementBusyDoesNotUploadAgain()
    {
        var (repository, local, original) = await SessionAsync(); await original.DisposeAsync();
        var blocked = true;
        await using var session = MakeSession(repository, local, (path, change) =>
        {
            if (blocked) throw new IOException("合成共享冲突", unchecked((int)0x80070020));
            return Matches(path, change);
        });
        await Assert.ThrowsAsync<IOException>(() => session.ProcessPathAsync(local));
        blocked = false;
        Assert.False(await session.ProcessPathAsync(local));
        Assert.Equal(1, repository.Uploads);
    }

    [Fact]
    public async Task SavingEmptyContentPreservesBaselineForNextNonemptyEdit()
    {
        var (repository, local, session) = await SessionAsync();
        await using (session)
        {
            await File.WriteAllTextAsync(local, "");
            Assert.False(await session.ProcessPathAsync(local));
            var first = Assert.Single(await Store.ReadChangesAsync(_mapping));
            Assert.Null(first.SavedVersion);
            Assert.Equal(DateTimeOffset.UnixEpoch, first.SavedEmptyModifiedAt);
            await File.WriteAllTextAsync(local, "after empty save");
            Assert.False(await session.ProcessPathAsync(local));
            Assert.Equal("after empty save", Encoding.UTF8.GetString(repository.Bytes!));
            Assert.Equal(2, repository.Uploads);
            Assert.True(repository.LastOverwrite);
        }
    }

    [Fact]
    public async Task StoppingDuringUploadKeepsUnknownJournalAndDoesNotReplayAfterRestart()
    {
        var (repository, local, session) = await SessionAsync();
        repository.HoldUpload = new(TaskCreationOptions.RunContinuationsAsynchronously);
        session.Start(() => [local]);
        try { await repository.UploadStarted.Task.WaitAsync(TimeSpan.FromSeconds(10)); }
        finally { await session.DisposeAsync(); }
        Assert.Equal(CloudDriveChangePhase.Submitted, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
        await using var restarted = MakeSession(repository, local);
        Assert.False(await restarted.ProcessPathAsync(local));
        Assert.Equal(1, repository.Uploads);
        Assert.Equal(CloudDriveChangePhase.Submitted, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task DisabledSessionDoesNotCaptureOrReadNas()
    {
        var (repository, local, session) = await SessionAsync();
        await using (session)
        {
            await Store.SetWritebackEnabledAsync(_mapping, false, true);
            Assert.False(await session.ProcessPathAsync(local));
            Assert.Empty(await Store.ReadChangesAsync(_mapping));
            Assert.Equal(0, repository.Uploads); Assert.Equal(0, repository.Lists);
        }
    }

    [Fact]
    public async Task ChangedPublishedBaselineCannotAcknowledgeOldContent()
    {
        var (repository, local, session) = await SessionAsync();
        await using (session)
        {
            await session.ProcessPathAsync(local);
            var saved = Assert.Single(await Store.ReadChangesAsync(_mapping));
            await Store.RefreshVersionAsync(_mapping, Remote, saved.SavedVersion, new(Remote, "\"new-remote\"", 20), _ => Task.CompletedTask);
            var acknowledgements = 0;
            Assert.False(await Store.TryAcknowledgeSavedAsync(_mapping, saved, () => { acknowledgements++; return true; }));
            Assert.Equal(0, acknowledgements);
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FileSystemWatcherCoalescesEditsAndDrainsOnStop(bool existingEditAtStartup)
    {
        var (repository, local, original) = await SessionAsync(); await original.DisposeAsync();
        var acknowledged = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var errors = new System.Collections.Concurrent.ConcurrentQueue<Exception>();
        var session = MakeSession(repository, local, (path, change) =>
        {
            var matches = Matches(path, change); if (matches) acknowledged.TrySetResult(); return matches;
        }, error => { if (error is not null) errors.Enqueue(error); });
        await using (session)
        {
            if (existingEditAtStartup) await File.WriteAllTextAsync(local, "watcher edit");
            session.Start(() => existingEditAtStartup ? [local] : []);
            if (!existingEditAtStartup) await File.WriteAllTextAsync(local, "watcher edit");
            for (var index = 0; index < 30; index++) session.NotifyChanged(local);
            await acknowledged.Task.WaitAsync(TimeSpan.FromSeconds(10));
        }
        Assert.Empty(errors);
        Assert.Equal(1, repository.Uploads);
        Assert.Equal("watcher edit", Encoding.UTF8.GetString(repository.Bytes!));
        await File.WriteAllTextAsync(local, "after stop");
        session.NotifyChanged(local);
        Assert.Equal(1, repository.Uploads);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ConfirmedRetryUsesNewIdentityAndFreshBaseline(bool conflict)
    {
        var change = await PrepareAsync(true);
        var repository = new Repository(_mapping.ProfileId) { Bytes = Encoding.UTF8.GetBytes("old"), RejectUpload = !conflict };
        if (conflict) repository.Version = "\"changed\"";
        var failed = await Coordinator(repository).SubmitAsync(change.Id);
        Assert.Equal(conflict ? CloudDriveChangePhase.Conflict : CloudDriveChangePhase.Rejected, failed.Phase);
        var uploads = repository.Uploads;
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).RetryAsync(failed, false));
        Assert.Equal(uploads, repository.Uploads);
        repository.RejectUpload = false;
        var result = await Coordinator(repository).RetryAsync(failed, true);
        Assert.Equal(CloudDriveChangePhase.Verified, result.Phase);
        Assert.NotEqual(failed.Id, result.Id);
        Assert.Equal("new content", Encoding.UTF8.GetString(repository.Bytes!));
        Assert.Equal(uploads + 1, repository.Uploads);
        var history = await Store.ReadChangesAsync(_mapping);
        Assert.Equal(CloudDriveChangePhase.KeptLocally, history.Single(item => item.Id == failed.Id).Phase);
        await using var oldCopy = await Store.OpenContentAsync(_mapping, failed.Id);
        using var reader = new StreamReader(oldCopy); Assert.Equal("new content", await reader.ReadToEndAsync());
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).RetryAsync(failed, true));
        Assert.Equal(uploads + 1, repository.Uploads);
    }

    [Fact]
    public async Task UnknownSubmissionCannotBeRetriedEvenWithConfirmation()
    {
        var change = await PrepareAsync(true);
        var repository = new Repository(_mapping.ProfileId) { Bytes = Encoding.UTF8.GetBytes("old"), LoseResponse = true };
        var unknown = await Coordinator(repository).SubmitAsync(change.Id);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).RetryAsync(unknown, true));
        Assert.Equal(1, repository.Uploads);
        Assert.Equal(CloudDriveChangePhase.Submitted, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task KeptCopyCanResumeExplicitlyButCannotCompeteWithAnotherPendingSave()
    {
        var change = await PrepareAsync(true);
        await Store.KeepLocallyAsync(_mapping, change.Id, true);
        var kept = Assert.Single(await Store.ReadChangesAsync(_mapping));
        var source = Path.Combine(_root, "another"); await File.WriteAllTextAsync(source, "newer");
        var pending = await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, source, "\"old\"");
        var repository = new Repository(_mapping.ProfileId) { Bytes = Encoding.UTF8.GetBytes("old") };
        await Assert.ThrowsAsync<InvalidOperationException>(() => Coordinator(repository).RetryAsync(kept, true));
        Assert.Equal(0, repository.Uploads);
        await Store.KeepLocallyAsync(_mapping, pending.Id, true);
        var result = await Coordinator(repository).RetryAsync(kept, true);
        Assert.Equal(CloudDriveChangePhase.Verified, result.Phase);
        Assert.Equal(1, repository.Uploads);
        Assert.Equal("new content", Encoding.UTF8.GetString(repository.Bytes!));
    }

    [Fact]
    public async Task ExportPreservesFrozenContentAndDoesNotChangeSubmissionState()
    {
        var store = new DesktopCloudDriveSyncStore(Path.Combine(_root, "journal"));
        await store.SetWritebackEnabledAsync(_mapping, true, true);
        var original = Path.Combine(_root, "original"); await File.WriteAllTextAsync(original, "frozen edit");
        var record = await store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, original, null);
        var destination = Path.Combine(_root, "export.bin"); await File.WriteAllTextAsync(destination, "previous destination");
        await File.WriteAllTextAsync(original, "newer edit");
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.ExportContentAsync(_mapping, record.Id, destination, false));
        Assert.Equal("previous destination", await File.ReadAllTextAsync(destination));
        await store.ExportContentAsync(_mapping, record.Id, destination, true);
        Assert.Equal("frozen edit", await File.ReadAllTextAsync(destination));
        Assert.Equal(record, Assert.Single(await store.ReadChangesAsync(_mapping)));
        Assert.Empty(Directory.GetFiles(_root, "*.tmp"));
    }

    [Fact]
    public async Task ExportCannotOverwriteItsOwnJournalOrReplaceDestinationWhenCancelled()
    {
        var store = new DesktopCloudDriveSyncStore(Path.Combine(_root, "journal"));
        await store.SetWritebackEnabledAsync(_mapping, true, true);
        var original = Path.Combine(_root, "original"); await File.WriteAllTextAsync(original, "edit");
        var record = await store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, original, null);
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.ExportContentAsync(_mapping, record.Id,
            Path.Combine(_root, "journal", _mapping.Id.ToString("N"), "state.json"), true));
        var destination = Path.Combine(_root, "export.bin"); await File.WriteAllTextAsync(destination, "unchanged");
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.ExportContentAsync(_mapping, record.Id, destination, true, cancellation.Token));
        Assert.Equal("unchanged", await File.ReadAllTextAsync(destination));
        Assert.Equal(record, Assert.Single(await store.ReadChangesAsync(_mapping)));
        Assert.Empty(Directory.GetFiles(_root, "*.tmp"));
    }

    private async Task<(Repository Repository, string Local, CloudDriveWritebackSession Session)> SessionAsync()
    {
        var local = Path.Combine(_root, "mapped", "item.bin"); Directory.CreateDirectory(Path.GetDirectoryName(local)!);
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), [Remote]);
        await Store.BindVersionAsync(_mapping, new(Remote, "\"old\"", 3));
        await File.WriteAllTextAsync(local, "new content");
        var repository = new Repository(_mapping.ProfileId) { Bytes = Encoding.UTF8.GetBytes("old") };
        return (repository, local, MakeSession(repository, local));
    }
    private CloudDriveWritebackSession MakeSession(Repository repository, string local,
        Func<string, CloudDrivePendingChange, bool>? acknowledge = null, Action<Exception?>? stateChanged = null) =>
        new(_mapping, Path.GetDirectoryName(local)!, repository, Store,
            path => string.Equals(path, local, StringComparison.OrdinalIgnoreCase) ? Remote : null,
            stateChanged ?? (_ => { }), (_, _) => true, acknowledge ?? Matches);
    private static bool Matches(string path, CloudDrivePendingChange change)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return file.Length == change.ContentLength && Convert.ToHexString(SHA256.HashData(file)) == change.ContentHash;
    }

    private CloudDriveWritebackCoordinator Coordinator(Repository repository) => new(_mapping, repository, Store);
    private async Task<CloudDrivePendingChange> PrepareAsync(bool existing, string text = "new content")
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        if (existing) await Store.BindVersionAsync(_mapping, new(Remote, "\"old\"", 3));
        var source = Path.Combine(_root, "edit"); await File.WriteAllTextAsync(source, text);
        return await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, source, existing ? "\"old\"" : null);
    }

    private sealed class Repository(Guid profileId) : IDsmRepository, IFilePreviewRepository
    {
        public Guid ProfileId => profileId;
        public IReadOnlyList<AppModule> AvailableModules => [AppModule.Files];
        internal byte[]? Bytes;
        internal string Version = "\"old\"";
        internal DateTimeOffset ModifiedAt = DateTimeOffset.UnixEpoch;
        internal string? FileType = "file";
        internal readonly Dictionary<string, (string? Type, string Mount)> DirectoryKinds = [];
        internal readonly List<string> MetadataPaths = [];
        internal bool ParentWritable = true, LoseResponse, CorruptResult, RejectUpload, LastOverwrite;
        internal int Uploads, Lists, VerificationReads;
        internal TaskCompletionSource UploadStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource? HoldUpload;
        public Task<FilePage> ListFilesAsync(string path, CancellationToken token = default) => ListFilesAsync(path, 0, 500, token);
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, FileListOptions options, CancellationToken token = default) => ListFilesAsync(path, offset, limit, token);
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, CancellationToken token = default)
        {
            token.ThrowIfCancellationRequested(); Lists++;
            FileItem[] items = path == "" ? [new("/share", "share", true, 0, null, null, ParentWritable, false)] :
                Bytes is null ? [] : [new(Remote, "item.bin", false, Bytes.Length, DateTimeOffset.UnixEpoch, null, true, true)];
            return Task.FromResult(new FilePage(items.Skip(offset).Take(limit).ToArray(), items.Length, offset));
        }
        public Task<FilePresence> ProbeFilePresenceAsync(string path, CancellationToken token = default) =>
            Task.FromResult(Bytes is null ? FilePresence.Missing : FilePresence.Present);
        public Task<FileEntryMetadata?> ReadFileMetadataAsync(string path, CancellationToken token = default)
        {
            token.ThrowIfCancellationRequested(); Lists++; MetadataPaths.Add(path);
            if (path != Remote)
            {
                var kind = DirectoryKinds.GetValueOrDefault(path, (Type: (string?)"dir", Mount: path == "/share" ? "shared_folder" : "normal"));
                return Task.FromResult<FileEntryMetadata?>(new(new(path, path[(path.LastIndexOf('/') + 1)..], true, 0,
                    DateTimeOffset.UnixEpoch, null, ParentWritable, false), kind.Type, kind.Mount));
            }
            return Task.FromResult<FileEntryMetadata?>(Bytes is null ? null : new(new(Remote, "item.bin", false, Bytes.Length,
                ModifiedAt, null, true, true), FileType, "normal"));
        }
        public async Task<MutationResult> UploadFileAsync(FileUploadRequest request, IProgress<long>? progress = null, CancellationToken cancellationToken = default)
        {
            Uploads++; LastOverwrite = request.Overwrite; UploadStarted.TrySetResult();
            Assert.Equal("/share", request.FolderPath); Assert.Equal("item.bin", request.FileName);
            if (HoldUpload is not null) await HoldUpload.Task.WaitAsync(cancellationToken);
            if (!RejectUpload)
            {
                using var result = new MemoryStream(); await request.Content.CopyToAsync(result, cancellationToken);
                Bytes = result.ToArray(); Assert.Equal(request.Length, Bytes.LongLength); Version = "\"saved\"";
                if (CorruptResult && Bytes.Length > 0) Bytes[0] ^= 0xff;
            }
            if (LoseResponse) throw new IOException("合成上传回执丢失");
            return new(1, RejectUpload ? MutationResultStatus.ConfirmedFailure : MutationResultStatus.ConfirmedSuccess,
                "uploadFile", true, false, new(RejectUpload ? 0 : 1, RejectUpload ? 1 : 0, 0));
        }
        public Task<FileRangeReadResult> ReadFileRangeResultAsync(string path, long offset, long length, string? expectedContentVersion = null,
            long? expectedTotalLength = null, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested(); var bytes = Bytes ?? throw new FileNotFoundException();
            if (expectedContentVersion is not null) { VerificationReads++; Assert.Equal(Version, expectedContentVersion); Assert.Equal(bytes.Length, expectedTotalLength); }
            return Task.FromResult(new FileRangeReadResult(206, offset, length, offset, length, bytes.LongLength, length,
                bytes.AsSpan((int)offset, (int)length).ToArray(), Version, true));
        }
        public async Task<byte[]> ReadFileRangeAsync(string path, long offset, long length, CancellationToken token = default) =>
            (await ReadFileRangeResultAsync(path, offset, length, cancellationToken: token)).Bytes;
        public FileMD5Availability MD5Availability => new(false);
        public FileTextEditAvailability GetTextEditAvailability() => throw new NotSupportedException();
        public Task<string> CalculateMD5Async(string path, CancellationToken token = default) => throw new NotSupportedException();
        public Task<string> FormatTextContentAsync(string text, TextFormatKind kind, CancellationToken token = default) => throw new NotSupportedException();
        public Task<IReadOnlyList<FileItem>> SearchFilesAsync(string path, string query, CancellationToken token = default) => throw new NotSupportedException();
        public Task CreateFolderAsync(string parent, string name, CancellationToken token = default) => throw new NotSupportedException();
        public Task RenameAsync(string path, string name, CancellationToken token = default) => throw new NotSupportedException();
        public Task DeleteFilesAsync(IReadOnlyList<string> paths, CancellationToken token = default) => throw new NotSupportedException();
        public Task<NasSettingsSnapshot> LoadNasSettingsAsync(CancellationToken token = default) => throw new NotSupportedException();
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
