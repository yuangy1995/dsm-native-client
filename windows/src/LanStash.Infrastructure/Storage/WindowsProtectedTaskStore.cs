using System.Security.Cryptography;
using Windows.Security.Cryptography;
using Windows.Security.Cryptography.DataProtection;

namespace LanStash.Infrastructure;

public interface IProtectedTaskStore
{
    Task<IReadOnlyDictionary<Guid, byte[]>> LoadAsync();
    Task SaveAsync(Guid id, byte[] record);
}

/// <summary>独立的当前 Windows 用户加密记录；不与登录配置及云盘日志共用格式。</summary>
public sealed class WindowsProtectedTaskStore(string directory) : IProtectedTaskStore, IDisposable
{
    public static WindowsProtectedTaskStore CrossNas { get; } = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "Recovery", "CrossNas-v1"));
    public static WindowsProtectedTaskStore PhotosUploads { get; } = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "Recovery", "PhotosUpload-v1"));
    public static WindowsProtectedTaskStore PhotosManagement { get; } = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "Recovery", "PhotosManagement-v1"));
    public static WindowsProtectedTaskStore OfficeEditing { get; } = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "Recovery", "OfficeEditing-v1"));
    public static WindowsProtectedTaskStore DownloadActions { get; } = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "Recovery", "DownloadActions-v1"));
    public static WindowsProtectedTaskStore NasManagement { get; } = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "Recovery", "NasManagement-v1"));
    private readonly string _directory = Path.GetFullPath(directory);
    private readonly SemaphoreSlim _gate = new(1, 1);
    private FileStream? _lease;
    private bool _loaded, _disposed;
    private Exception? _failure;
    private const int MaximumRecordBytes = 32 * 1024 * 1024;

    public async Task<IReadOnlyDictionary<Guid, byte[]>> LoadAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        var result = new Dictionary<Guid, byte[]>();
        try
        {
            CheckAvailable();
            if (_loaded) throw new InvalidOperationException("recovery.already-loaded");
            Directory.CreateDirectory(_directory);
            if ((File.GetAttributes(_directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("recovery.directory-link");
            _lease = new FileStream(Path.Combine(_directory, "writer.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
            foreach (var path in Directory.EnumerateFiles(_directory, "*.task"))
            {
                if (!Guid.TryParseExact(Path.GetFileNameWithoutExtension(path), "N", out var id) || id == Guid.Empty ||
                    (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0 || new FileInfo(path).Length > MaximumRecordBytes)
                    throw new InvalidDataException("recovery.invalid-record");
                var encrypted = await File.ReadAllBytesAsync(path).ConfigureAwait(false);
                var buffer = await new DataProtectionProvider().UnprotectAsync(CryptographicBuffer.CreateFromByteArray(encrypted));
                CryptographicBuffer.CopyToByteArray(buffer, out var bytes);
                result.Add(id, bytes);
            }
            _loaded = true;
            return result;
        }
        catch (Exception error)
        {
            foreach (var bytes in result.Values) CryptographicOperations.ZeroMemory(bytes);
            _failure = error;
            throw;
        }
        finally { _gate.Release(); }
    }

    public async Task SaveAsync(Guid id, byte[] record)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        string? temporary = null;
        try
        {
            CheckAvailable();
            if (!_loaded || _lease is null || id == Guid.Empty || record.Length > MaximumRecordBytes)
                throw new InvalidOperationException("recovery.not-ready");
            var buffer = await new DataProtectionProvider("LOCAL=user").ProtectAsync(CryptographicBuffer.CreateFromByteArray(record));
            CryptographicBuffer.CopyToByteArray(buffer, out var encrypted);
            temporary = Path.Combine(_directory, $"{Guid.NewGuid():N}.pending");
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                4096, FileOptions.WriteThrough | FileOptions.Asynchronous))
            {
                await stream.WriteAsync(encrypted).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            // 同目录原子替换；中断时仅旧版或新版可见，不写明文中间文件。
            File.Move(temporary, Path.Combine(_directory, $"{id:N}.task"), overwrite: true);
            temporary = null;
        }
        catch (Exception error) { _failure = error; throw; }
        finally
        {
            try { if (temporary is not null) File.Delete(temporary); }
            finally { _gate.Release(); }
        }
    }

    private void CheckAvailable()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_failure is not null) throw new IOException("recovery.storage-unavailable", _failure);
    }
    public void Dispose() { _disposed = true; _lease?.Dispose(); }
}
