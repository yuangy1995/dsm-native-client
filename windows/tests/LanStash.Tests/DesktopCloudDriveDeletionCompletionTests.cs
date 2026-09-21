using LanStash.App.CloudDrive;
using LanStash.Domain;
using System.Runtime.InteropServices;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveDeletionCompletionTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-delete-complete-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic", DesktopDriveScope.Folder("/share"),
        DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private string CatalogPath => Path.Combine(_root, "catalog.json");
    private string StatePath => Path.Combine(_root, "sync", _mapping.Id.ToString("N"), "state.json");
    private DesktopCloudDriveStore Catalog => new(CatalogPath);
    private DesktopCloudDriveSyncStore Sync => new(Path.Combine(_root, "sync"));

    [Fact]
    public async Task SameNameRecreationNeverReusesDeletedIdentity()
    {
        var operation = await ReadyAsync();
        await new CloudDriveDeletionCompletion(_mapping, Sync, Catalog, (_, _) => Task.CompletedTask).CompleteAsync(operation);
        var recreated = await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/folder", "/share/folder/file"]);
        Assert.NotEqual(operation.ItemIdentity, recreated.Single(item => item.Value == "/share/folder").Key);
        var again = await Catalog.RegisterItemPathsAsync(_mapping.Id, recreated.Values);
        Assert.Equal(recreated.OrderBy(item => item.Key), again.OrderBy(item => item.Key));
        var callbacks = 0;
        await new CloudDriveDeletionCompletion(_mapping, Sync, Catalog, (_, _) => { callbacks++; return Task.CompletedTask; }).CompleteAsync(operation);
        Assert.Equal(0, callbacks); Assert.Equal(2, (await Catalog.LoadItemPathsAsync(_mapping.Id)).Count);
    }

    [Fact]
    public async Task LocalFailureKeepsIndexBaselineAndDeletionPending()
    {
        var operation = await ReadyAsync();
        await Assert.ThrowsAsync<IOException>(() => new CloudDriveDeletionCompletion(_mapping, Sync, Catalog,
            (_, _) => throw new IOException("合成本地占用")).CompleteAsync(operation));
        Assert.Equal(2, (await Catalog.LoadItemPathsAsync(_mapping.Id)).Count);
        Assert.NotNull(await Sync.ReadVersionAsync(_mapping, "/share/folder/file"));
        Assert.Equal(CloudDriveDeletionPhase.ServerVerified, Assert.Single(await Sync.ReadDeletionOperationsAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task InterruptedCatalogWriteCanRetryWithoutSendingAnotherDeletion()
    {
        var operation = await ReadyAsync(); var removed = new HashSet<string>();
        Task Remove(IReadOnlyDictionary<string, string> tree, CancellationToken _) { removed.UnionWith(tree.Values); return Task.CompletedTask; }
        using (var locked = new FileStream(CatalogPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            await Assert.ThrowsAsync<UnauthorizedAccessException>(() => new CloudDriveDeletionCompletion(_mapping, Sync, Catalog, Remove).CompleteAsync(operation));
        Assert.Equal(2, removed.Count); Assert.Equal(2, (await Catalog.LoadItemPathsAsync(_mapping.Id)).Count);
        await new CloudDriveDeletionCompletion(_mapping, Sync, Catalog, Remove).CompleteAsync(operation);
        Assert.Empty(await Catalog.LoadItemPathsAsync(_mapping.Id));
        Assert.Equal(CloudDriveDeletionPhase.Completed, Assert.Single(await Sync.ReadDeletionOperationsAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task InterruptedFinalJournalWriteDoesNotCleanNewSameNameItem()
    {
        var operation = await ReadyAsync();
        using (var locked = new FileStream(StatePath, FileMode.Open, FileAccess.Read, FileShare.Read))
            await Assert.ThrowsAsync<UnauthorizedAccessException>(() => new CloudDriveDeletionCompletion(_mapping, Sync, Catalog, (_, _) => Task.CompletedTask).CompleteAsync(operation));
        Assert.Empty(await Catalog.LoadItemPathsAsync(_mapping.Id));
        // 模拟在恢复前已登记的同名新对象；旧身份不能再次选中它。
        var replacement = await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/folder"]);
        var callbacks = 0;
        await new CloudDriveDeletionCompletion(_mapping, Sync, Catalog, (_, _) => { callbacks++; return Task.CompletedTask; }).CompleteAsync(operation);
        Assert.Equal(0, callbacks); Assert.Equal(replacement.Single(), (await Catalog.LoadItemPathsAsync(_mapping.Id)).Single());
        Assert.Null(await Sync.ReadVersionAsync(_mapping, "/share/folder/file"));
    }

    [Fact]
    public async Task PendingDeletionCannotCreateProjectionUnderReservedName()
    {
        await ReadyAsync();
        await Assert.ThrowsAsync<InvalidOperationException>(() => Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/folder/file"]));
        Assert.Equal("file", (await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), []))["/share/folder/file"]);
    }

    [Fact]
    public async Task ReconnectCanReadExistingNamesWithoutRegisteringReservedDeletionPaths()
    {
        await ReadyAsync(); var paths = await Catalog.LoadItemPathsAsync(_mapping.Id);
        var before = await File.ReadAllTextAsync(StatePath);
        var names = await Sync.RegisterLocalNamesAsync(_mapping, DesktopDriveWindowsNameCodec.BuildSafeSegments(paths.Values), []);
        Assert.Equal("folder", names["/share/folder"]); Assert.Equal("file", names["/share/folder/file"]);
        Assert.Equal(before, await File.ReadAllTextAsync(StatePath));
    }

    [Fact]
    public async Task CompletingDeletionClearsOnlyItsCacheAndOfflinePreferences()
    {
        var operation = await ReadyAsync();
        var entry = new DesktopDriveCacheEntry("/share/folder/file", DesktopDriveCacheEntryKind.KeptOffline, 3, 3, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch);
        await Catalog.SaveRuntimeAsync(_mapping.Id, DesktopDriveMappingRuntime.Default with
        {
            PinnedPaths = ["/share/folder", "/share/other"],
            CacheEntries = new Dictionary<string, DesktopDriveCacheEntry> { [entry.RemotePath] = entry, ["/share/other"] = entry with { RemotePath = "/share/other" } },
        });
        await new CloudDriveDeletionCompletion(_mapping, Sync, Catalog, (_, _) => Task.CompletedTask).CompleteAsync(operation);
        var runtime = await Catalog.LoadRuntimeAsync(_mapping.Id);
        Assert.Equal(["/share/other"], runtime.PinnedPaths); Assert.Equal("/share/other", Assert.Single(runtime.CacheEntries).Key);
    }

    [Fact]
    public async Task UnverifiedDeletionCannotInvokeLocalCleanup()
    {
        var operation = await ReadyAsync(); var called = false;
        await Assert.ThrowsAsync<InvalidOperationException>(() => new CloudDriveDeletionCompletion(_mapping, Sync, Catalog,
            (_, _) => { called = true; return Task.CompletedTask; }).CompleteAsync(operation with { Phase = CloudDriveDeletionPhase.Submitted }));
        Assert.False(called);
    }

    [Theory]
    [InlineData(0, false, false)]
    [InlineData(1, true, false)]
    [InlineData(2, false, true)]
    [InlineData(3, true, true)]
    public void DeleteCallbackDistinguishesDirectoryAndUndelete(int flags, bool directory, bool undelete)
    {
        var pointer = Marshal.AllocHGlobal(16);
        try
        {
            Marshal.WriteInt32(pointer, 16); Marshal.WriteInt32(pointer, 8, flags);
            Assert.Equal((directory, undelete), CloudFilePlaceholderNative.ReadDeleteRequest(pointer));
            Marshal.WriteInt32(pointer, 8, 4);
            Assert.Throws<InvalidDataException>(() => CloudFilePlaceholderNative.ReadDeleteRequest(pointer));
            Marshal.WriteInt32(pointer, 8);
            Assert.Throws<InvalidDataException>(() => CloudFilePlaceholderNative.ReadDeleteRequest(pointer));
        }
        finally { Marshal.FreeHGlobal(pointer); }
    }

    private async Task<CloudDriveDeletionOperation> ReadyAsync()
    {
        await Catalog.SaveAsync([_mapping]);
        var paths = await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/folder", "/share/folder/file"]);
        await Sync.SetWritebackEnabledAsync(_mapping, true, true); await Sync.SetDeletionEnabledAsync(_mapping, true, true);
        await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), paths.Values);
        await Sync.BindVersionAsync(_mapping, new("/share/folder/file", "\"baseline\"", 3));
        var operation = new CloudDriveDeletionOperation(Guid.NewGuid(), paths.Single(item => item.Value == "/share/folder").Key,
            "/share/folder", true, 0, DateTimeOffset.UnixEpoch, null, CloudDriveDeletionPhase.Prepared, DateTimeOffset.UtcNow);
        await Sync.AddDeletionOperationAsync(_mapping, operation);
        var submitted = operation with { Phase = CloudDriveDeletionPhase.Submitted }; await Sync.UpdateDeletionOperationAsync(_mapping, operation, submitted);
        var verified = submitted with { Phase = CloudDriveDeletionPhase.ServerVerified }; await Sync.UpdateDeletionOperationAsync(_mapping, submitted, verified);
        return verified;
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
