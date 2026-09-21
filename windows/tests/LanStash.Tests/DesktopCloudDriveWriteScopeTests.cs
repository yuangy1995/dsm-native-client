using System.Text.Json.Nodes;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveWriteScopeTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-write-scope-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic", DesktopDriveScope.AllShares,
        DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private DesktopCloudDriveSyncStore Store => new(Path.Combine(_root, "sync"));

    [Theory]
    [InlineData(null, false)]
    [InlineData("/", false)]
    [InlineData("/share", false)]
    [InlineData("/share/file", true)]
    [InlineData("/another/folder/file", true)]
    [InlineData("/share/#recycle/file", false)]
    [InlineData("/share/../outside", false)]
    [InlineData("/share//file", false)]
    public void AllSharesWriteBoundaryMatchesProtectedShareRoots(string? path, bool allowed) =>
        Assert.Equal(allowed, CloudDriveWriteScope.CanWrite(_mapping, path));

    [Fact]
    public async Task ExistingFileCaptureUsesWholeShareNameAndKeepsRecordedBaseline()
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share", "/share/existing.txt"]);
        await Store.BindEmptyFileBaselineAsync(_mapping, "/share/existing.txt", DateTimeOffset.UnixEpoch);
        var localRoot = Path.Combine(_root, "drive"); var share = Path.Combine(localRoot, "share"); Directory.CreateDirectory(share);
        var file = Path.Combine(share, "existing.txt"); await File.WriteAllTextAsync(file, "edited");
        var change = await Store.CaptureMappedSaveAsync(_mapping, Guid.NewGuid(), "/share/existing.txt", file, localRoot);
        Assert.Equal(DateTimeOffset.UnixEpoch, change.EmptyBaseModifiedAt);
        Assert.Equal("/share/existing.txt", change.RemotePath);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), "/share", file, null));
        Assert.Single(await Store.ReadChangesAsync(_mapping));
    }

    [Fact]
    public async Task CrossShareIndexAndPendingContentMoveWithoutChangingIdentity()
    {
        var catalog = new DesktopCloudDriveStore(Path.Combine(_root, "catalog.json")); await catalog.SaveAsync([_mapping]);
        var paths = await catalog.RegisterItemPathsAsync(_mapping.Id, ["/one", "/two", "/one/file"]);
        var identity = paths.Single(item => item.Value == "/one/file").Key;
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), paths.Values);
        var content = Path.Combine(_root, "edit"); await File.WriteAllTextAsync(content, "pending");
        var change = await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), "/one/file", content, null);
        await Store.RelocatePathsAsync(_mapping, new(Guid.NewGuid(), "/one/file", "/two/file", "file"));
        await catalog.RelocateItemPathsAsync(_mapping.Id, "/one/file", "/two/file");
        Assert.Equal("/two/file", (await catalog.LoadItemPathsAsync(_mapping.Id))[identity]);
        Assert.Equal(change with { RemotePath = "/two/file" }, Assert.Single(await Store.ReadChangesAsync(_mapping)));
        await using var frozen = await Store.OpenContentAsync(_mapping, change.Id); using var reader = new StreamReader(frozen);
        Assert.Equal("pending", await reader.ReadToEndAsync());
        await Assert.ThrowsAsync<InvalidDataException>(() => catalog.RelocateItemPathsAsync(_mapping.Id, "/one", "/two/renamed"));
    }

    [Fact]
    public async Task WholeNasWriteEnablementCannotBeSmuggledIntoLegacySchema()
    {
        Assert.False(await Store.IsWritebackEnabledAsync(_mapping));
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        var path = Path.Combine(_root, "sync", _mapping.Id.ToString("N"), "state.json");
        var document = JsonNode.Parse(await File.ReadAllTextAsync(path))!;
        Assert.Equal(10, document["Version"]!.GetValue<int>());
        document["Version"] = 9; await File.WriteAllTextAsync(path, document.ToJsonString());
        var invalid = await File.ReadAllTextAsync(path);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.IsWritebackEnabledAsync(_mapping));
        Assert.Equal(invalid, await File.ReadAllTextAsync(path));
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
