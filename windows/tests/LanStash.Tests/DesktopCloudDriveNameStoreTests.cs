using System.Text.Json.Nodes;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveNameStoreTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-name-tests-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic",
        DesktopDriveScope.Folder("/share"), DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private DesktopCloudDriveSyncStore Store => new(_root);
    private string StatePath => Path.Combine(_root, _mapping.Id.ToString("N"), "state.json");

    [Fact]
    public async Task NewCaseCollisionDoesNotRenameExistingFileAndSurvivesRestart()
    {
        var original = await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/Report.txt"]);
        var next = await Store.RegisterLocalNamesAsync(_mapping, original, ["/share/report.txt"]);
        Assert.Equal("Report.txt", next["/share/Report.txt"]);
        Assert.NotEqual(next["/share/Report.txt"].ToUpperInvariant(), next["/share/report.txt"].ToUpperInvariant());
        var restarted = await Store.RegisterLocalNamesAsync(_mapping,
            DesktopDriveWindowsNameCodec.BuildSafeSegments(next.Keys), next.Keys);
        Assert.Equal(next.OrderBy(item => item.Key), restarted.OrderBy(item => item.Key));
    }

    [Fact]
    public async Task V1MigrationKeepsContentVersionsPendingEditsAndOldNames()
    {
        var version = new CloudDriveContentVersion("/share/a.txt", "\"old\"", 3);
        await Store.BindVersionAsync(_mapping, version);
        await Store.SetWritebackEnabledAsync(_mapping, true, true);
        var source = Path.Combine(_root, "edit.txt"); await File.WriteAllTextAsync(source, "new");
        var edit = await Store.PrepareSaveAsync(_mapping, Guid.NewGuid(), version.RemotePath, source, version.Version);
        Assert.Equal(1, JsonNode.Parse(await File.ReadAllTextAsync(StatePath))!["Version"]!.GetValue<int>());
        var names = await Store.RegisterLocalNamesAsync(_mapping,
            new Dictionary<string, string> { [version.RemotePath] = "a.txt" }, ["/share/A.txt"]);
        Assert.Equal(2, JsonNode.Parse(await File.ReadAllTextAsync(StatePath))!["Version"]!.GetValue<int>());
        Assert.Equal("a.txt", names[version.RemotePath]);
        Assert.Equal(version, await Store.ReadVersionAsync(_mapping, version.RemotePath));
        Assert.Equal(edit, Assert.Single(await Store.ReadChangesAsync(_mapping)));
        Assert.Equal("new", await File.ReadAllTextAsync(Path.Combine(_root, _mapping.Id.ToString("N"), edit.Id.ToString("N") + ".content")));
    }

    [Fact]
    public async Task DifferentRemoteParentsHaveIndependentLocalNameSpaces()
    {
        var names = await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(),
            ["/share/Folder", "/share/folder", "/share/Folder/file.txt", "/share/folder/file.txt"]);
        Assert.NotEqual(names["/share/Folder"].ToUpperInvariant(), names["/share/folder"].ToUpperInvariant());
        Assert.Equal("file.txt", names["/share/Folder/file.txt"]);
        Assert.Equal("file.txt", names["/share/folder/file.txt"]);
    }

    [Fact]
    public async Task LongEscapedNamesRemainWithinWindowsLeafLimitAndKeepExtension()
    {
        var path = "/share/" + new string('?', 250) + ".txt";
        var names = await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), [path]);
        Assert.InRange(names[path].Length, 1, 255); Assert.EndsWith(".txt", names[path]);
        Assert.DoesNotContain('?', names[path]);
        Assert.Equal(names[path], (await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), [path]))[path]);
    }

    [Fact]
    public async Task MappingRootHasNoLeafAliasAndDeviceNamesAreEscaped()
    {
        var names = await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share", "/share/CON"]);
        Assert.Single(names); Assert.Equal("%00CON", names["/share/CON"]);
    }

    [Fact]
    public async Task V2WithoutNameMapCannotSilentlyRecomputeNames()
    {
        await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/a.txt"]);
        var state = JsonNode.Parse(await File.ReadAllTextAsync(StatePath))!.AsObject(); state.Remove("LocalNames");
        await File.WriteAllTextAsync(StatePath, state.ToJsonString());
        await Assert.ThrowsAsync<InvalidDataException>(() => Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), ["/share/a.txt"]));
    }

    [Fact]
    public async Task LargeDirectoryAndLaterInsertKeepAllAssignments()
    {
        var paths = Enumerable.Range(0, 5000).Select(index => $"/share/item-{index:D5}.txt").ToArray();
        var names = await Store.RegisterLocalNamesAsync(_mapping, new Dictionary<string, string>(), paths);
        var added = await Store.RegisterLocalNamesAsync(_mapping, names, ["/share/ITEM-00001.txt"]);
        Assert.Equal(5001, added.Count);
        Assert.All(names, item => Assert.Equal(item.Value, added[item.Key]));
    }

    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
