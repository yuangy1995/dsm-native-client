namespace LanStash.Domain;

public enum FileArchiveCompressionSourceKind
{
    Local,
    Remote,
    Virtual,
    Recycle,
}

public sealed record FileArchiveCompressionSource(
    FileItem Item,
    FileArchiveCompressionSourceKind SourceKind = FileArchiveCompressionSourceKind.Local,
    bool CanRead = true);

public sealed record FileArchiveCompressionAvailability(
    bool CanCompress,
    int? CompressVersion = null,
    int? ListVersion = null,
    int? CheckPermissionVersion = null)
{
    public bool IsAvailable => CanCompress;
}

public sealed record FileArchiveCompressionRequest(
    Guid ProfileId,
    IReadOnlyList<FileArchiveCompressionSource> Sources,
    string DestinationName)
{
    public FileArchiveCompressionOptions Options { get; init; } = new();
    public override string ToString() => nameof(FileArchiveCompressionRequest);
}

public enum FileArchiveFormat { Zip, SevenZip }
public enum FileArchiveCompressionLevel { Moderate, Store, Fastest, Best }

public sealed record FileArchiveCompressionOptions(
    FileArchiveFormat Format = FileArchiveFormat.Zip,
    FileArchiveCompressionLevel Level = FileArchiveCompressionLevel.Moderate,
    string? Password = null)
{
    public bool IsValid => Enum.IsDefined(Format) && Enum.IsDefined(Level);
    public string FormatValue => Format == FileArchiveFormat.SevenZip ? "7z" : "zip";
    public string LevelValue => Level switch
    {
        FileArchiveCompressionLevel.Store => "store",
        FileArchiveCompressionLevel.Fastest => "fastest",
        FileArchiveCompressionLevel.Best => "best",
        _ => "moderate",
    };
    public override string ToString() => nameof(FileArchiveCompressionOptions);

    public bool TryNormalizeName(string? value, out string name)
    {
        name = string.Empty;
        if (!IsValid || string.IsNullOrWhiteSpace(value) || value != value.Trim()) return false;
        while (value.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || value.EndsWith(".7z", StringComparison.OrdinalIgnoreCase))
            value = value[..value.LastIndexOf('.')];
        if (string.IsNullOrWhiteSpace(value) || value != value.Trim() || value is "." or ".." ||
            value.IndexOfAny(['/', '\\']) >= 0 || value.Any(char.IsControl)) return false;
        name = value + "." + FormatValue;
        return name.Length <= 255;
    }
}

public sealed record FileArchiveCompressionOutcome(
    MutationResult Result,
    FileItem? ConfirmedItem = null);
