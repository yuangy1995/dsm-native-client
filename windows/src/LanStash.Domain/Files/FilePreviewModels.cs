namespace LanStash.Domain;

public enum FilePreviewKind
{
    Unsupported,
    Text,
    Image,
    Pdf,
    Audio,
    Video,
}

public enum FileTextEditState
{
    Viewing,
    Editing,
    Saving,
    SaveCompleted,
    SaveNeedsReview,
    SaveFailed,
}

public enum TextFormatKind
{
    Json,
    Xml,
    JavaScript,
    TypeScript,
    Css,
}

public sealed record FileTextEditAvailability(
    bool CanEdit,
    bool CanFormat,
    IReadOnlyList<string> SupportedExtensions);

public sealed record FileTextContentSnapshot(
    string Text,
    long ByteLength,
    string ContentVersion,
    string Sha256);

public static class FileTextEditClassification
{
    private static readonly HashSet<string> TextEditExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "txt", "json", "geojson", "xml", "js", "ts", "jsx", "tsx",
        "css", "scss", "html", "htm", "md", "yaml", "yml",
        "sh", "py", "rb", "cs", "swift", "kt", "java",
        "c", "cpp", "h", "hpp", "sql", "conf", "ini", "cfg", "log", "csv", "toml",
    };

    private static readonly HashSet<string> FormatExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        "json", "xml", "js", "ts", "jsx", "tsx", "css",
    };

    public static bool CanEditSelectedText(string extension) =>
        !string.IsNullOrWhiteSpace(extension) &&
        TextEditExtensions.Contains(extension.TrimStart('.'));

    public static bool CanFormatSelectedText(string extension) =>
        !string.IsNullOrWhiteSpace(extension) &&
        FormatExtensions.Contains(extension.TrimStart('.'));

    public static TextFormatKind? FormatKindForExtension(string extension)
    {
        var ext = extension.TrimStart('.').ToLowerInvariant();
        return ext switch
        {
            "json" or "geojson" => TextFormatKind.Json,
            "xml" => TextFormatKind.Xml,
            "js" or "jsx" => TextFormatKind.JavaScript,
            "ts" or "tsx" => TextFormatKind.TypeScript,
            "css" or "scss" => TextFormatKind.Css,
            _ => null,
        };
    }
}

public sealed record FilePreviewTarget(
    Guid ProfileId,
    FileItem Item,
    FilePreviewKind Kind);
