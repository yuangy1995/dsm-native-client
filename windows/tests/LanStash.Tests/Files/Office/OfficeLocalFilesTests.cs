using System.Text;
using LanStash.App.Features.Files.Office;
using LanStash.Domain;

namespace LanStash.Tests.Files.Office;

public sealed class OfficeLocalFilesTests
{
    [Fact]
    public async Task FrozenSnapshotIsIndependentFromSubsequentEditorWrites()
    {
        using var folder = new OfficeTestDirectory(); var path = folder.FilePath();
        await File.WriteAllTextAsync(path, "original bytes", new UTF8Encoding(false));
        using var copy = new OfficeLocalCopy(path);
        await using var snapshot = await copy.FreezeAsync(default);
        await File.WriteAllTextAsync(path, "new editor save", new UTF8Encoding(false));
        using var reader = new StreamReader(snapshot.Content, Encoding.UTF8, leaveOpen: true);
        Assert.Equal("original bytes", await reader.ReadToEndAsync());
        Assert.Equal(OfficeTestServer.Fingerprint(Encoding.UTF8.GetBytes("original bytes")), snapshot.Fingerprint);
        Assert.NotEqual(snapshot.Stamp, copy.ReadStamp());
    }

    [Fact]
    public async Task AtomicReplacementWithEqualLengthAndModificationTimeChangesIdentity()
    {
        using var folder = new OfficeTestDirectory(); var path = folder.FilePath();
        await File.WriteAllTextAsync(path, "first", new UTF8Encoding(false));
        using var copy = new OfficeLocalCopy(path); var before = copy.ReadStamp(); var modified = File.GetLastWriteTimeUtc(path);
        var replacement = folder.FilePath("replacement.docx"); await File.WriteAllTextAsync(replacement, "other", new UTF8Encoding(false));
        File.SetLastWriteTimeUtc(replacement, modified); File.Move(replacement, path, overwrite: true);
        var after = copy.ReadStamp(); Assert.Equal(before.Length, after.Length); Assert.Equal(before.Modified, after.Modified);
        Assert.NotEqual((before.FileIdLow, before.FileIdHigh), (after.FileIdLow, after.FileIdHigh));
        await using var snapshot = await copy.FreezeAsync(default);
        Assert.Equal(OfficeTestServer.Fingerprint(Encoding.UTF8.GetBytes("other")), snapshot.Fingerprint);
    }

    [Fact]
    public async Task LockedCopyCannotBeFrozenAndCancellationLeavesEditorCopyUntouched()
    {
        using var folder = new OfficeTestDirectory(); var path = folder.FilePath(); await File.WriteAllBytesAsync(path, [1, 2, 3]);
        using var copy = new OfficeLocalCopy(path);
        using (var writer = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.None))
            await Assert.ThrowsAsync<IOException>(() => copy.FreezeAsync(default));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => copy.FreezeAsync(new(true)));
        Assert.Equal(new byte[] { 1, 2, 3 }, await File.ReadAllBytesAsync(path));
    }

    [Fact]
    public async Task ChangedParentDirectoryNeverRedirectsTheEditingSession()
    {
        using var folder = new OfficeTestDirectory(); var parent = Path.Combine(folder.Path, "copy"); Directory.CreateDirectory(parent);
        var path = Path.Combine(parent, "document.docx"); await File.WriteAllBytesAsync(path, [1]);
        using var copy = new OfficeLocalCopy(path);
        var moved = Path.Combine(folder.Path, "old-copy"); Directory.Move(parent, moved); Directory.CreateDirectory(parent); await File.WriteAllBytesAsync(path, [2]);
        Assert.Throws<IOException>(() => copy.ReadStamp());
        await Assert.ThrowsAsync<IOException>(() => copy.FreezeAsync(default));
        Assert.Equal(new byte[] { 1 }, await File.ReadAllBytesAsync(Path.Combine(moved, "document.docx")));
    }

    [Theory]
    [InlineData(false)] [InlineData(true)]
    public async Task DownloadRechecksRemoteBeforeReplacingAnExistingLocalCopy(bool drift)
    {
        using var server = new OfficeTestServer(); using var folder = new OfficeTestDirectory(); var path = folder.FilePath();
        await File.WriteAllTextAsync(path, "keep this old local copy"); var previous = await File.ReadAllBytesAsync(path);
        var repo = server.Repository(); var baseline = await repo.ReadOfficeRemoteAsync(server.RemotePath);
        if (drift) server.Version++;
        if (drift)
        {
            await Assert.ThrowsAsync<IOException>(() => new OfficeLocalFiles().DownloadAsync(repo, baseline, path, default));
            Assert.Equal(previous, await File.ReadAllBytesAsync(path));
        }
        else
        {
            var fingerprint = await new OfficeLocalFiles().DownloadAsync(repo, baseline, path, default);
            Assert.Equal(server.Bytes, await File.ReadAllBytesAsync(path)); Assert.Equal(OfficeTestServer.Fingerprint(server.Bytes), fingerprint);
        }
        Assert.Empty(Directory.GetFiles(folder.Path, "*.download")); Assert.Equal(0, server.Uploads);
    }

    [Fact]
    public async Task SaveAsUsesAFrozenCopyAndKeepsTheEditingOriginal()
    {
        using var folder = new OfficeTestDirectory(); var path = folder.FilePath(); var destination = folder.FilePath("export.docx");
        await File.WriteAllBytesAsync(path, [0, 1, 255, 7]); using var copy = new OfficeLocalCopy(path);
        await new OfficeLocalFiles().ExportAsync(copy, destination, default);
        Assert.Equal(await File.ReadAllBytesAsync(path), await File.ReadAllBytesAsync(destination));
    }
}
