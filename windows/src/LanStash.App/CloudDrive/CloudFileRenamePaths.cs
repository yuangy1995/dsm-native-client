using System.Runtime.InteropServices;

namespace LanStash.App.CloudDrive;

internal static class CloudFileRenamePaths
{
    // File.Exists 不区分大小写；只接受目录实际记录的叶名称，避免尚未改名就完成日志。
    internal static bool HasExactLeafName(string path)
    {
        var full = Path.GetFullPath(path);
        var parent = Path.GetDirectoryName(full) ?? throw new InvalidDataException("cloud.relocate.invalid_path");
        var leaf = Path.GetFileName(full);
        return Directory.EnumerateFileSystemEntries(parent, leaf).Any(entry => Path.GetFileName(entry).Equals(leaf, StringComparison.Ordinal));
    }

    internal static void CompleteLocalMove(string source, string target, bool isDirectory, bool moveLocal, Action<string> verifyIdentity)
    {
        if (!HasExactLeafName(target) && moveLocal)
        {
            verifyIdentity(source);
            if (isDirectory) Directory.Move(source, target); else File.Move(source, target);
        }
        if (!HasExactLeafName(target)) throw new InvalidDataException("cloud.relocate.local_unverified");
        verifyIdentity(target);
    }

    internal static (string Target, bool Directory) Read(in CloudFilesInterop.CallbackInfo info, IntPtr parameters, string localRoot)
    {
        if (parameters == IntPtr.Zero || Marshal.ReadInt32(parameters) < 24) throw new InvalidDataException("cloud.relocate.invalid_callback");
        var value = Marshal.PtrToStructure<CloudFilesInterop.RenameCallbackParameters>(parameters);
        if ((value.Flags & 6) != 6 || (value.Flags & ~7u) != 0) throw new InvalidDataException("cloud.relocate.outside_mapping");
        var drive = Marshal.PtrToStringUni(info.VolumeDosName);
        var relative = Marshal.PtrToStringUni(value.Path);
        return (ResolveTarget(drive, relative, localRoot), (value.Flags & 1) != 0);
    }

    internal static string ResolveTarget(string? drive, string? volumeRelativePath, string localRoot)
    {
        if (drive is not { Length: 2 } || !char.IsAsciiLetter(drive[0]) || drive[1] != ':' ||
            string.IsNullOrWhiteSpace(volumeRelativePath) || !volumeRelativePath.StartsWith('\\') || volumeRelativePath.StartsWith("\\\\", StringComparison.Ordinal) ||
            volumeRelativePath.Contains(':') || volumeRelativePath.Contains('/') || volumeRelativePath.Any(char.IsControl) ||
            volumeRelativePath.Split('\\').Any(part => part is "." or "..")) throw new InvalidDataException("cloud.relocate.invalid_callback");
        var result = System.IO.Path.GetFullPath(drive + volumeRelativePath);
        var root = System.IO.Path.GetFullPath(localRoot).TrimEnd(System.IO.Path.DirectorySeparatorChar);
        if (!result.StartsWith(root + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("cloud.relocate.outside_mapping");
        return result;
    }
}
