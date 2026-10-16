using System.Text;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.CopyMove;

public sealed class WindowsProtectedTaskStoreTests
{
    [Fact]
    public async Task WindowsUserEncryptionRoundTripsAndSerializesExclusiveAccess()
    {
        using var folder = new TemporaryFolder(); var id = Guid.NewGuid();
        var bytes = Encoding.UTF8.GetBytes("synthetic-only-private-path-and-digest");
        using (var store = new WindowsProtectedTaskStore(folder.Path))
        {
            Assert.Empty(await store.LoadAsync()); await store.SaveAsync(id, bytes);
            var encrypted = await File.ReadAllBytesAsync(System.IO.Path.Combine(folder.Path, $"{id:N}.task"));
            Assert.NotEqual(bytes, encrypted); Assert.DoesNotContain("synthetic-only", Encoding.UTF8.GetString(encrypted));
            using var competing = new WindowsProtectedTaskStore(folder.Path);
            await Assert.ThrowsAsync<IOException>(() => competing.LoadAsync());
            await Assert.ThrowsAsync<IOException>(() => competing.SaveAsync(id, [1]));
            await store.SaveAsync(id, bytes.Concat([ (byte)42 ]).ToArray());
            Assert.Empty(Directory.GetFiles(folder.Path, "*.pending"));
        }
        using var reopened = new WindowsProtectedTaskStore(folder.Path);
        var read = Assert.Single(await reopened.LoadAsync());
        Assert.Equal(id, read.Key); Assert.Equal(bytes.Concat([ (byte)42 ]), read.Value);
    }

    [Fact]
    public async Task TamperingCannotSilentlyResetOrOverwriteEncryptedRecord()
    {
        using var folder = new TemporaryFolder(); var id = Guid.NewGuid();
        using (var store = new WindowsProtectedTaskStore(folder.Path))
        { await store.LoadAsync(); await store.SaveAsync(id, Encoding.UTF8.GetBytes("synthetic-record")); }
        var path = System.IO.Path.Combine(folder.Path, $"{id:N}.task");
        var corrupted = await File.ReadAllBytesAsync(path); corrupted[corrupted.Length / 2] ^= 1;
        await File.WriteAllBytesAsync(path, corrupted);
        using var reopened = new WindowsProtectedTaskStore(folder.Path);
        await Assert.ThrowsAnyAsync<Exception>(() => reopened.LoadAsync());
        await Assert.ThrowsAsync<IOException>(() => reopened.SaveAsync(id, [1]));
        Assert.Equal(corrupted, await File.ReadAllBytesAsync(path));
    }

    private sealed class TemporaryFolder : IDisposable
    {
        public string Path { get; } = System.IO.Path.GetFullPath(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "LanStash-journal-test-" + Guid.NewGuid().ToString("N")));
        public void Dispose()
        {
            Assert.StartsWith(System.IO.Path.GetFullPath(System.IO.Path.GetTempPath()), Path, StringComparison.OrdinalIgnoreCase);
            if (Directory.Exists(Path)) Directory.Delete(Path, recursive: true);
        }
    }
}
