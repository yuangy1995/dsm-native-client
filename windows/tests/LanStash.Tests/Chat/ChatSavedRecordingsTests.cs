using LanStash.App.Features.Chat;

namespace LanStash.Tests.Chat;

public sealed class ChatSavedRecordingsTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "LanStash-voice-recovery-test-" + Guid.NewGuid().ToString("N"));
    private readonly HashSet<string> _protected = new(StringComparer.OrdinalIgnoreCase);
    public ChatSavedRecordingsTests() => Directory.CreateDirectory(_root);
    private ChatSavedRecordings Store => new(_root);

    [Fact]
    public async Task ListsOnlyCompletedOwnedRecordingsWithoutOpeningActiveDrafts()
    {
        var saved = await WriteAsync([1, 2, 3]);
        var active = await WriteAsync([4, 5, 6]); _protected.Add(active);
        await WriteAsync([]);
        await File.WriteAllBytesAsync(Path.Combine(_root, "unrelated.m4a"), [9]);
        await File.WriteAllBytesAsync(Path.Combine(_root, Guid.NewGuid().ToString("N") + ".txt"), [9]);
        var result = await Store.ListAsync(_protected);
        var recording = Assert.Single(result.Items);
        Assert.Equal(saved, recording.Path); Assert.Equal(3, recording.Length); Assert.Equal(0, result.UnavailableCount);
    }

    [Fact]
    public async Task LockedRecordingIsReportedUnavailableAndNeverDeleted()
    {
        var path = await WriteAsync([1, 2, 3]);
        await using (var locked = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            var result = await Store.ListAsync(_protected);
            Assert.Empty(result.Items); Assert.Equal(1, result.UnavailableCount);
        }
        Assert.Single((await Store.ListAsync(_protected)).Items); Assert.True(File.Exists(path));
    }

    [Fact]
    public async Task ExportKeepsOriginalAndWritesExactContent()
    {
        var bytes = new byte[] { 1, 2, 3, 4, 5 }; var path = await WriteAsync(bytes);
        var recording = Assert.Single((await Store.ListAsync(_protected)).Items);
        var destination = Path.Combine(_root, "export.m4a");
        await Store.ExportAsync(recording, destination, _protected);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(destination)); Assert.Equal(bytes, await File.ReadAllBytesAsync(path));
        Assert.Single((await Store.ListAsync(_protected)).Items);
    }

    [Fact]
    public async Task FailedOrCancelledExportKeepsOriginalAndExistingDestination()
    {
        var path = await WriteAsync([1, 2, 3]); var recording = Assert.Single((await Store.ListAsync(_protected)).Items);
        var destination = Path.Combine(_root, "export.m4a"); await File.WriteAllBytesAsync(destination, [7, 8]);
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Store.ExportAsync(recording, destination, _protected, cancellation.Token));
        Assert.Equal(new byte[] { 7, 8 }, await File.ReadAllBytesAsync(destination)); Assert.True(File.Exists(path));
        await Assert.ThrowsAsync<IOException>(() => Store.ExportAsync(recording, path, _protected)); Assert.True(File.Exists(path));
        Assert.Equal(2, Directory.GetFiles(_root).Length);
    }

    [Fact]
    public async Task ReplacedRecordingCannotBeExportedOrDiscardedUsingOldSelection()
    {
        var path = await WriteAsync([1, 2, 3]); var recording = Assert.Single((await Store.ListAsync(_protected)).Items);
        File.Move(path, Path.Combine(_root, "previous.m4a")); await File.WriteAllBytesAsync(path, [4, 5, 6]);
        File.SetLastWriteTimeUtc(path, DateTime.FromFileTimeUtc(recording.Modified));
        await Assert.ThrowsAsync<IOException>(() => Store.ExportAsync(recording, Path.Combine(_root, "export.m4a"), _protected));
        Assert.Throws<IOException>(() => Store.Discard(recording, _protected));
        Assert.Equal(new byte[] { 4, 5, 6 }, await File.ReadAllBytesAsync(path));
    }

    [Fact]
    public async Task ChangedContentAndNewlyActiveDraftAreProtected()
    {
        var path = await WriteAsync([1, 2, 3]); var recording = Assert.Single((await Store.ListAsync(_protected)).Items);
        await File.WriteAllBytesAsync(path, [4, 5, 6, 7]);
        Assert.Throws<IOException>(() => Store.Discard(recording, _protected));
        recording = Assert.Single((await Store.ListAsync(_protected)).Items); _protected.Add(path);
        Assert.Throws<IOException>(() => Store.Discard(recording, _protected));
        await Assert.ThrowsAsync<IOException>(() => Store.ExportAsync(recording, Path.Combine(_root, "export.m4a"), _protected));
        Assert.True(File.Exists(path));
    }

    [Fact]
    public async Task ExplicitDiscardRemovesOnlyTheSelectedOriginal()
    {
        var first = await WriteAsync([1, 2, 3]); var second = await WriteAsync([4, 5, 6]);
        var recording = (await Store.ListAsync(_protected)).Items.Single(item => item.Path == first);
        Store.Discard(recording, _protected);
        Assert.False(File.Exists(first)); Assert.True(File.Exists(second));
        Assert.Throws<IOException>(() => Store.Discard(recording, _protected));
    }

    [Fact]
    public async Task SelectionOutsideRecordingDirectoryIsRejected()
    {
        var path = await WriteAsync([1, 2, 3]); var recording = Assert.Single((await Store.ListAsync(_protected)).Items);
        var nested = Path.Combine(_root, "nested"); Directory.CreateDirectory(nested);
        var moved = Path.Combine(nested, Path.GetFileName(path)); File.Move(path, moved);
        Assert.Throws<IOException>(() => Store.Discard(recording with { Path = moved }, _protected));
        Assert.True(File.Exists(moved)); Assert.Empty((await Store.ListAsync(_protected)).Items);
    }

    private async Task<string> WriteAsync(byte[] bytes)
    {
        var path = Path.Combine(_root, Guid.NewGuid().ToString("N") + ".m4a");
        await File.WriteAllBytesAsync(path, bytes); return path;
    }
    public void Dispose()
    {
        foreach (var file in Directory.EnumerateFiles(_root, "*", SearchOption.AllDirectories)) File.Delete(file);
        foreach (var folder in Directory.EnumerateDirectories(_root).OrderByDescending(path => path.Length)) Directory.Delete(folder);
        Directory.Delete(_root);
    }
}
