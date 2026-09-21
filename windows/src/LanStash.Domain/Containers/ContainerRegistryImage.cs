namespace LanStash.Domain;

public sealed record ContainerRegistryImage(string Name, string Registry, string? Description, long? StarCount,
    bool? IsOfficial, bool? IsAutomated, bool? IsTrusted)
{
    public override string ToString() => nameof(ContainerRegistryImage);
}

public static class ContainerRegistryRules
{
    public const int SearchLimit = 50;
    public static bool IsValidQuery(string? value) => Valid(value, 200);
    public static bool IsValidRepository(string? value) => Valid(value, 500);
    private static bool Valid(string? value, int maximum) => !string.IsNullOrWhiteSpace(value) &&
        value.Trim().Length <= maximum && !value.Any(char.IsControl);
}
