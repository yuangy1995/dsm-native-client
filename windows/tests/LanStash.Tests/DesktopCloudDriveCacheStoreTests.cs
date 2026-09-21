using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveCacheStoreTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-cache-merge-" + Guid.NewGuid().ToString("N"));
    private DesktopCloudDriveStore Store => new(Path.Combine(_root, "mappings.json"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic", DesktopDriveScope.Folder("/share"),
        DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private static DesktopDriveCacheEntry Entry(string path) => new(path, DesktopDriveCacheEntryKind.Temporary, 10, 10, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch);

    [Fact]
    public async Task ClearingCacheDoesNotEraseNewSaveStatisticsOrUnrelatedState()
    {
        await Store.SaveAsync([_mapping]);
        var baseline = DesktopDriveMappingRuntime.Default with { CacheEntries = new Dictionary<string, DesktopDriveCacheEntry>
            { ["/share/a"] = Entry("/share/a"), ["/share/b"] = Entry("/share/b") } };
        var changed = Entry("/share/a") with { LogicalSizeBytes = 20, AllocatedSizeBytes = 20, UpdatedAt = DateTimeOffset.UnixEpoch.AddSeconds(1) };
        await Store.SaveRuntimeAsync(_mapping.Id, baseline with { State = DesktopDriveMappingState.Degraded,
            CacheEntries = new Dictionary<string, DesktopDriveCacheEntry> { ["/share/a"] = changed, ["/share/b"] = Entry("/share/b"), ["/share/new"] = Entry("/share/new") } });
        await Store.ApplyCacheReleaseAsync(_mapping.Id, baseline, ["/share/a", "/share/b"]);
        var result = await Store.LoadRuntimeAsync(_mapping.Id);
        Assert.Equal(changed, result.CacheEntries["/share/a"]); Assert.DoesNotContain("/share/b", result.CacheEntries.Keys);
        Assert.Contains("/share/new", result.CacheEntries.Keys); Assert.Equal(DesktopDriveMappingState.Degraded, result.State);
    }

    [Fact]
    public async Task ReleasingOfflineFolderPreservesNewlyAddedChildPreference()
    {
        await Store.SaveAsync([_mapping]);
        var baseline = DesktopDriveMappingRuntime.Default with { PinnedPaths = ["/share/folder"] };
        await Store.SaveRuntimeAsync(_mapping.Id, baseline with { PinnedPaths = ["/share/folder", "/share/folder/child"],
            CacheEntries = new Dictionary<string, DesktopDriveCacheEntry>
            {
                ["/share/folder/a"] = Entry("/share/folder/a") with { Kind = DesktopDriveCacheEntryKind.KeptOffline },
                ["/share/folder/child/b"] = Entry("/share/folder/child/b") with { Kind = DesktopDriveCacheEntryKind.KeptOffline },
            } });
        await Store.ApplyCacheReleaseAsync(_mapping.Id, baseline, [], ["/share/folder"]);
        var result = await Store.LoadRuntimeAsync(_mapping.Id);
        Assert.Equal(["/share/folder/child"], result.PinnedPaths);
        Assert.Equal(DesktopDriveCacheEntryKind.Temporary, result.CacheEntries["/share/folder/a"].Kind);
        Assert.Equal(DesktopDriveCacheEntryKind.KeptOffline, result.CacheEntries["/share/folder/child/b"].Kind);
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
