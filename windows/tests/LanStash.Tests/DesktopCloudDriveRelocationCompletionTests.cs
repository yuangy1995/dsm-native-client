using System.Runtime.InteropServices;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveRelocationCompletionTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-local-move-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic", DesktopDriveScope.Folder("/share"),
        DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private string CatalogPath => Path.Combine(_root, "mappings.json");
    private string StatePath => Path.Combine(_root, "sync", _mapping.Id.ToString("N"), "state.json");
    private DesktopCloudDriveStore Catalog => new(CatalogPath);
    private DesktopCloudDriveSyncStore Sync => new(Path.Combine(_root, "sync"));

    [Fact]
    public async Task LocalIdentityMustBeVerifiedBeforeEitherStoreMoves()
    {
        var operation = await PrepareAsync();
        var completion = new CloudDriveRelocationCompletion(_mapping, Sync, Catalog, _ => false);
        await Assert.ThrowsAsync<InvalidDataException>(() => completion.CompleteAsync(operation.Id));
        Assert.Equal("/share/old", (await Catalog.LoadItemPathsAsync(_mapping.Id))[operation.ItemIdentity]);
        Assert.Equal(CloudDriveRelocationPhase.ServerVerified, Assert.Single(await Sync.ReadRelocationOperationsAsync(_mapping)).Phase);
    }

    [Fact]
    public async Task CompletionMovesBothStoresAndIsIdempotentAfterOldPathReuse()
    {
        var operation = await PrepareAsync();
        var completion = new CloudDriveRelocationCompletion(_mapping, Sync, Catalog, _ => true);
        Assert.Equal(CloudDriveRelocationPhase.Completed, (await completion.CompleteAsync(operation.Id)).Phase);
        await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/old"]);
        await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/old"]);
        await completion.CompleteAsync(operation.Id);
        var paths = await Catalog.LoadItemPathsAsync(_mapping.Id);
        Assert.Equal("/share/new", paths[operation.ItemIdentity]); Assert.Contains("/share/old", paths.Values);
        Assert.Equal("new", (await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), []))["/share/new"]);
    }

    [Fact]
    public async Task FailureBetweenSyncAndCatalogCanResumeAfterRestart()
    {
        var operation = await PrepareAsync();
        using (var locked = new FileStream(CatalogPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            await Assert.ThrowsAsync<UnauthorizedAccessException>(() => new CloudDriveRelocationCompletion(_mapping, Sync, Catalog, _ => true).CompleteAsync(operation.Id));
        Assert.Equal("/share/old", (await Catalog.LoadItemPathsAsync(_mapping.Id))[operation.ItemIdentity]);
        Assert.Contains("/share/new", (await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), [])).Keys);
        Assert.Equal(CloudDriveRelocationPhase.Completed,
            (await new CloudDriveRelocationCompletion(_mapping, Sync, Catalog, _ => true).CompleteAsync(operation.Id)).Phase);
    }

    [Fact]
    public async Task FailureAfterCatalogDoesNotRepeatMigrationOfReusedSource()
    {
        var operation = await PrepareAsync();
        await Sync.RelocatePathsAsync(_mapping, new(operation.Id, operation.Source, operation.Destination, operation.LocalName));
        using (var locked = new FileStream(StatePath, FileMode.Open, FileAccess.Read, FileShare.Read))
            await Assert.ThrowsAsync<UnauthorizedAccessException>(() => new CloudDriveRelocationCompletion(_mapping, Sync, Catalog, _ => true).CompleteAsync(operation.Id));
        Assert.Equal("/share/new", (await Catalog.LoadItemPathsAsync(_mapping.Id))[operation.ItemIdentity]);
        await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/old"]);
        await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/old"]);
        await new CloudDriveRelocationCompletion(_mapping, Sync, Catalog, _ => true).CompleteAsync(operation.Id);
        Assert.Contains("/share/old", (await Catalog.LoadItemPathsAsync(_mapping.Id)).Values);
    }

    [Fact]
    public void RenameCallbackLayoutMatchesNativePointerAlignment()
    {
        Assert.Equal(24, Marshal.SizeOf<CloudFilesInterop.RenameCallbackParameters>());
        Assert.Equal(new IntPtr(16), Marshal.OffsetOf<CloudFilesInterop.RenameCallbackParameters>("Path"));
        Assert.Equal(12u, CloudFilesInterop.CallbackNotifyRenameCompletion);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void CaseOnlyRecoveryChangesActualLeafNameBeforeAcceptingCompletion(bool directory)
    {
        Directory.CreateDirectory(_root);
        var source = Path.Combine(_root, "Original"); var target = Path.Combine(_root, "original");
        if (directory) Directory.CreateDirectory(source); else File.WriteAllText(source, "synthetic");
        Assert.False(CloudFileRenamePaths.HasExactLeafName(target));
        Assert.Throws<InvalidDataException>(() => CloudFileRenamePaths.CompleteLocalMove(source, target, directory, false, _ => { }));
        var verified = new List<string>();
        CloudFileRenamePaths.CompleteLocalMove(source, target, directory, true, verified.Add);
        Assert.Equal(new[] { source, target }, verified);
        Assert.True(CloudFileRenamePaths.HasExactLeafName(target));
        Assert.False(CloudFileRenamePaths.HasExactLeafName(source));
        if (!directory) Assert.Equal("synthetic", File.ReadAllText(target));
        verified.Clear();
        CloudFileRenamePaths.CompleteLocalMove(source, target, directory, true, verified.Add);
        Assert.Equal(new[] { target }, verified);
    }

    [Fact]
    public void LocalRecoveryNeverMovesAnUnverifiedSource()
    {
        Directory.CreateDirectory(_root);
        var source = Path.Combine(_root, "source"); var target = Path.Combine(_root, "target");
        File.WriteAllText(source, "synthetic");
        Assert.Throws<InvalidDataException>(() => CloudFileRenamePaths.CompleteLocalMove(source, target, false, true,
            _ => throw new InvalidDataException("changed identity")));
        Assert.True(File.Exists(source)); Assert.False(File.Exists(target));
    }

    [Fact]
    public async Task VacantHistoricalAliasDoesNotPreventCompletion()
    {
        var operation = await PrepareAsync();
        await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/new", "/share/new/old-child"]);
        Assert.Equal(CloudDriveRelocationPhase.Completed,
            (await new CloudDriveRelocationCompletion(_mapping, Sync, Catalog, _ => true).CompleteAsync(operation.Id)).Phase);
        var names = await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), []);
        Assert.Equal("new", names["/share/new"]); Assert.DoesNotContain("/share/new/old-child", names.Keys);
    }

    [Fact]
    public async Task OccupiedCatalogDestinationCannotBeMistakenForHistoricalAlias()
    {
        var operation = await PrepareAsync();
        await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/new"]);
        await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/new"]);
        await Assert.ThrowsAsync<InvalidDataException>(() => new CloudDriveRelocationCompletion(_mapping, Sync, Catalog, _ => true).CompleteAsync(operation.Id));
        Assert.Equal("/share/old", (await Catalog.LoadItemPathsAsync(_mapping.Id))[operation.ItemIdentity]);
        Assert.Contains("/share/old", (await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), [])).Keys);
    }

    [Theory]
    [InlineData("D:", "\\cache\\drive\\new.txt", "D:\\cache\\drive\\new.txt")]
    [InlineData("d:", "\\CACHE\\drive\\目录\\new.txt", "d:\\CACHE\\drive\\目录\\new.txt")]
    public void VolumeRelativeRenameTargetStaysInsideMapping(string drive, string relative, string expected) =>
        Assert.Equal(expected, CloudFileRenamePaths.ResolveTarget(drive, relative, "D:\\cache\\drive"));

    [Theory]
    [InlineData("D:", "\\cache\\other\\new.txt")]
    [InlineData("D:", "\\cache\\drive\\..\\new.txt")]
    [InlineData("D:", "\\cache\\drive\\item:stream")]
    [InlineData("D:", "\\\\server\\share\\item")]
    [InlineData("D:", "relative.txt")]
    [InlineData("D:", "\\cache\\drive")]
    [InlineData("E:", "\\cache\\drive\\new.txt")]
    public void UnsafeRenameTargetsAreRejected(string drive, string relative) =>
        Assert.Throws<InvalidDataException>(() => CloudFileRenamePaths.ResolveTarget(drive, relative, "D:\\cache\\drive"));

    private async Task<CloudDriveRelocationOperation> PrepareAsync()
    {
        await Catalog.SaveAsync([_mapping]);
        var identity = Assert.Single(await Catalog.RegisterItemPathsAsync(_mapping.Id, ["/share/old"])).Key;
        await Sync.SetWritebackEnabledAsync(_mapping, true, true);
        await Sync.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/old"]);
        var operation = new CloudDriveRelocationOperation(Guid.NewGuid(), identity, "/share/old", "/share/new", "new", false, 3,
            DateTimeOffset.UnixEpoch, [new("/share/old", "/share/new", false)], 0, CloudDriveRelocationPhase.Prepared, DateTimeOffset.UtcNow);
        await Sync.AddRelocationOperationAsync(_mapping, operation);
        var submitted = operation with { Phase = CloudDriveRelocationPhase.Submitted };
        await Sync.UpdateRelocationOperationAsync(_mapping, operation, submitted);
        var verified = submitted with { Step = 1, Phase = CloudDriveRelocationPhase.ServerVerified };
        await Sync.UpdateRelocationOperationAsync(_mapping, submitted, verified);
        return verified;
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
