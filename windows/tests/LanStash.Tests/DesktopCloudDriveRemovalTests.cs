using System.Runtime.InteropServices;
using System.Text;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveRemovalTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-removal-tests-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic",
        DesktopDriveScope.Folder("/share"), DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private DesktopCloudDriveSyncStore Store => new(_root);

    [Fact]
    public void CallbackGrantRequiresProcessRootFileAndIdentityAndIsConsumedOnce()
    {
        var gate = new CloudFileLocalRemovalGate();
        var state = new CloudFilesInterop.PlaceholderStandardInfo { FileId = 7, SyncRootFileId = 9 };
        using var grant = gate.Authorize(state, "synthetic");
        var process = Marshal.AllocHGlobal(8); var identity = Marshal.AllocHGlobal(9);
        try
        {
            Marshal.WriteInt32(process, 8); Marshal.WriteInt32(process, 4, Environment.ProcessId);
            Marshal.Copy(Encoding.UTF8.GetBytes("synthetic"), 0, identity, 9);
            var info = new CloudFilesInterop.CallbackInfo { FileId = 7, SyncRootFileId = 9, ProcessInfo = process, FileIdentity = identity, FileIdentityLength = 9 };
            Assert.False(gate.TryConsume(info with { FileId = 8 }));
            Assert.False(gate.TryConsume(info with { SyncRootFileId = 10 }));
            Assert.False(gate.TryConsume(info with { ProcessInfo = IntPtr.Zero }));
            Assert.False(gate.TryConsume(info with { FileIdentityLength = 8 }));
            Marshal.WriteInt32(process, 4, -1); Assert.False(gate.TryConsume(info));
            Marshal.WriteInt32(process, 4, Environment.ProcessId);
            Marshal.WriteByte(identity, 0, (byte)'x'); Assert.False(gate.TryConsume(info));
            Marshal.WriteByte(identity, 0, (byte)'s');
            Assert.True(gate.TryConsume(info)); Assert.False(gate.TryConsume(info));
        }
        finally { Marshal.FreeHGlobal(process); Marshal.FreeHGlobal(identity); }
    }

    [Fact]
    public void DuplicateGrantIsRejectedAndDisposalReleasesOnlyItsOwnGrant()
    {
        var gate = new CloudFileLocalRemovalGate();
        var state = new CloudFilesInterop.PlaceholderStandardInfo { FileId = 7, SyncRootFileId = 9 };
        using (gate.Authorize(state, "synthetic"))
            Assert.Throws<InvalidOperationException>(() => gate.Authorize(state, "synthetic"));
        using var next = gate.Authorize(state, "synthetic");
    }

    [Fact]
    public async Task SuccessfulRemovalClearsVersionsButKeepsStableNames()
    {
        const string path = "/share/folder/file.bin";
        await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/folder", path]);
        await Store.BindVersionAsync(_mapping, new(path, "\"v1\"", 8));
        Assert.True(await Store.TryRemoveLocalProjectionAsync(_mapping, "/share/folder", _ => Task.FromResult(true)));
        Assert.Null(await Store.ReadVersionAsync(_mapping, path));
        var names = await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), []);
        Assert.Equal("folder", names["/share/folder"]); Assert.Equal("file.bin", names[path]);
    }

    [Fact]
    public async Task NativeRetentionOrFailureDoesNotClearVersion()
    {
        var version = new CloudDriveContentVersion("/share/file.bin", "\"v1\"", 8);
        await Store.BindVersionAsync(_mapping, version);
        Assert.False(await Store.TryRemoveLocalProjectionAsync(_mapping, version.RemotePath, _ => Task.FromResult(false)));
        await Assert.ThrowsAsync<IOException>(() => Store.TryRemoveLocalProjectionAsync(_mapping, version.RemotePath,
            _ => Task.FromException<bool>(new IOException("合成本地删除失败"))));
        Assert.Equal(version, await Store.ReadVersionAsync(_mapping, version.RemotePath));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PendingChangePreventsItemOrAncestorRemoval(bool ancestor)
    {
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        var source = Path.Combine(_root, "edit"); await File.WriteAllTextAsync(source, "synthetic edit");
        var change = await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), "/share/folder/item.bin", source, null);
        var calls = 0;
        Assert.False(await Store.TryRemoveLocalProjectionAsync(_mapping, ancestor ? "/share/folder" : change.RemotePath,
            _ => { calls++; return Task.FromResult(true); }));
        Assert.Equal(0, calls); Assert.Single(await Store.ReadChangesAsync(_mapping));
        Assert.Equal("synthetic edit", await File.ReadAllTextAsync(Path.Combine(_root, _mapping.Id.ToString("N"), change.Id.ToString("N") + ".content")));
    }

    [Fact]
    public async Task MappingRootCannotBeRemovedThroughProjectionCleanup()
    {
        var calls = 0;
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.TryRemoveLocalProjectionAsync(_mapping, "/share",
            _ => { calls++; return Task.FromResult(true); }));
        Assert.Equal(0, calls);
    }

    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
