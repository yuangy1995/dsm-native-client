namespace LanStash.Domain;

public enum FileStationThemeImageKind { Logo, Background }
public enum FileStationThemeImageSource { Nas, History, Default }
public enum FileStationLogoPosition { TopRight, TopLeft, BottomRight, BottomLeft }
public enum FileStationBackgroundPosition { Center, Fill, Fit, Stretch, Tile }
public sealed record FileStationThemeImage(FileStationThemeImageKind Kind, FileStationThemeImageSource Source, string Path, string Name, int? HistoryIndex = null)
{
    public static bool SupportsFilename(string name) => System.IO.Path.GetExtension(name).ToLowerInvariant() is ".jpg" or ".jpeg" or ".jpe" or ".gif" or ".bmp" or ".png";
    public bool IsValid => Enum.IsDefined(Kind) && Enum.IsDefined(Source) && !string.IsNullOrEmpty(Name) && SupportsFilename(Path) &&
        !Path.Any(c => char.IsControl(c) || c == '\\') && !Path.Split('/').Any(c => c is "." or "..") &&
        (Source != FileStationThemeImageSource.Nas || Path.StartsWith('/')) &&
        (Source != FileStationThemeImageSource.Default || Kind == FileStationThemeImageKind.Background && Defaults.Any(v => v.Path == Path));
    public static IReadOnlyList<FileStationThemeImage> Defaults => Enumerable.Range(1, 10).Select(i => new FileStationThemeImage(
        FileStationThemeImageKind.Background, FileStationThemeImageSource.Default, $"dsm7_0{i}.jpg", $"dsm7_0{i}.jpg")).ToArray();
    public override string ToString() => nameof(FileStationThemeImage);
}
public sealed record FileStationTheme(Guid ProfileId, bool CustomLogo, FileStationLogoPosition LogoPosition,
    bool CustomBackground, FileStationBackgroundPosition BackgroundPosition, string BackgroundColor, string Footer, bool FooterUsesHtml,
    string? LogoSequence, string? BackgroundSequence, FileStationThemeImage? LogoImage = null, FileStationThemeImage? BackgroundImage = null) : FileStationSetting(ProfileId)
{
    public override string Target => "theme";
    public override bool IsValid => base.IsValid && Enum.IsDefined(LogoPosition) && Enum.IsDefined(BackgroundPosition) &&
        BackgroundColor.Length == 7 && BackgroundColor[0] == '#' && BackgroundColor.AsSpan(1).ToArray().All(char.IsAsciiHexDigit) &&
        Footer.Length <= 512 && !Footer.Contains('\r') && !Footer.Contains('\n') &&
        (LogoImage is null || CustomLogo && LogoImage is { IsValid: true, Kind: FileStationThemeImageKind.Logo }) &&
        (BackgroundImage is null || CustomBackground && BackgroundImage is { IsValid: true, Kind: FileStationThemeImageKind.Background });
    public bool SameLayout(FileStationTheme other) => this with { LogoSequence = other.LogoSequence, BackgroundSequence = other.BackgroundSequence,
        LogoImage = other.LogoImage, BackgroundImage = other.BackgroundImage } == other;
}
public sealed record FileStationThemeUploadResult(MutationResult Outcome, FileStationThemeImage? Image = null)
{
    public override string ToString() => nameof(FileStationThemeUploadResult);
}
public sealed record FileStationThemeUploadTransportResult(bool Submitted, bool Accepted, string? Path = null, MutationErrorCategory? Error = null)
{ public override string ToString() => nameof(FileStationThemeUploadTransportResult); }
public interface IFileStationThemeRepository : IFileStationSettingsRepository
{
    Task<FileStationTheme> LoadFileStationThemeAsync(CancellationToken token = default);
    Task<IReadOnlyList<FileStationThemeImage>> ListFileStationThemeImagesAsync(FileStationThemeImageKind kind, CancellationToken token = default);
    Task<byte[]> ReadFileStationThemeImageAsync(FileStationThemeImage image, CancellationToken token = default);
    Task<FileStationThemeUploadResult> UploadFileStationThemeImageAsync(FileStationThemeImageKind kind, string filename, ReadOnlyMemory<byte> content, bool confirmed, CancellationToken token = default);
}
