namespace LanStash.Domain;

public sealed record FileArchiveExtractionSource(
    FileItem Item,
    FileArchiveCompressionSourceKind SourceKind = FileArchiveCompressionSourceKind.Local,
    bool CanRead = true);

public sealed record FileArchiveExtractionAvailability(
    bool CanExtract,
    int? ExtractVersion = null,
    int? ListVersion = null)
{
    public bool IsAvailable => CanExtract;
}

public sealed record FileArchiveExtractionRequest(
    Guid ProfileId,
    FileArchiveExtractionSource Source,
    string DestinationFolder)
{
    public FileArchiveExtractionOptions Options { get; init; } = new();
    public bool OverwriteConfirmed { get; init; }
    public override string ToString() => nameof(FileArchiveExtractionRequest);
}

public sealed record FileArchiveExtractionOptions(string? Password = null, string? Codepage = null)
{
    public static bool IsSupportedArchive(string name) =>
        new[] { ".zip", ".gz", ".tar", ".tgz", ".tbz", ".bz2", ".rar", ".7z", ".iso" }
            .Contains(Path.GetExtension(name), StringComparer.OrdinalIgnoreCase);
    public bool KeepDirectoryStructure { get; init; } = true;
    public bool CreateSubfolder { get; init; }
    public bool Overwrite { get; init; }
    public bool IsValid => Codepage is null or "enu" or "cht" or "chs" or "krn" or "ger" or "fre" or "ita" or
        "spn" or "jpn" or "dan" or "nor" or "sve" or "nld" or "rus" or "plk" or "ptb" or "ptg" or "hun" or "trk" or "csy";
    public override string ToString() => nameof(FileArchiveExtractionOptions);

    // 与 macOS 基线一致，只在出现乱码线索时比较中文旧编码，不按界面语言强制改写。
    public static int NamePenalty(IEnumerable<string> names)
    {
        var score = 0;
        foreach (var name in names)
        {
            score += name.Count(character => character == '\uFFFD' || character is >= '\u00C0' and <= '\u024F') * 3;
            foreach (var suspicious in new[] { "Ã", "Â", "Ð", "æ", "å", "ç", "ï¿½", "¤", "¦", "¨" })
                if (name.Contains(suspicious, StringComparison.Ordinal)) score += 5;
        }
        return score;
    }
}

public sealed record FileArchiveExtractionOutcome(
    MutationResult Result,
    IReadOnlyList<FileItem>? ConfirmedItems = null);
