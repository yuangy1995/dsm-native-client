namespace LanStash.Domain;

public static class FileVfsPath
{
    public static string Root(FileVfsProfile profile) => profile.Uri.TrimEnd('/');
    public static bool Contains(FileVfsProfile profile, string path)
    {
        var root = Root(profile);
        return root.Length > profile.Protocol.Length + 3 && root.StartsWith(profile.Protocol + "://", StringComparison.Ordinal) &&
            !path.Any(char.IsControl) && !path.Contains('\\') &&
            (path == root || path.StartsWith(root + "/", StringComparison.Ordinal)) &&
            !path[root.Length..].Split('/').Any(segment => segment is "." or "..");
    }
    public static bool IsChild(FileVfsProfile profile, string parent, string path) => Contains(profile, parent) && Contains(profile, path) &&
        path.StartsWith(parent.TrimEnd('/') + "/", StringComparison.Ordinal) &&
        path[(parent.TrimEnd('/').Length + 1)..] is { Length: > 0 } tail && !tail.Contains('/');
}

public sealed record FileVfsFolder(FileVfsProfile Profile, string Path, IReadOnlyList<FileItem> Items)
{
    public override string ToString() => nameof(FileVfsFolder);
}
public sealed record FileVfsDownloadSource(FileVfsProfile Profile, string Parent, FileItem File)
{
    public bool IsValid => Profile.State == FileVfsState.Connected && !File.IsDirectory && File.Size >= 0 &&
        !string.IsNullOrWhiteSpace(File.Name) && !File.Name.Any(char.IsControl) && !File.Name.Contains('/') && !File.Name.Contains('\\') &&
        FileVfsPath.IsChild(Profile, Parent, File.Path);
    public override string ToString() => nameof(FileVfsDownloadSource);
}
public interface IFileVfsBrowserRepository : IFileVfsRepository
{
    bool CanBrowseVfs { get; }
    bool CanDownloadVfs { get; }
    Task<FileVfsFolder> ListVfsFolderAsync(FileVfsProfile profile, string path, CancellationToken cancellationToken = default);
    Task ValidateVfsDownloadAsync(FileVfsDownloadSource source, CancellationToken cancellationToken = default);
    Task<FileRangeReadResult> ReadVfsRangeAsync(FileVfsDownloadSource source, long offset, long length,
        string? expectedContentVersion = null, CancellationToken cancellationToken = default);
}

// 原 URI 仅进入只读下载来源，不放宽普通 NAS 文件写路径。
public sealed class FileVfsRangeReader(IFileVfsBrowserRepository repository, FileVfsDownloadSource source) : IFileRangeReader
{
    public Task<FileRangeReadResult> ReadFileRangeResultAsync(string remotePath, long offset, long length,
        string? expectedContentVersion = null, long? expectedTotalLength = null, CancellationToken cancellationToken = default)
    {
        if (remotePath != source.File.Path || expectedTotalLength != source.File.Size || !source.IsValid)
            throw new ArgumentException("file.vfs.download-changed");
        return repository.ReadVfsRangeAsync(source, offset, length, expectedContentVersion, cancellationToken);
    }
}
