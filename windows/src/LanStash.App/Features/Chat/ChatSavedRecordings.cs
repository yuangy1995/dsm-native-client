using System.Runtime.InteropServices;
using LanStash.App.CloudDrive;
using LanStash.App.Features.Transfers;
using Microsoft.Win32.SafeHandles;

namespace LanStash.App.Features.Chat;

internal sealed record ChatSavedRecording(string Path, ulong Volume, ulong FileLow, ulong FileHigh,
    long Length, long Modified, long Changed, DateTimeOffset Created);
internal sealed record ChatSavedRecordingList(IReadOnlyList<ChatSavedRecording> Items, int UnavailableCount);
internal interface IChatSavedRecordings
{
    Task<ChatSavedRecordingList> ListAsync(IReadOnlySet<string> protectedPaths, CancellationToken token = default);
    Task ExportAsync(ChatSavedRecording expected, string destination, IReadOnlySet<string> protectedPaths, CancellationToken token = default);
    void Discard(ChatSavedRecording expected, IReadOnlySet<string> protectedPaths);
}

/// <summary>只管理已有随机录音文件，不建立账号索引、不恢复发送，也不参与缓存清理。</summary>
internal sealed class ChatSavedRecordings(string directory) : IChatSavedRecordings
{
    private readonly string _directory = Path.GetFullPath(directory);

    public Task<ChatSavedRecordingList> ListAsync(IReadOnlySet<string> protectedPaths, CancellationToken token = default) => Task.Run(() =>
    {
        if (!Directory.Exists(_directory)) return new ChatSavedRecordingList([], 0);
        using var parent = ForegroundDownloadDirectoryLease.Acquire(_directory);
        var items = new List<ChatSavedRecording>(); var unavailable = 0;
        foreach (var path in Directory.EnumerateFiles(_directory, "*.m4a", SearchOption.TopDirectoryOnly))
        {
            token.ThrowIfCancellationRequested();
            if (!IsOwnedName(path) || protectedPaths.Contains(path)) continue;
            try
            {
                using var handle = Open(path, delete: false);
                var item = Read(handle, path);
                if (item.Length > 0) items.Add(item);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { unavailable++; }
        }
        parent.Validate();
        return new ChatSavedRecordingList(items.OrderByDescending(item => item.Created).ToArray(), unavailable);
    }, token);

    public async Task ExportAsync(ChatSavedRecording expected, string destination, IReadOnlySet<string> protectedPaths,
        CancellationToken token = default)
    {
        EnsureTarget(expected, protectedPaths);
        if (string.Equals(Path.GetFullPath(destination), expected.Path, StringComparison.OrdinalIgnoreCase))
            throw new IOException("chat.voice.same-copy");
        using var parent = ForegroundDownloadDirectoryLease.Acquire(_directory);
        using var handle = Open(expected.Path, delete: false);
        if (Read(handle, expected.Path) != expected) throw new IOException("chat.voice.copy-changed");
        using var source = new FileStream(handle, FileAccess.Read);
        using var destinationParent = ForegroundDownloadDirectoryLease.Acquire(Path.GetDirectoryName(Path.GetFullPath(destination))!);
        await using var output = await WindowsTransactionalDownloadDestination.CreateAsync(destination, validateTarget: destinationParent.Validate);
        var buffer = new byte[64 * 1024]; int count;
        while ((count = await source.ReadAsync(buffer, token).ConfigureAwait(false)) > 0)
            await output.WriteAsync(buffer.AsMemory(0, count), token).ConfigureAwait(false);
        parent.Validate();
        if (Read(handle, expected.Path) != expected) throw new IOException("chat.voice.copy-changed");
        await output.CommitAsync(token).ConfigureAwait(false);
    }

    public void Discard(ChatSavedRecording expected, IReadOnlySet<string> protectedPaths)
    {
        EnsureTarget(expected, protectedPaths);
        using var parent = ForegroundDownloadDirectoryLease.Acquire(_directory);
        using var handle = Open(expected.Path, delete: true);
        if (Read(handle, expected.Path) != expected) throw new IOException("chat.voice.copy-changed");
        parent.Validate();
        // 删除仍持有的原文件，不能通过名称删除被替换后的另一个文件。
        var disposition = new FileDisposition { Delete = 1 };
        if (!SetDisposition(handle, 4, ref disposition, (uint)Marshal.SizeOf<FileDisposition>()))
            throw new IOException("chat.voice.copy-delete-failed");
    }

    private void EnsureTarget(ChatSavedRecording expected, IReadOnlySet<string> protectedPaths)
    {
        if (!IsOwnedName(expected.Path) || !string.Equals(Path.GetDirectoryName(Path.GetFullPath(expected.Path)), _directory, StringComparison.OrdinalIgnoreCase) ||
            protectedPaths.Contains(expected.Path)) throw new IOException("chat.voice.copy-unavailable");
    }

    private static bool IsOwnedName(string path) => Path.GetExtension(path).Equals(".m4a", StringComparison.OrdinalIgnoreCase) &&
        Guid.TryParseExact(Path.GetFileNameWithoutExtension(path), "N", out _);

    private static SafeFileHandle Open(string path, bool delete) => CloudFilesInterop.CreateFile(path,
        CloudFilesInterop.GenericRead | (delete ? 0x00010000u : 0u), 1u, IntPtr.Zero, CloudFilesInterop.OpenExisting,
        CloudFilesInterop.FileFlagOpenReparsePoint, IntPtr.Zero);

    private static ChatSavedRecording Read(SafeFileHandle handle, string path)
    {
        if (handle.IsInvalid || !GetIdentity(handle, 18, out var identity, 24) ||
            !CloudFilesInterop.GetFileBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<CloudFilesInterop.FileBasicInfo>()) ||
            !CloudFilesInterop.GetFileStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<CloudFilesInterop.FileStandardInfo>()) ||
            standard.Directory != 0 || standard.EndOfFile < 0 ||
            (basic.FileAttributes & (uint)(FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
            throw new IOException("chat.voice.copy-unavailable");
        return new(path, identity.Volume, identity.Low, identity.High, standard.EndOfFile,
            basic.LastWriteTime, basic.ChangeTime, DateTimeOffset.FromFileTime(basic.CreationTime));
    }

    [StructLayout(LayoutKind.Sequential)] private readonly record struct FileIdentity(ulong Volume, ulong Low, ulong High);
    [StructLayout(LayoutKind.Sequential)] private struct FileDisposition { public byte Delete; }
    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetIdentity(SafeFileHandle handle, int informationClass, out FileIdentity identity, uint size);
    [DllImport("kernel32.dll", EntryPoint = "SetFileInformationByHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetDisposition(SafeFileHandle handle, int informationClass, ref FileDisposition disposition, uint size);
}
