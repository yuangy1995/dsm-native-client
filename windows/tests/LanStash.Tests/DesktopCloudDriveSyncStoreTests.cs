using System.Text.Json.Nodes;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveSyncStoreTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-sync-tests-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic",
        DesktopDriveScope.Folder("/share/work"), DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private const string Remote = "/share/work/document.txt";
    private DesktopCloudDriveSyncStore Store => new(Path.Combine(_root, "journal"));
    private string StatePath => Path.Combine(_root, "journal", _mapping.Id.ToString("N"), "state.json");
    private string ContentPath(Guid id) => Path.Combine(Path.GetDirectoryName(StatePath)!, id.ToString("N") + ".content");

    [Fact]
    public async Task OldMappingDefaultsReadOnlyAndDoesNotRewriteLegacyConfiguration()
    {
        Directory.CreateDirectory(_root);
        var legacy = Path.Combine(_root, "desktop-drives-v1.json");
        await File.WriteAllTextAsync(legacy, "legacy-mapping-sentinel");
        Assert.False(await Store.IsWritebackEnabledAsync(_mapping));
        Assert.Empty(await Store.ReadChangesAsync(_mapping));
        Assert.Null(await Store.ReadVersionAsync(_mapping, Remote));
        Assert.Equal("legacy-mapping-sentinel", await File.ReadAllTextAsync(legacy));
        Assert.False(File.Exists(StatePath));
    }

    [Fact]
    public async Task ConfirmationAndValidScopeAreRequired()
    {
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.SetWritebackEnabledAsync(_mapping, true, false));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.SetWritebackEnabledAsync(_mapping with { Scope = DesktopDriveScope.Folder("/") }, true, true));
        Assert.False(await Store.IsWritebackEnabledAsync(_mapping));
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        Assert.True(await Store.IsWritebackEnabledAsync(_mapping));
    }

    [Fact]
    public async Task StrongVersionSurvivesNewStoreAndRejectsSilentReplacement()
    {
        var version = new CloudDriveContentVersion(Remote, "\"v1\"", 123);
        await Store.BindVersionAsync(_mapping, version);
        Assert.Equal(version, await Store.ReadVersionAsync(_mapping, Remote));
        await Store.BindVersionAsync(_mapping, version);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.BindVersionAsync(_mapping, version with { Version = "\"v2\"" }));
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.BindVersionAsync(_mapping, version with { Length = 124 }));
        Assert.Equal(version, await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Theory]
    [InlineData("W/\"weak\"")]
    [InlineData("unquoted")]
    [InlineData("\"bad\r\nheader\"")]
    public async Task InvalidVersionsNeverCreateState(string version)
    {
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.BindVersionAsync(_mapping, new(Remote, version, 1)));
        Assert.False(File.Exists(StatePath));
    }

    [Theory]
    [InlineData("/other/document.txt")]
    [InlineData("/share/work/../document.txt")]
    [InlineData("/share/work")]
    [InlineData("/share/work/document\\child")]
    public async Task ForeignOrAmbiguousTargetsAreRejected(string path)
    {
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.ReadVersionAsync(_mapping, path));
    }

    [Fact]
    public async Task ProfileAndMappingScopeAreBoundToPersistedState()
    {
        await Store.BindVersionAsync(_mapping, new(Remote, "\"v1\"", 1));
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.IsWritebackEnabledAsync(_mapping with { ProfileId = Guid.NewGuid() }));
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.IsWritebackEnabledAsync(_mapping with { Scope = DesktopDriveScope.Folder("/other") }));
        Assert.False(await Store.IsWritebackEnabledAsync(_mapping with { Id = Guid.NewGuid() }));
    }

    [Fact]
    public async Task PreparedContentIsFrozenAndSameRequestNeverReplacesIt()
    {
        var (change, source) = await PrepareAsync();
        await File.WriteAllTextAsync(source, "later-edit");
        var again = await Store.PrepareSaveAsync(_mapping, change.Id, Remote, source, null);
        Assert.Equal(change, again);
        Assert.Equal("original-edit", await File.ReadAllTextAsync(ContentPath(change.Id)));
        Assert.Single(await Store.ReadChangesAsync(_mapping));
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.PrepareSaveAsync(_mapping, change.Id,
            "/share/work/other.txt", source, null));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, source, null));
    }

    [Fact]
    public async Task SubmittedRequestSurvivesRestartAndCannotBeSentAgainOrDiscarded()
    {
        var (change, _) = await PrepareAsync();
        Assert.True(await Store.TryMarkSubmittedAsync(_mapping, change.Id));
        Assert.False(await Store.TryMarkSubmittedAsync(_mapping, change.Id));
        Assert.Equal(CloudDriveChangePhase.Submitted, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.KeepLocallyAsync(_mapping, change.Id, true));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.SetWritebackEnabledAsync(_mapping, false, true));
        Assert.True(File.Exists(ContentPath(change.Id)));
    }

    [Fact]
    public async Task PendingContentIsRetainedOnConflictAndExplicitKeepThenDisable()
    {
        var (change, _) = await PrepareAsync();
        await Store.MarkConflictAsync(_mapping, change.Id);
        Assert.False(await Store.TryMarkSubmittedAsync(_mapping, change.Id));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.KeepLocallyAsync(_mapping, change.Id, false));
        await Store.KeepLocallyAsync(_mapping, change.Id, true);
        await Store.SetWritebackEnabledAsync(_mapping, false, true);
        Assert.False(await Store.IsWritebackEnabledAsync(_mapping));
        Assert.Equal(CloudDriveChangePhase.KeptLocally, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
        Assert.Equal("original-edit", await File.ReadAllTextAsync(ContentPath(change.Id)));
    }

    [Fact]
    public async Task ChangedStagedContentCannotBeSubmitted()
    {
        var (change, _) = await PrepareAsync();
        await File.WriteAllTextAsync(ContentPath(change.Id), "altered");
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.TryMarkSubmittedAsync(_mapping, change.Id));
        Assert.Equal(CloudDriveChangePhase.Prepared, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task ExistingFileRequiresMatchingPersistedBaseVersion()
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        var source = await SourceAsync();
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, source, "\"v1\""));
        await Store.BindVersionAsync(_mapping, new(Remote, "\"v1\"", 50));
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, source, null));
        var change = await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, source, "\"v1\"");
        Assert.Equal("\"v1\"", change.BaseVersion);
    }

    [Fact]
    public async Task ConfirmationRequiresMatchingContentProofAndAtomicallyAdvancesVersion()
    {
        var (change, _) = await PrepareAsync();
        var version = new CloudDriveContentVersion(Remote, "\"saved\"", change.ContentLength);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.ConfirmSavedAsync(_mapping, change.Id, version, change.ContentHash));
        await Store.TryMarkSubmittedAsync(_mapping, change.Id);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.ConfirmSavedAsync(_mapping, change.Id, version, new string('0', 64)));
        await Store.ConfirmSavedAsync(_mapping, change.Id, version, change.ContentHash);
        Assert.Equal(version, await Store.ReadVersionAsync(_mapping, Remote));
        Assert.Equal(CloudDriveChangePhase.Verified, Assert.Single(await Store.ReadChangesAsync(_mapping)).Phase);
        Assert.False(await Store.TryMarkSubmittedAsync(_mapping, change.Id));
        Assert.True(File.Exists(ContentPath(change.Id)));
    }

    [Fact]
    public async Task UnknownSchemaOrCorruptionIsNotResetOrOverwritten()
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        var document = JsonNode.Parse(await File.ReadAllTextAsync(StatePath))!;
        document["Version"] = 99;
        await File.WriteAllTextAsync(StatePath, document.ToJsonString());
        var before = await File.ReadAllTextAsync(StatePath);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.SetWritebackEnabledAsync(_mapping, false, true));
        Assert.Equal(before, await File.ReadAllTextAsync(StatePath));
        await File.WriteAllTextAsync(StatePath, "broken");
        await Assert.ThrowsAsync<System.Text.Json.JsonException>(() => Store.ReadChangesAsync(_mapping));
        Assert.Equal("broken", await File.ReadAllTextAsync(StatePath));
    }

    [Fact]
    public async Task MissingSubmissionPhaseCannotTurnIntoPreparedAfterRestart()
    {
        var (change, _) = await PrepareAsync();
        await Store.TryMarkSubmittedAsync(_mapping, change.Id);
        var document = JsonNode.Parse(await File.ReadAllTextAsync(StatePath))!;
        document["Changes"]![0]!.AsObject().Remove("Phase");
        await File.WriteAllTextAsync(StatePath, document.ToJsonString());
        await Assert.ThrowsAsync<System.Text.Json.JsonException>(() => Store.TryMarkSubmittedAsync(_mapping, change.Id));
        Assert.True(File.Exists(ContentPath(change.Id)));
    }

    [Fact]
    public async Task MissingJournalWithRetainedEditsCannotBeInitializedAsEmpty()
    {
        var (change, _) = await PrepareAsync();
        File.Delete(StatePath);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.SetWritebackEnabledAsync(_mapping, true, true));
        Assert.True(File.Exists(ContentPath(change.Id)));
        Assert.False(File.Exists(StatePath));
    }

    [Fact]
    public async Task OtherProcessLeasePreventsJournalAccessWithoutStealingLock()
    {
        await Store.IsWritebackEnabledAsync(_mapping);
        using (new FileStream(Path.Combine(Path.GetDirectoryName(StatePath)!, "write.lock"), FileMode.Open,
            FileAccess.ReadWrite, FileShare.None))
            await Assert.ThrowsAsync<IOException>(() => Store.IsWritebackEnabledAsync(_mapping));
        Assert.False(await Store.IsWritebackEnabledAsync(_mapping));
    }

    [Fact]
    public async Task CancelledCaptureLeavesNoRecordedChangeOrSnapshot()
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        var source = await SourceAsync();
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Store.PrepareSaveAsync(_mapping,
            Guid.NewGuid(), Remote, source, null, cancellation.Token));
        Assert.Empty(await Store.ReadChangesAsync(_mapping));
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(StatePath)!, "*.content"));
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(StatePath)!, "*.tmp"));
    }

    private async Task<(CloudDrivePendingChange Change, string Source)> PrepareAsync()
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        var source = await SourceAsync();
        return (await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, source, null), source);
    }

    [Fact]
    public async Task VerifiedCopyIsReleasedOnlyAfterMatchingLocalAcknowledgement()
    {
        var (change, _) = await PrepareAsync();
        Assert.True(await Store.TryMarkSubmittedAsync(_mapping, change.Id));
        await Store.ConfirmSavedAsync(_mapping, change.Id, new(Remote, "\"saved\"", change.ContentLength), change.ContentHash);
        var saved = Assert.Single(await Store.ReadChangesAsync(_mapping));
        Assert.False(await Store.TryAcknowledgeSavedAsync(_mapping, saved, () => false));
        Assert.True(File.Exists(ContentPath(change.Id)));
        Assert.True(await Store.TryAcknowledgeSavedAsync(_mapping, saved, () => true));
        var released = Assert.Single(await Store.ReadChangesAsync(_mapping));
        Assert.True(released.ContentReleased); Assert.Equal(CloudDriveChangePhase.Verified, released.Phase);
        Assert.False(File.Exists(ContentPath(change.Id)));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.OpenContentAsync(_mapping, change.Id));
        Assert.True(await Store.TryAcknowledgeSavedAsync(_mapping, released, () => true));
    }

    [Fact]
    public async Task InterruptedReleaseKeepsDurableReceiptAndRetriesOnlyReleasedContent()
    {
        var (change, _) = await PrepareAsync();
        await Store.TryMarkSubmittedAsync(_mapping, change.Id);
        await Store.ConfirmSavedAsync(_mapping, change.Id, new(Remote, "\"saved\"", change.ContentLength), change.ContentHash);
        var saved = Assert.Single(await Store.ReadChangesAsync(_mapping));
        using (var reading = new FileStream(ContentPath(change.Id), FileMode.Open, FileAccess.Read, FileShare.Read))
            await Assert.ThrowsAsync<IOException>(() => Store.TryAcknowledgeSavedAsync(_mapping, saved, () => true));
        Assert.True(Assert.Single(await Store.ReadChangesAsync(_mapping)).ContentReleased);
        Assert.True(File.Exists(ContentPath(change.Id)));
        await Store.CleanReleasedContentAsync(_mapping);
        Assert.False(File.Exists(ContentPath(change.Id)));
    }

    [Fact]
    public async Task NewestAcknowledgedSaveAlsoReleasesOlderVerifiedCopiesButNotOtherPendingContent()
    {
        var (first, source) = await PrepareAsync(); await Store.TryMarkSubmittedAsync(_mapping, first.Id);
        await Store.ConfirmSavedAsync(_mapping, first.Id, new(Remote, "\"first\"", first.ContentLength), first.ContentHash);
        await File.WriteAllTextAsync(source, "second-edit");
        var second = await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), Remote, source, "\"first\"");
        var other = await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), "/share/work/other.txt", source, null);
        await Store.TryMarkSubmittedAsync(_mapping, second.Id);
        await Store.ConfirmSavedAsync(_mapping, second.Id, new(Remote, "\"second\"", second.ContentLength), second.ContentHash);
        var verified = (await Store.ReadChangesAsync(_mapping)).Single(item => item.Id == second.Id);
        Assert.True(await Store.TryAcknowledgeSavedAsync(_mapping, verified, () => true));
        Assert.False(File.Exists(ContentPath(first.Id))); Assert.False(File.Exists(ContentPath(second.Id)));
        Assert.True(File.Exists(ContentPath(other.Id)));
        Assert.All((await Store.ReadChangesAsync(_mapping)).Where(item => item.RemotePath == Remote), item => Assert.True(item.ContentReleased));
    }

    [Theory]
    [InlineData((int)CloudDriveChangePhase.Prepared)]
    [InlineData((int)CloudDriveChangePhase.Submitted)]
    [InlineData((int)CloudDriveChangePhase.KeptLocally)]
    public async Task CleanupNeverDeletesUnverifiedOrUserKeptContent(int phaseValue)
    {
        var (change, _) = await PrepareAsync(); var phase = (CloudDriveChangePhase)phaseValue;
        if (phase == CloudDriveChangePhase.Submitted) await Store.TryMarkSubmittedAsync(_mapping, change.Id);
        if (phase == CloudDriveChangePhase.KeptLocally) await Store.KeepLocallyAsync(_mapping, change.Id, true);
        await Store.CleanReleasedContentAsync(_mapping);
        var record = Assert.Single(await Store.ReadChangesAsync(_mapping));
        Assert.False(record.ContentReleased); Assert.Equal(phase, record.Phase);
        Assert.True(File.Exists(ContentPath(change.Id)));
        await using var content = await Store.OpenContentAsync(_mapping, change.Id); using var reader = new StreamReader(content);
        Assert.Equal("original-edit", await reader.ReadToEndAsync());
    }

    [Fact]
    public async Task RetryJournalFailureRemovesOnlyItsUnpublishedCopy()
    {
        var (change, _) = await PrepareAsync(); await Store.MarkConflictAsync(_mapping, change.Id);
        var conflict = Assert.Single(await Store.ReadChangesAsync(_mapping));
        using (var locked = new FileStream(StatePath, FileMode.Open, FileAccess.Read, FileShare.Read))
            await Assert.ThrowsAsync<UnauthorizedAccessException>(() => Store.PrepareRetryAsync(_mapping, conflict, null, null, true));
        Assert.Equal(conflict, Assert.Single(await Store.ReadChangesAsync(_mapping)));
        Assert.Single(Directory.GetFiles(Path.GetDirectoryName(StatePath)!, "*.content"));
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(StatePath)!, "*.tmp"));
        var retry = await Store.PrepareRetryAsync(_mapping, conflict, null, null, true);
        Assert.NotEqual(conflict.Id, retry.Id); Assert.False(retry.ContentReleased);
        Assert.Equal(2, Directory.GetFiles(Path.GetDirectoryName(StatePath)!, "*.content").Length);
    }

    [Fact]
    public async Task ReleaseFlagCannotBeOmittedOrAppliedToPendingContent()
    {
        var (change, _) = await PrepareAsync(); await Store.TryMarkSubmittedAsync(_mapping, change.Id);
        await Store.ConfirmSavedAsync(_mapping, change.Id, new(Remote, "\"saved\"", change.ContentLength), change.ContentHash);
        await Store.TryAcknowledgeSavedAsync(_mapping, Assert.Single(await Store.ReadChangesAsync(_mapping)), () => true);
        var document = JsonNode.Parse(await File.ReadAllTextAsync(StatePath))!.AsObject();
        Assert.Equal(9, document["Version"]!.GetValue<int>());
        var row = document["Changes"]![0]!.AsObject(); row.Remove("ContentReleased");
        await File.WriteAllTextAsync(StatePath, document.ToJsonString());
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.CleanReleasedContentAsync(_mapping));
        row["ContentReleased"] = true; row["Phase"] = (int)CloudDriveChangePhase.Prepared;
        row["SavedVersion"] = null; row["SavedEmptyModifiedAt"] = null;
        await File.WriteAllTextAsync(StatePath, document.ToJsonString());
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.CleanReleasedContentAsync(_mapping));
    }
    private async Task<string> SourceAsync()
    {
        Directory.CreateDirectory(_root);
        var source = Path.Combine(_root, "synthetic-edit.txt");
        await File.WriteAllTextAsync(source, "original-edit");
        return source;
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
