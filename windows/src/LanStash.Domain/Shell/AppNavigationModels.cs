namespace LanStash.Domain;

public enum AppModule
{
    Files,
    Photos,
    Chat,
    Downloads,
    Containers,
    VirtualMachines,
    NasSettings,
    Transfers,
    Settings,
}

public enum AppLanguageSelection
{
    System,
    English,
    SimplifiedChinese,
}

public static class AppLanguageResolver
{
    public static string Resolve(
        AppLanguageSelection selection,
        string? primaryPreferredLanguage)
    {
        return selection switch
        {
            AppLanguageSelection.English => "en-US",
            AppLanguageSelection.SimplifiedChinese => "zh-CN",
            _ => ResolveSystemLanguage(primaryPreferredLanguage),
        };
    }

    public static string ResolveSystemLanguage(string? identifier)
    {
        if (string.IsNullOrWhiteSpace(identifier))
        {
            return "en-US";
        }
        var parts = identifier.Replace('_', '-')
            .Split('-', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (parts.Length == 0)
        {
            return "en-US";
        }
        if (string.Equals(parts[0], "en", StringComparison.OrdinalIgnoreCase))
        {
            return "en-US";
        }
        if (!string.Equals(parts[0], "zh", StringComparison.OrdinalIgnoreCase))
        {
            return "en-US";
        }
        if (parts.Any(part =>
                part.Equals("Hant", StringComparison.OrdinalIgnoreCase) ||
                part.Equals("TW", StringComparison.OrdinalIgnoreCase) ||
                part.Equals("HK", StringComparison.OrdinalIgnoreCase) ||
                part.Equals("MO", StringComparison.OrdinalIgnoreCase)))
        {
            return "en-US";
        }
        return parts.Any(part =>
                part.Equals("Hans", StringComparison.OrdinalIgnoreCase) ||
                part.Equals("CN", StringComparison.OrdinalIgnoreCase) ||
                part.Equals("SG", StringComparison.OrdinalIgnoreCase))
            ? "zh-CN"
            : "en-US";
    }
}

public static class AppModuleExtensions
{
    public static string Glyph(this AppModule module) => module switch
    {
        AppModule.Files => "\uE8B7",
        AppModule.Photos => "\uEB9F",
        AppModule.Chat => "\uE8BD",
        AppModule.Downloads => "\uE896",
        AppModule.Containers => "\uE7B8",
        AppModule.VirtualMachines => "\uE7F4",
        AppModule.NasSettings => "\uEDA2",
        AppModule.Transfers => "\uE898",
        AppModule.Settings => "\uE713",
        _ => "\uE946",
    };
}
