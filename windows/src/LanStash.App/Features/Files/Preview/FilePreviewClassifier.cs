using LanStash.Domain;

namespace LanStash.App.Features.Files.Preview;

public static class FilePreviewClassifier
{
    public const int TextPreviewByteLimit = 512 * 1024;
    public const long DocumentPreviewByteLimit = 128L * 1024 * 1024;

    private static readonly HashSet<string> TextExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "txt", "md", "markdown", "json", "xml", "yaml", "yml", "log", "csv", "tsv",
        "swift", "kt", "kts", "java", "cs", "js", "tsx", "jsx", "html", "css",
        "py", "rb", "go", "rs", "sh", "zsh", "ini", "conf", "toml",
    };

    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp",
    };

    private static readonly HashSet<string> AudioExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "mp3", "wav", "m4a", "aac", "wma",
    };

    private static readonly HashSet<string> VideoExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "mp4", "m4v", "mov", "avi", "wmv", "mkv", "webm",
    };

    public static FilePreviewKind Classify(FileItem item)
    {
        ArgumentNullException.ThrowIfNull(item);
        if (item.IsDirectory)
        {
            return FilePreviewKind.Unsupported;
        }

        var extension = Path.GetExtension(item.Name).TrimStart('.');
        if (string.IsNullOrWhiteSpace(extension) ||
            string.Equals(extension, "ts", StringComparison.OrdinalIgnoreCase))
        {
            return FilePreviewKind.Unsupported;
        }
        if (TextExtensions.Contains(extension))
        {
            return FilePreviewKind.Text;
        }
        if (ImageExtensions.Contains(extension))
        {
            return FilePreviewKind.Image;
        }
        if (string.Equals(extension, "pdf", StringComparison.OrdinalIgnoreCase))
        {
            return FilePreviewKind.Pdf;
        }
        if (AudioExtensions.Contains(extension))
        {
            return FilePreviewKind.Audio;
        }
        return VideoExtensions.Contains(extension)
            ? FilePreviewKind.Video
            : FilePreviewKind.Unsupported;
    }

    public static string SafeExtension(FileItem item)
    {
        var extension = Path.GetExtension(item.Name).TrimStart('.').ToLowerInvariant();
        return Classify(item) == FilePreviewKind.Unsupported ? string.Empty : extension;
    }

    public static string MediaContentType(FileItem item, FilePreviewKind kind)
    {
        var extension = SafeExtension(item);
        return (kind, extension) switch
        {
            (FilePreviewKind.Audio, "mp3") => "audio/mpeg",
            (FilePreviewKind.Audio, "wav") => "audio/wav",
            (FilePreviewKind.Audio, "m4a") => "audio/mp4",
            (FilePreviewKind.Audio, "aac") => "audio/aac",
            (FilePreviewKind.Audio, "wma") => "audio/x-ms-wma",
            (FilePreviewKind.Video, "mp4" or "m4v") => "video/mp4",
            (FilePreviewKind.Video, "mov") => "video/quicktime",
            (FilePreviewKind.Video, "avi") => "video/x-msvideo",
            (FilePreviewKind.Video, "wmv") => "video/x-ms-wmv",
            (FilePreviewKind.Video, "mkv") => "video/x-matroska",
            (FilePreviewKind.Video, "webm") => "video/webm",
            _ => throw new InvalidOperationException("The file is not an allowed media preview type."),
        };
    }
}
