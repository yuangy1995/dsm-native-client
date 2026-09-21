namespace LanStash.Domain;

public static class FileArchivePaths
{
    public static bool IsValid(string? path) => !string.IsNullOrWhiteSpace(path) && path.StartsWith('/') && path != "/" &&
        !path.EndsWith('/') && !path.Contains("//", StringComparison.Ordinal) && !path.Contains('\\') && !path.Any(char.IsControl) &&
        !path.Split('/').Any(part => part is "." or "..");

    public static bool IsValidSelection(IReadOnlyList<string> paths) => paths.Count > 0 &&
        paths.All(IsValid) && paths.Distinct(StringComparer.Ordinal).Count() == paths.Count;
}
