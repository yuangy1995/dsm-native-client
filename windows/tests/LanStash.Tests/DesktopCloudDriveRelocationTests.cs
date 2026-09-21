using System.Text.Json.Nodes;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveRelocationTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-relocation-tests-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic", DesktopDriveScope.Folder("/share"),
        DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private DesktopCloudDriveStore Catalog => new(Path.Combine(_root, "mappings.json"));
    private DesktopCloudDriveSyncStore Sync => new(Path.Combine(_root, "sync"));

    [Fact]
    public async Task MovedTreeRetainsIdentitiesAndReusedSourceGetsNewIdentity()
    {
        await Catalog.SaveAsync([_mapping]);
        var original = await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/old", "/share/old/file"]);
        var rootId = original.Single(item => item.Value == "/share/old").Key;
        var fileId = original.Single(item => item.Value == "/share/old/file").Key;
        var moved = await Catalog.RelocateItemPathsAsync(_mapping.Id, "/share/old", "/share/new");
        Assert.Equal("/share/new", moved[rootId]); Assert.Equal("/share/new/file", moved[fileId]);
        var registered = await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/old", "/share/old/file", "/share/new/file"]);
        Assert.Equal(4, registered.Count);
        Assert.Equal("/share/new/file", registered[fileId]);
        Assert.NotEqual(rootId, registered.Single(item => item.Value == "/share/old").Key);
        Assert.NotEqual(fileId, registered.Single(item => item.Value == "/share/old/file").Key);
        Assert.Equal(registered.OrderBy(item => item.Key), (await Catalog.LoadItemPathsAsync(_mapping.Id)).OrderBy(item => item.Key));
    }

    [Fact]
    public async Task OfflinePreferencesAndCacheEntriesFollowTheTree()
    {
        await Catalog.SaveAsync([_mapping]);
        await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/old", "/share/old/file"]);
        var entry = new DesktopDriveCacheEntry("/share/old/file", DesktopDriveCacheEntryKind.KeptOffline, 123, 120,
            DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch);
        await Catalog.SaveRuntimeAsync(_mapping.Id, DesktopDriveMappingRuntime.Default with
        {
            PinnedPaths = ["/share/old"], CacheEntries = new Dictionary<string, DesktopDriveCacheEntry> { [entry.RemotePath] = entry },
        });
        await Catalog.RelocateItemPathsAsync(_mapping.Id, "/share/old", "/share/new");
        var state = await Catalog.LoadRuntimeAsync(_mapping.Id);
        Assert.Equal(["/share/new"], state.PinnedPaths);
        Assert.Equal(entry with { RemotePath = "/share/new/file" }, Assert.Single(state.CacheEntries).Value);
    }

    [Theory]
    [InlineData("/share", "/share/new")]
    [InlineData("/share/old", "/other/new")]
    [InlineData("/share/old", "/share/old/inside")]
    [InlineData("/share/missing", "/share/new")]
    [InlineData("/share/old", "/share/taken")]
    public async Task InvalidCatalogRelocationLeavesOriginalIndex(string source, string destination)
    {
        await Catalog.SaveAsync([_mapping]);
        var original = await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/old", "/share/taken"]);
        await Assert.ThrowsAsync<InvalidDataException>(() => Catalog.RelocateItemPathsAsync(_mapping.Id, source, destination));
        Assert.Equal(original.OrderBy(item => item.Key), (await Catalog.LoadItemPathsAsync(_mapping.Id)).OrderBy(item => item.Key));
    }

    [Fact]
    public async Task PendingContentAndVersionsMoveAtomicallyWithoutCopyingOrReplacingContent()
    {
        var change = await PrepareAsync();
        var operation = new CloudDrivePathRelocation(Guid.NewGuid(), "/share/old", "/share/new", "new");
        await Sync.RelocatePathsAsync(_mapping, operation);
        var moved = Assert.Single(await Sync.ReadChangesAsync(_mapping));
        Assert.Equal(change with { RemotePath = "/share/new/file" }, moved);
        Assert.Null(await Sync.ReadVersionAsync(_mapping, "/share/old/file"));
        Assert.Equal(new CloudDriveContentVersion("/share/new/file", "\"base\"", 3), await Sync.ReadVersionAsync(_mapping, "/share/new/file"));
        await using var content = await Sync.OpenContentAsync(_mapping, change.Id);
        using var reader = new StreamReader(content); Assert.Equal("pending edit", await reader.ReadToEndAsync());
        var names = await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), []);
        Assert.Equal("new", names["/share/new"]); Assert.Equal("file", names["/share/new/file"]);
    }

    [Fact]
    public async Task RepeatingReceiptAfterSourcePathReuseDoesNotMoveTheNewFile()
    {
        await PrepareAsync();
        var operation = new CloudDrivePathRelocation(Guid.NewGuid(), "/share/old", "/share/new", "new");
        await Sync.RelocatePathsAsync(_mapping, operation);
        await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/old"]);
        await Sync.RelocatePathsAsync(_mapping, operation);
        var names = await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), []);
        Assert.True(names.ContainsKey("/share/old")); Assert.True(names.ContainsKey("/share/new"));
        await Assert.ThrowsAsync<InvalidDataException>(() => Sync.RelocatePathsAsync(_mapping, operation with { Destination = "/share/elsewhere" }));
    }

    [Fact]
    public async Task UnknownSubmissionMustBeResolvedBeforeItsPathsCanChange()
    {
        var change = await PrepareAsync(); await Sync.TryMarkSubmittedAsync(_mapping, change.Id);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Sync.RelocatePathsAsync(_mapping,
            new(Guid.NewGuid(), "/share/old", "/share/new", "new")));
        Assert.Equal("/share/old/file", Assert.Single(await Sync.ReadChangesAsync(_mapping)).RemotePath);
    }

    [Theory]
    [InlineData("version")]
    [InlineData("empty")]
    [InlineData("pending")]
    [InlineData("kept")]
    public async Task VacantCatalogCannotDiscardActiveDestinationState(string kind)
    {
        await PrepareAsync();
        await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/new"]);
        if (kind == "version") await Sync.BindVersionAsync(_mapping, new("/share/new", "\"existing\"", 3));
        else if (kind == "empty") await Sync.BindEmptyFileBaselineAsync(_mapping, "/share/new", DateTimeOffset.UnixEpoch);
        else
        {
            var file = Path.Combine(_root, "destination-edit"); await File.WriteAllTextAsync(file, "do not discard");
            var change = await Sync.PrepareSaveAsync(_mapping, Guid.NewGuid(), "/share/new", file, null);
            if (kind == "kept") await Sync.KeepLocallyAsync(_mapping, change.Id, true);
        }
        await Assert.ThrowsAsync<InvalidDataException>(() => Sync.RelocatePathsAsync(_mapping,
            new(Guid.NewGuid(), "/share/old", "/share/new", "new"), activePaths: ["/share/old", "/share/old/file"]));
        Assert.Contains("/share/old", (await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), [])).Keys);
        if (kind is "pending" or "kept")
        {
            var change = (await Sync.ReadChangesAsync(_mapping)).Single(item => item.RemotePath == "/share/new");
            await using var content = await Sync.OpenContentAsync(_mapping, change.Id);
            using var reader = new StreamReader(content); Assert.Equal("do not discard", await reader.ReadToEndAsync());
        }
    }

    [Fact]
    public async Task MissingRelocationReceiptsCannotBeReadAsAnOlderSchema()
    {
        await PrepareAsync(); await Sync.RelocatePathsAsync(_mapping, new(Guid.NewGuid(), "/share/old", "/share/new", "new"));
        var path = Path.Combine(_root, "sync", _mapping.Id.ToString("N"), "state.json");
        var state = JsonNode.Parse(await File.ReadAllTextAsync(path))!.AsObject();
        Assert.Equal(6, state["Version"]!.GetValue<int>());
        state.Remove("Relocations"); await File.WriteAllTextAsync(path, state.ToJsonString());
        var invalid = await File.ReadAllTextAsync(path);
        await Assert.ThrowsAsync<InvalidDataException>(() => Sync.ReadChangesAsync(_mapping));
        Assert.Equal(invalid, await File.ReadAllTextAsync(path));
    }

    [Fact]
    public async Task ReusingRemovedDestinationPreservesVerifiedBackupAndRecoveryReceipt()
    {
        await PrepareAsync();
        await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/new"]);
        var file = Path.Combine(_root, "historical-content"); await File.WriteAllTextAsync(file, "saved history");
        var historical = await Sync.PrepareSaveAsync(_mapping, Guid.NewGuid(), "/share/new", file, null);
        Assert.True(await Sync.TryMarkSubmittedAsync(_mapping, historical.Id));
        await Sync.ConfirmSavedAsync(_mapping, historical.Id, new("/share/new", "\"saved\"", historical.ContentLength), historical.ContentHash);
        Assert.True(await Sync.TryRemoveLocalProjectionAsync(_mapping, "/share/new", _ => Task.FromResult(true)));
        var receipt = new CloudDrivePathRelocation(Guid.NewGuid(), "/share/old", "/share/new", "new");
        await Sync.RelocatePathsAsync(_mapping, receipt, activePaths: ["/share/old", "/share/old/file"]);
        // 索引已经迁移后的恢复仍认同一回执，不把本次目标当作其他项目占用。
        await Sync.RelocatePathsAsync(_mapping, receipt, activePaths: ["/share/new", "/share/new/file"]);
        var records = await Sync.ReadChangesAsync(_mapping);
        Assert.Equal(CloudDriveChangePhase.Verified, records.Single(item => item.Id == historical.Id).Phase);
        Assert.Contains(records, item => item.RemotePath == "/share/new/file" && item.Phase == CloudDriveChangePhase.Prepared);
        await using var content = await Sync.OpenContentAsync(_mapping, historical.Id);
        using var reader = new StreamReader(content); Assert.Equal("saved history", await reader.ReadToEndAsync());
    }

    private async Task<CloudDrivePendingChange> PrepareAsync()
    {
        await Sync.SetWritebackEnabledAsync(_mapping, true, true);
        await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/old", "/share/old/file"]);
        await Sync.BindVersionAsync(_mapping, new("/share/old/file", "\"base\"", 3));
        var file = Path.Combine(_root, "edit"); await File.WriteAllTextAsync(file, "pending edit");
        return await Sync.PrepareSaveAsync(_mapping, Guid.NewGuid(), "/share/old/file", file, "\"base\"");
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
