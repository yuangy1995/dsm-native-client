using LanStash.Domain;

namespace LanStash.App.CloudDrive;

/// 全部共享只开放共享内部；挂载根和共享根不属于普通文件操作。
internal static class CloudDriveWriteScope
{
    internal static bool CanEnable(DesktopDriveMapping mapping) => mapping.Scope.Kind switch
    {
        DesktopDriveScopeKind.AllShares => mapping.Scope.FolderPath is null,
        DesktopDriveScopeKind.Folder => DesktopDrivePath.Normalize(mapping.Scope.FolderPath) is { } root && root != "/" && !Protected(root),
        _ => false,
    };

    internal static string Root(DesktopDriveMapping mapping) => !CanEnable(mapping)
        ? throw new InvalidDataException("cloud.sync.invalid_path")
        : mapping.Scope.Kind == DesktopDriveScopeKind.AllShares ? "/" : DesktopDrivePath.Normalize(mapping.Scope.FolderPath)!;

    internal static bool CanWrite(DesktopDriveMapping mapping, string? path)
    {
        if (!CanEnable(mapping) || string.IsNullOrWhiteSpace(path) || DesktopDrivePath.Normalize(path) != path || path.Count(character => character == '/') < 2 ||
            path.Contains('\\') || path.Any(char.IsControl) || Protected(path)) return false;
        var root = Root(mapping);
        return path != root && DesktopDrivePath.IsAncestorOrSame(root, path);
    }

    internal static void RequireWritable(DesktopDriveMapping mapping, string path)
    {
        if (!CanWrite(mapping, path)) throw new InvalidDataException("cloud.sync.invalid_path");
    }

    private static bool Protected(string path) => path.Split('/').Any(part => part.Equals("#recycle", StringComparison.OrdinalIgnoreCase));
}
