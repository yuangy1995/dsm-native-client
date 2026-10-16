using LanStash.App.CloudDrive;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;

namespace LanStash.App.Features.Transfers;

/// <summary>保留原目录身份，在写入和提交前拒绝联接、符号链接和已替换的目录。</summary>
internal sealed class ForegroundDownloadDirectoryLease : IDisposable
{
    private readonly List<(string Path, SafeFileHandle Handle, FileIdentity Identity)> _parents = [];

    public static ForegroundDownloadDirectoryLease Acquire(string directoryPath)
    {
        var lease = new ForegroundDownloadDirectoryLease();
        try
        {
            var parents = new Stack<DirectoryInfo>();
            for (var directory = new DirectoryInfo(Path.GetFullPath(directoryPath)); directory is not null; directory = directory.Parent)
                parents.Push(directory);
            foreach (var directory in parents)
            {
                // 复用现有 kernel32 声明，不涉及 Cloud Files 注册或同步语义。
                var handle = Open(directory.FullName);
                try { lease._parents.Add((directory.FullName, handle, Identity(handle))); }
                catch { handle.Dispose(); throw; }
            }
            lease.Validate();
            return lease;
        }
        catch { lease.Dispose(); throw; }
    }

    public void Validate()
    {
        foreach (var parent in _parents)
        {
            using var current = Open(parent.Path);
            if (Identity(current) != parent.Identity) throw new IOException("download.local-folder-changed");
        }
    }

    private static SafeFileHandle Open(string path) => CloudFilesInterop.CreateFile(path, 0x80,
        CloudFilesInterop.FileShareReadWriteDelete, IntPtr.Zero, CloudFilesInterop.OpenExisting,
        CloudFilesInterop.FileFlagOpenReparsePoint | CloudFilesInterop.FileFlagBackupSemantics, IntPtr.Zero);

    private static FileIdentity Identity(SafeFileHandle handle)
    {
        if (handle.IsInvalid || !GetFileIdentity(handle, 18, out var identity, 24) ||
            !CloudFilesInterop.GetFileBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()) ||
            (basic.FileAttributes & (uint)FileAttributes.Directory) == 0 || (basic.FileAttributes & (uint)FileAttributes.ReparsePoint) != 0)
            throw new IOException("download.local-folder-unavailable");
        return identity;
    }

    [StructLayout(LayoutKind.Sequential)]
    private readonly record struct FileIdentity(ulong Volume, ulong Low, ulong High);
    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileIdentity(SafeFileHandle handle, int informationClass, out FileIdentity identity, uint size);

    public static string Resolve(string root, string relativePath)
    {
        if (relativePath.Split('/').Any(part => !BoundedFileDownloadBatch.IsValidLocalName(part)))
            throw new InvalidDataException("download.invalid-local-path");
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        var path = Path.GetFullPath(Path.Combine(fullRoot, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        if (!path.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("download.invalid-local-path");
        return path;
    }

    public void Dispose()
    {
        for (var i = _parents.Count - 1; i >= 0; i--) _parents[i].Handle.Dispose();
        _parents.Clear();
    }
}
