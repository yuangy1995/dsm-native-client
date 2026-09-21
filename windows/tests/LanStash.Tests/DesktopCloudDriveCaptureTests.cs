using LanStash.App.CloudDrive;
using LanStash.Domain;
using System.Text.Json.Nodes;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveCaptureTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-capture-tests-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic",
        DesktopDriveScope.Folder("/share"), DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private DesktopCloudDriveSyncStore Store => new(Path.Combine(_root, "state"));
    private string LocalRoot => Path.Combine(_root, "drive");

    [Fact]
    public async Task OrdinaryReplacementAtRegisteredLocationBecomesImmutableSnapshot()
    {
        var local = await PrepareAsync(); var id = Guid.NewGuid();
        var record = await Store.PrepareMappedSaveAsync(_mapping, id, "/share/item.txt", local, LocalRoot, null,
            emptyBaseModifiedAt: DateTimeOffset.UnixEpoch);
        await File.WriteAllTextAsync(local, "next edit");
        await using var content = await Store.OpenContentAsync(_mapping, id);
        using var reader = new StreamReader(content);
        Assert.Equal("synthetic edit", await reader.ReadToEndAsync());
        Assert.Equal(DateTimeOffset.UnixEpoch, record.EmptyBaseModifiedAt);
    }

    [Fact]
    public async Task SameNameOutsideMappingCannotBeCaptured()
    {
        await PrepareAsync(); var outside = Path.Combine(_root, "item.txt"); await File.WriteAllTextAsync(outside, "outside");
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.PrepareMappedSaveAsync(_mapping, Guid.NewGuid(),
            "/share/item.txt", outside, LocalRoot, null, emptyBaseModifiedAt: DateTimeOffset.UnixEpoch));
        Assert.Empty(await Store.ReadChangesAsync(_mapping));
    }

    [Fact]
    public async Task UnregisteredNameCannotImpersonateAnExistingFile()
    {
        var local = await PrepareAsync();
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.PrepareMappedSaveAsync(_mapping, Guid.NewGuid(),
            "/share/other.txt", local, LocalRoot, null, emptyBaseModifiedAt: DateTimeOffset.UnixEpoch));
        Assert.Empty(await Store.ReadChangesAsync(_mapping));
    }

    [Fact]
    public async Task FileStillOpenForWritingDoesNotCreatePartialSnapshot()
    {
        var local = await PrepareAsync();
        await using (var writer = new FileStream(local, FileMode.Open, FileAccess.Write, FileShare.ReadWrite))
            await Assert.ThrowsAsync<IOException>(() => Store.PrepareMappedSaveAsync(_mapping, Guid.NewGuid(),
                "/share/item.txt", local, LocalRoot, null, emptyBaseModifiedAt: DateTimeOffset.UnixEpoch));
        Assert.Empty(await Store.ReadChangesAsync(_mapping));
    }

    [Fact]
    public async Task DisabledWritebackCannotCaptureEvenRegisteredContent()
    {
        var local = await PrepareAsync(); await Store.SetWritebackEnabledAsync(_mapping, false, true);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Store.PrepareMappedSaveAsync(_mapping, Guid.NewGuid(),
            "/share/item.txt", local, LocalRoot, null, emptyBaseModifiedAt: DateTimeOffset.UnixEpoch));
        Assert.Empty(await Store.ReadChangesAsync(_mapping));
    }

    [Fact]
    public async Task ExistingMappedFileCannotBeGuessedAsNewWithoutBaseline()
    {
        var local = await PrepareAsync();
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.PrepareMappedSaveAsync(_mapping, Guid.NewGuid(),
            "/share/item.txt", local, LocalRoot, null));
        Assert.Empty(await Store.ReadChangesAsync(_mapping));
    }

    [Fact]
    public async Task RestartedCaptureUsesRecordedEmptyBaselineInsteadOfEditedFileTime()
    {
        var local = await PrepareAsync();
        await Store.BindEmptyFileBaselineAsync(_mapping, "/share/item.txt", DateTimeOffset.UnixEpoch);
        File.SetLastWriteTimeUtc(local, DateTime.UtcNow);
        var change = await Store.CaptureMappedSaveAsync(_mapping, Guid.NewGuid(), "/share/item.txt", local, LocalRoot);
        Assert.Equal(DateTimeOffset.UnixEpoch, change.EmptyBaseModifiedAt);
        Assert.True(change.WasExisting);
        var state = JsonNode.Parse(await File.ReadAllTextAsync(StatePath))!;
        Assert.Equal(4, state["Version"]!.GetValue<int>());
        Assert.NotNull(state["EmptyFileBaselines"]);
    }

    [Fact]
    public async Task AutomaticCaptureRequiresPersistedBaseline()
    {
        var local = await PrepareAsync();
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.CaptureMappedSaveAsync(_mapping, Guid.NewGuid(),
            "/share/item.txt", local, LocalRoot));
        Assert.Empty(await Store.ReadChangesAsync(_mapping));
    }

    [Fact]
    public async Task AutomaticCaptureRetainsStrongVersionForNonemptyFile()
    {
        var local = await PrepareAsync();
        await Store.BindVersionAsync(_mapping, new("/share/item.txt", "\"original\"", 10));
        var change = await Store.CaptureMappedSaveAsync(_mapping, Guid.NewGuid(), "/share/item.txt", local, LocalRoot);
        Assert.Equal("\"original\"", change.BaseVersion);
        Assert.Null(change.EmptyBaseModifiedAt);
    }

    [Fact]
    public async Task EmptyBaselineCannotBeChangedOrConvertedToStrongVersionSilently()
    {
        var local = await PrepareAsync();
        await Store.BindEmptyFileBaselineAsync(_mapping, "/share/item.txt", DateTimeOffset.UnixEpoch);
        await Store.BindEmptyFileBaselineAsync(_mapping, "/share/item.txt", DateTimeOffset.UnixEpoch);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.BindEmptyFileBaselineAsync(_mapping,
            "/share/item.txt", DateTimeOffset.UnixEpoch.AddSeconds(1)));
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.BindVersionAsync(_mapping, new("/share/item.txt", "\"changed\"", 1)));
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.PrepareMappedSaveAsync(_mapping, Guid.NewGuid(),
            "/share/item.txt", local, LocalRoot, null, emptyBaseModifiedAt: DateTimeOffset.UnixEpoch.AddSeconds(1)));
        Assert.Empty(await Store.ReadChangesAsync(_mapping));
    }

    [Fact]
    public async Task DamagedNewBaselineTableIsNotInterpretedAsANewFile()
    {
        var local = await PrepareAsync();
        await Store.BindEmptyFileBaselineAsync(_mapping, "/share/item.txt", DateTimeOffset.UnixEpoch);
        var state = JsonNode.Parse(await File.ReadAllTextAsync(StatePath))!.AsObject();
        state.Remove("EmptyFileBaselines");
        await File.WriteAllTextAsync(StatePath, state.ToJsonString());
        var damaged = await File.ReadAllTextAsync(StatePath);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.CaptureMappedSaveAsync(_mapping, Guid.NewGuid(),
            "/share/item.txt", local, LocalRoot));
        Assert.Equal(damaged, await File.ReadAllTextAsync(StatePath));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task RefreshOrRemovalDropsOldEmptyBaseline(bool remove)
    {
        var local = await PrepareAsync();
        await Store.BindEmptyFileBaselineAsync(_mapping, "/share/item.txt", DateTimeOffset.UnixEpoch);
        if (remove) Assert.True(await Store.TryRemoveLocalProjectionAsync(_mapping, "/share/item.txt", _ => Task.FromResult(true)));
        else await Store.RefreshVersionAsync(_mapping, "/share/item.txt", null, null, _ => Task.CompletedTask);
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.CaptureMappedSaveAsync(_mapping, Guid.NewGuid(),
            "/share/item.txt", local, LocalRoot));
    }

    private string StatePath => Path.Combine(_root, "state", _mapping.Id.ToString("N"), "state.json");

    private async Task<string> PrepareAsync()
    {
        Directory.CreateDirectory(LocalRoot);
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/item.txt"]);
        var local = Path.Combine(LocalRoot, "item.txt"); await File.WriteAllTextAsync(local, "synthetic edit");
        return local;
    }
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
