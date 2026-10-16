using System.Text;
using LanStash.App.Features.Files.Office;
using LanStash.Domain;

namespace LanStash.Tests.Files.Office;

public sealed class OfficeEditingCoordinatorTests
{
    private static readonly DateTimeOffset Start = DateTimeOffset.UnixEpoch;
    [Fact]
    public async Task OldStoppedHistoryNeverShadowsTheCurrentSessionAfterUnorderedRecovery()
    {
        using var server = new OfficeTestServer(); var store = new OfficeTestStore(); var repo = server.Repository(store);
        var old = await server.BeginAsync(repo); await repo.StopOfficeSessionAsync(old.Id); var current = await server.BeginAsync(repo);
        var reversed = new OfficeTestStore();
        foreach (var pair in store.Records.Reverse()) reversed.Records.Add(pair.Key, pair.Value.ToArray());
        var cold = server.Repository(reversed, freshClient: true); using var coordinator = Coordinator(new LocalFiles(server));
        await coordinator.AttachAsync(cold);
        Assert.Equal(current.Id, coordinator.SessionFor(cold, server.RemotePath, includeStopped: true)!.Id);
        Assert.Equal(current.Id, coordinator.SessionFor(cold, server.RemotePath)!.Id);
        Assert.Null(coordinator.SessionFor(server.Repository(user: "other-user"), server.RemotePath, includeStopped: true));
        Assert.Equal(0, server.Uploads);
    }
    [Fact]
    public async Task LateOldNasCompletionCannotChangeTheNewNasSession()
    {
        using var firstServer = new OfficeTestServer { HoldUpload = new(TaskCreationOptions.RunContinuationsAsynchronously), IgnoreUploadCancellation = true };
        using var secondServer = new OfficeTestServer(); var firstRepo = firstServer.Repository(); var secondRepo = secondServer.Repository();
        var files = new LocalFiles(firstServer); using var coordinator = Coordinator(files);
        var oldSession = await coordinator.BeginAsync(firstRepo, (await firstRepo.ReadOfficeRemoteAsync(firstServer.RemotePath)).Metadata.Item, files.Path);
        files.Copy.Change("save on original NAS"); await coordinator.PollAsync(oldSession, Start);
        var saving = coordinator.PollAsync(oldSession, Start.AddSeconds(2)); await firstServer.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        coordinator.Disconnect(firstRepo.ProfileId); Assert.False(saving.IsCompleted);
        var newSession = await coordinator.BeginAsync(secondRepo, (await secondRepo.ReadOfficeRemoteAsync(secondServer.RemotePath)).Metadata.Item,
            Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".docx"));
        var newInfo = newSession.Info;
        firstServer.HoldUpload.SetResult(); await saving;
        Assert.Equal(newInfo, newSession.Info); Assert.True(newSession.Watching); Assert.Equal(OfficeEditingPhase.Watching, newSession.Phase);
        Assert.False(oldSession.Connected); Assert.False(oldSession.Watching); Assert.Null(oldSession.Copy);
        Assert.Equal(0, secondServer.Uploads); Assert.Equal(1, firstServer.Uploads);
    }
    [Fact]
    public async Task OpeningAndTouchingUnchangedCopyNeverUploads()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var files = new LocalFiles(server);
        using var coordinator = Coordinator(files); var session = await coordinator.BeginAsync(repo, (await repo.ReadOfficeRemoteAsync(server.RemotePath)).Metadata.Item, files.Path);
        var reads = server.Reads;
        await StablePoll(coordinator, session, 0);
        files.Copy.Change(files.Copy.Bytes);
        await StablePoll(coordinator, session, 5);
        Assert.Equal(0, server.Uploads); Assert.Equal(reads, server.Reads); Assert.True(session.Watching);
    }

    [Fact]
    public async Task ContinuousSavesAndAtomicReplacementUploadOnlyStableFrozenSnapshots()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var files = new LocalFiles(server);
        using var coordinator = Coordinator(files); var session = await coordinator.BeginAsync(repo, (await repo.ReadOfficeRemoteAsync(server.RemotePath)).Metadata.Item, files.Path);
        await StablePoll(coordinator, session, 0);
        files.Copy.Change("first"); await coordinator.PollAsync(session, Start.AddSeconds(3));
        files.Copy.Change("second"); await coordinator.PollAsync(session, Start.AddSeconds(4));
        Assert.Equal(0, server.Uploads);
        server.HoldUpload = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var saving = coordinator.PollAsync(session, Start.AddSeconds(6)); await server.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        files.Copy.Change("third!", replacement: true);
        await coordinator.PollAsync(session, Start.AddSeconds(7));
        Assert.Equal(1, server.Uploads); Assert.True(coordinator.HasBusySessions); Assert.False(coordinator.TryPrepareExit());
        server.HoldUpload.SetResult(); await saving;
        Assert.Equal("second", Encoding.UTF8.GetString(server.Bytes)); Assert.Equal(OfficeEditingPhase.Saved, session.Phase);
        await StablePoll(coordinator, session, 8);
        Assert.Equal("third!", Encoding.UTF8.GetString(server.Bytes)); Assert.Equal(2, server.Uploads);
    }

    [Fact]
    public async Task EditsDuringPreparationAreNotMarkedAlreadySynchronized()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var files = new LocalFiles(server);
        files.AfterDownload = () => server.AfterMd5 = () => { files.Copy.Change("changed during preparation"); server.AfterMd5 = null; };
        using var coordinator = Coordinator(files); var session = await coordinator.BeginAsync(repo, (await repo.ReadOfficeRemoteAsync(server.RemotePath)).Metadata.Item, files.Path);
        await StablePoll(coordinator, session, 0);
        Assert.Equal("changed during preparation", Encoding.UTF8.GetString(server.Bytes)); Assert.Equal(1, server.Uploads);
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task UnknownOrConflictStopsMonitoringAndKeepsCopy(bool conflict)
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var files = new LocalFiles(server);
        using var coordinator = Coordinator(files); var session = await coordinator.BeginAsync(repo, (await repo.ReadOfficeRemoteAsync(server.RemotePath)).Metadata.Item, files.Path);
        if (conflict) server.Version++; else server.LoseReceipt = true;
        files.Copy.Change("local edit"); await StablePoll(coordinator, session, 0);
        Assert.False(session.Watching); Assert.Equal(conflict ? OfficeEditingPhase.Conflict : OfficeEditingPhase.ResultUnavailable, session.Phase);
        files.Copy.Change("later edit"); await StablePoll(coordinator, session, 5);
        Assert.Equal(conflict ? 0 : 1, server.Uploads); Assert.False(files.Copy.Disposed);
        await coordinator.StopAsync(session); Assert.True(files.Copy.Disposed);
        Assert.Equal(conflict ? OfficeEditingPhase.Stopped : OfficeEditingPhase.ResultUnavailable, session.Phase);
    }

    [Fact]
    public async Task DisconnectAndReconnectRemainPausedUntilExplicitResume()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var files = new LocalFiles(server);
        using var coordinator = Coordinator(files); var session = await coordinator.BeginAsync(repo, (await repo.ReadOfficeRemoteAsync(server.RemotePath)).Metadata.Item, files.Path);
        coordinator.Disconnect(repo.ProfileId); files.Copy.Change("offline edit");
        await StablePoll(coordinator, session, 0); Assert.Equal(0, server.Uploads);
        await coordinator.AttachAsync(server.Repository());
        Assert.True(session.CanResume); Assert.Equal(OfficeEditingPhase.Paused, session.Phase); Assert.False(session.Watching);
        await coordinator.ResumeAsync(session); await StablePoll(coordinator, session, 5);
        Assert.Equal("offline edit", Encoding.UTF8.GetString(server.Bytes)); Assert.Equal(1, server.Uploads);
    }

    [Fact]
    public async Task ColdAttachmentNeverOpensFilesOrStartsSaving()
    {
        using var server = new OfficeTestServer(); var store = new OfficeTestStore(); var repo = server.Repository(store);
        var info = await server.BeginAsync(repo); var cold = server.Repository(store.Reopen()); var files = new LocalFiles(server);
        using var coordinator = Coordinator(files); await coordinator.AttachAsync(cold);
        var session = Assert.Single(coordinator.Sessions);
        Assert.Equal(info.Id, session.Id); Assert.Equal(OfficeEditingPhase.Paused, session.Phase);
        await StablePoll(coordinator, session, 0);
        Assert.Equal(0, files.Opens); Assert.Equal(0, server.Uploads);
    }

    [Fact]
    public async Task CopyLockOrReplacementHasABoundedWaitAndCanResumeAfterRecovery()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var files = new LocalFiles(server);
        using var coordinator = Coordinator(files); var session = await coordinator.BeginAsync(repo, (await repo.ReadOfficeRemoteAsync(server.RemotePath)).Metadata.Item, files.Path);
        files.Copy.Unavailable = true;
        await coordinator.PollAsync(session, Start); Assert.True(session.Watching); Assert.Equal(OfficeEditingPhase.WaitingForSave, session.Phase);
        await coordinator.PollAsync(session, Start.AddSeconds(31)); Assert.False(session.Watching); Assert.True(session.LocalUnavailable);
        files.Copy.Unavailable = false; files.Copy.Change("recovered editor save");
        await coordinator.ResumeAsync(session); await StablePoll(coordinator, session, 35);
        Assert.Equal(1, server.Uploads); Assert.Equal("recovered editor save", Encoding.UTF8.GetString(server.Bytes));
    }

    [Fact]
    public async Task CloudOwnershipIsRecheckedBeforeEachSaveAndExportDoesNotNeedRemoteOwnership()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var files = new LocalFiles(server);
        var deny = false;
        using var coordinator = new OfficeEditingCoordinator(files, (profile, _, _, _) =>
            deny && profile != Guid.Empty ? Task.FromException(new IOException("office.cloud-writeback-conflict")) : Task.CompletedTask);
        var session = await coordinator.BeginAsync(repo, (await repo.ReadOfficeRemoteAsync(server.RemotePath)).Metadata.Item, files.Path);
        deny = true; files.Copy.Change("preserved edit"); await StablePoll(coordinator, session, 0);
        Assert.Equal(OfficeEditingPhase.Paused, session.Phase); Assert.False(session.LocalUnavailable); Assert.Equal(0, server.Uploads);
        await coordinator.ExportAsync(session, Path.Combine(Path.GetTempPath(), "synthetic-export.docx"));
        Assert.Equal(Encoding.UTF8.GetBytes("preserved edit"), files.Exported);
        await Assert.ThrowsAsync<IOException>(() => coordinator.ExportAsync(session, session.LocalPath));
    }

    [Fact]
    public async Task PreparationCancellationAndDuplicateTargetsNeverCreateAnotherSession()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var files = new LocalFiles(server) { HoldDownload = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        using var coordinator = Coordinator(files); var item = (await repo.ReadOfficeRemoteAsync(server.RemotePath)).Metadata.Item;
        var preparing = coordinator.BeginAsync(repo, item, files.Path);
        await files.DownloadStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await Assert.ThrowsAsync<InvalidOperationException>(() => coordinator.BeginAsync(repo, item, files.Path + ".docx"));
        Assert.True(coordinator.HasBusySessions); coordinator.Disconnect(repo.ProfileId);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => preparing);
        Assert.Empty(coordinator.Sessions); Assert.Empty(await repo.GetOfficeSessionsAsync()); Assert.Equal(0, server.Uploads);
    }

    [Fact]
    public async Task ExitStopsFurtherMonitoringButKeepsRecoveryAndLocalContent()
    {
        using var server = new OfficeTestServer(); var repo = server.Repository(); var files = new LocalFiles(server);
        using var coordinator = Coordinator(files); var session = await coordinator.BeginAsync(repo, (await repo.ReadOfficeRemoteAsync(server.RemotePath)).Metadata.Item, files.Path);
        files.Copy.Change("still local"); Assert.True(coordinator.TryPrepareExit()); coordinator.Dispose();
        await StablePoll(coordinator, session, 0);
        Assert.Equal(0, server.Uploads); Assert.Single(await repo.GetOfficeSessionsAsync()); Assert.Equal("still local", Encoding.UTF8.GetString(files.Copy.Bytes));
    }

    private static OfficeEditingCoordinator Coordinator(LocalFiles files) => new(files, (_, _, _, _) => Task.CompletedTask);
    private static async Task StablePoll(OfficeEditingCoordinator coordinator, OfficeEditingSession session, int seconds)
    { await coordinator.PollAsync(session, Start.AddSeconds(seconds)); await coordinator.PollAsync(session, Start.AddSeconds(seconds + 2)); }

    private sealed class LocalFiles(OfficeTestServer server) : IOfficeLocalFiles
    {
        private readonly Dictionary<string, LocalCopy> _otherCopies = [];
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".docx");
        public LocalCopy Copy { get; } = new(server.Bytes);
        public int Opens;
        public byte[]? Exported;
        public Action? AfterDownload;
        public TaskCompletionSource? HoldDownload;
        public TaskCompletionSource DownloadStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<OfficeContentFingerprint> DownloadAsync(IOfficeEditingRepository repository, OfficeRemoteSnapshot baseline, string destination, CancellationToken token)
        {
            DownloadStarted.TrySetResult(); if (HoldDownload is not null) await HoldDownload.Task.WaitAsync(token);
            CopyFor(destination).Change(server.Bytes); var fingerprint = OfficeTestServer.Fingerprint(server.Bytes); AfterDownload?.Invoke(); return fingerprint;
        }
        private LocalCopy CopyFor(string path)
        { if (path == Path) return Copy; if (!_otherCopies.TryGetValue(path, out var value)) _otherCopies[path] = value = new(server.Bytes); return value; }
        public IOfficeLocalCopy Open(string path) { Opens++; var copy = CopyFor(path); copy.Disposed = false; return copy; }
        public Task ExportAsync(IOfficeLocalCopy copy, string destination, CancellationToken token)
        { Exported = ((LocalCopy)copy).Bytes.ToArray(); return Task.CompletedTask; }
    }
    private sealed class LocalCopy(byte[] bytes) : IOfficeLocalCopy
    {
        public byte[] Bytes { get; private set; } = bytes.ToArray();
        public bool Unavailable, Disposed;
        private long _revision;
        private ulong _identity = 1;
        public void Change(string value, bool replacement = false) => Change(Encoding.UTF8.GetBytes(value), replacement);
        public void Change(byte[] value, bool replacement = false) { Bytes = value.ToArray(); _revision++; if (replacement) _identity++; }
        public OfficeLocalStamp ReadStamp()
        { if (Unavailable) throw new IOException("synthetic lock"); return new(1, _identity, 0, Bytes.LongLength, 100, _revision); }
        public Task<OfficeUploadSnapshot> FreezeAsync(CancellationToken token) => Task.FromResult(new OfficeUploadSnapshot(new MemoryStream(Bytes.ToArray()), OfficeTestServer.Fingerprint(Bytes), ReadStamp()));
        public void Dispose() => Disposed = true;
    }
}
