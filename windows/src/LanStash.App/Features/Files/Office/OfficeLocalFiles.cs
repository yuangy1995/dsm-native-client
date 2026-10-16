using LanStash.App.CloudDrive;
using LanStash.App.Features.Transfers;
using LanStash.Domain;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace LanStash.App.Features.Files.Office;

internal sealed record OfficeLocalStamp(ulong Volume, ulong FileIdLow, ulong FileIdHigh, long Length, long Modified, long Changed);

internal sealed class OfficeUploadSnapshot(Stream content, OfficeContentFingerprint fingerprint, OfficeLocalStamp stamp) : IAsyncDisposable
{
    public Stream Content { get; } = content;
    public OfficeContentFingerprint Fingerprint { get; } = fingerprint;
    public OfficeLocalStamp Stamp { get; } = stamp;
    public ValueTask DisposeAsync() => Content.DisposeAsync();
}

internal interface IOfficeLocalCopy : IDisposable
{
    OfficeLocalStamp ReadStamp();
    Task<OfficeUploadSnapshot> FreezeAsync(CancellationToken token);
}

internal interface IOfficeLocalFiles
{
    Task<OfficeContentFingerprint> DownloadAsync(IOfficeEditingRepository repository, OfficeRemoteSnapshot baseline,
        string destination, CancellationToken token);
    IOfficeLocalCopy Open(string path);
    Task ExportAsync(IOfficeLocalCopy copy, string destination, CancellationToken token);
}

internal sealed class OfficeLocalFiles : IOfficeLocalFiles
{
    public IOfficeLocalCopy Open(string path) => new OfficeLocalCopy(path);

    public async Task<OfficeContentFingerprint> DownloadAsync(IOfficeEditingRepository repository, OfficeRemoteSnapshot baseline,
        string destination, CancellationToken token)
    {
        using var parent = ForegroundDownloadDirectoryLease.Acquire(Path.GetDirectoryName(destination)!);
        var output = await WindowsTransactionalDownloadDestination.CreateAsync(destination, validateTarget: parent.Validate);
        var verified = new OfficeDownloadDestination(output, repository, baseline, token);
        await new SafeFileDownloadService().DownloadAsync(repository, baseline.Metadata.Item.Path,
            baseline.Metadata.Item.Size, verified, cancellationToken: token).ConfigureAwait(false);
        return verified.Fingerprint!;
    }

    public async Task ExportAsync(IOfficeLocalCopy copy, string destination, CancellationToken token)
    {
        await using var snapshot = await copy.FreezeAsync(token).ConfigureAwait(false);
        using var parent = ForegroundDownloadDirectoryLease.Acquire(Path.GetDirectoryName(destination)!);
        await using var output = await WindowsTransactionalDownloadDestination.CreateAsync(destination, validateTarget: parent.Validate);
        try
        {
            var buffer = new byte[1024 * 1024];
            int read;
            while ((read = await snapshot.Content.ReadAsync(buffer, token).ConfigureAwait(false)) > 0)
                await output.WriteAsync(buffer.AsMemory(0, read), token).ConfigureAwait(false);
            await output.CommitAsync(token).ConfigureAwait(false);
        }
        catch { await output.AbortAsync(CancellationToken.None).ConfigureAwait(false); throw; }
    }

    /// <summary>提交本机替换前核对下载摘要及原远端版本，失败保留用户已有副本。</summary>
    private sealed class OfficeDownloadDestination(ITransactionalDownloadDestination destination, IOfficeEditingRepository repository,
        OfficeRemoteSnapshot baseline, CancellationToken lifetime) : ITransactionalDownloadDestination
    {
        private readonly IncrementalHash _md5 = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
        private readonly IncrementalHash _sha256 = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        private long _length;
        public OfficeContentFingerprint? Fingerprint { get; private set; }
        public async ValueTask WriteAsync(ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken = default)
        {
            await destination.WriteAsync(bytes, cancellationToken).ConfigureAwait(false);
            _md5.AppendData(bytes.Span); _sha256.AppendData(bytes.Span); _length += bytes.Length;
        }
        public async ValueTask CommitAsync(CancellationToken cancellationToken = default)
        {
            lifetime.ThrowIfCancellationRequested();
            var fingerprint = new OfficeContentFingerprint(_length, Convert.ToHexString(_md5.GetHashAndReset()),
                Convert.ToHexString(_sha256.GetHashAndReset()));
            var current = await repository.ReadOfficeRemoteAsync(baseline.Metadata.Item.Path, lifetime).ConfigureAwait(false);
            if (_length != baseline.Metadata.Item.Size || !string.Equals(fingerprint.Md5, baseline.Md5, StringComparison.OrdinalIgnoreCase) ||
                current.Metadata.Item.Path != baseline.Metadata.Item.Path || current.Metadata.Item.Size != baseline.Metadata.Item.Size ||
                current.Metadata.Item.ModifiedAt != baseline.Metadata.Item.ModifiedAt || current.Metadata.Type != baseline.Metadata.Type ||
                current.Metadata.MountPointType != baseline.Metadata.MountPointType ||
                !string.Equals(current.Md5, baseline.Md5, StringComparison.OrdinalIgnoreCase)) throw new IOException("office.download-changed");
            lifetime.ThrowIfCancellationRequested();
            await destination.CommitAsync(cancellationToken).ConfigureAwait(false);
            Fingerprint = fingerprint;
        }
        public ValueTask AbortAsync(CancellationToken cancellationToken = default) => destination.AbortAsync(cancellationToken);
        public async ValueTask DisposeAsync()
        { _md5.Dispose(); _sha256.Dispose(); await destination.DisposeAsync().ConfigureAwait(false); }
    }
}

internal sealed class OfficeLocalCopy : IOfficeLocalCopy
{
    private readonly string _path;
    private readonly ForegroundDownloadDirectoryLease _parent;
    public OfficeLocalCopy(string path)
    {
        _path = Path.GetFullPath(path);
        _parent = ForegroundDownloadDirectoryLease.Acquire(Path.GetDirectoryName(_path)!);
        try { _ = ReadStamp(); }
        catch { _parent.Dispose(); throw; }
    }

    public OfficeLocalStamp ReadStamp()
    {
        _parent.Validate();
        using var handle = OpenHandle(readContent: false);
        return ReadStamp(handle);
    }

    public Task<OfficeUploadSnapshot> FreezeAsync(CancellationToken token) => Task.Run(() => Freeze(token), token);

    private OfficeUploadSnapshot Freeze(CancellationToken token)
    {
        _parent.Validate();
        using var handle = OpenHandle(readContent: true);
        var before = ReadStamp(handle);
        using var input = new FileStream(handle, FileAccess.Read);
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LanStash", "OfficeSnapshots");
        Directory.CreateDirectory(directory);
        using var snapshotParent = ForegroundDownloadDirectoryLease.Acquire(directory);
        var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".snapshot");
        // 文件只由本次上传持有，退出或异常时系统删除；编辑器不能修改上传中的内容。
        var output = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 1024 * 1024,
            FileOptions.DeleteOnClose | FileOptions.SequentialScan);
        try
        {
            using var md5 = IncrementalHash.CreateHash(HashAlgorithmName.MD5);
            using var sha256 = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[1024 * 1024];
            long length = 0; int read;
            while ((read = input.Read(buffer)) > 0)
            {
                token.ThrowIfCancellationRequested();
                output.Write(buffer, 0, read); md5.AppendData(buffer, 0, read); sha256.AppendData(buffer, 0, read); length += read;
            }
            _parent.Validate(); snapshotParent.Validate();
            if (ReadStamp(handle) != before || ReadStamp() != before || length != before.Length)
                throw new IOException("office.local-changed-during-read");
            output.Position = 0;
            return new(output, new(length, Convert.ToHexString(md5.GetHashAndReset()), Convert.ToHexString(sha256.GetHashAndReset())), before);
        }
        catch { output.Dispose(); throw; }
    }

    private SafeFileHandle OpenHandle(bool readContent) => CloudFilesInterop.CreateFile(_path,
        readContent ? 0x80000000u : 0x80u, readContent ? 1u : CloudFilesInterop.FileShareReadWriteDelete,
        IntPtr.Zero, CloudFilesInterop.OpenExisting, CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);

    private static OfficeLocalStamp ReadStamp(SafeFileHandle handle)
    {
        if (handle.IsInvalid || !GetFileIdentity(handle, 18, out var identity, 24) ||
            !CloudFilesInterop.GetFileBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()) ||
            !CloudFilesInterop.GetFileStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<CloudFilesInterop.FileStandardInfo>()) ||
            standard.Directory != 0 || standard.EndOfFile < 0 ||
            (basic.FileAttributes & (uint)(FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException("office.local-unavailable");
        return new(identity.Volume, identity.Low, identity.High, standard.EndOfFile, basic.LastWriteTime, basic.ChangeTime);
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct FileIdentity(ulong Volume, ulong Low, ulong High);
    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileIdentity(SafeFileHandle handle, int informationClass, out FileIdentity identity, uint size);
    public void Dispose() => _parent.Dispose();
}
