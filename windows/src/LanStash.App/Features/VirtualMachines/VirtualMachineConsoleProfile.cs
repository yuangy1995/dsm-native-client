namespace LanStash.App.Features.VirtualMachines;

/// <summary>只清理当前窗口创建的随机缓存目录，不枚举或删除其他窗口目录。</summary>
public sealed class VirtualMachineConsoleProfile
{
    private static readonly string Root = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "LanStash", "VirtualMachineConsole"));
    [System.Text.Json.Serialization.JsonIgnore] public string DirectoryPath { get; }
    private VirtualMachineConsoleProfile(string path) => DirectoryPath = path;
    public static VirtualMachineConsoleProfile Create()
    {
        Directory.CreateDirectory(Root);
        if (HasRedirectedParent()) throw new IOException("vm.console.cache_redirected");
        var path = Path.Combine(Root, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(path);
        return new(path);
    }
    public bool Matches(string path) => string.Equals(Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar), DirectoryPath, StringComparison.OrdinalIgnoreCase);
    public bool TryDelete()
    {
        try
        {
            if (!Directory.Exists(DirectoryPath)) return true;
            if (HasRedirectedParent() || Path.GetDirectoryName(Path.GetFullPath(DirectoryPath)) != Root ||
                !Guid.TryParseExact(Path.GetFileName(DirectoryPath), "N", out _)) return false;
            var directory = new DirectoryInfo(DirectoryPath);
            Directory.Delete(DirectoryPath, recursive: !directory.Attributes.HasFlag(FileAttributes.ReparsePoint));
            return true;
        }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }
    private static bool HasRedirectedParent() => new DirectoryInfo(Root).Attributes.HasFlag(FileAttributes.ReparsePoint) ||
        new DirectoryInfo(Root).Parent!.Attributes.HasFlag(FileAttributes.ReparsePoint);
    public override string ToString() => nameof(VirtualMachineConsoleProfile);
}
