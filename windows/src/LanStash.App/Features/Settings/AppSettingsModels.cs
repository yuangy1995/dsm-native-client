using LanStash.Domain;

namespace LanStash.App.Features.Settings;

public enum AppThemePreference
{
    System,
    Light,
    Dark,
}

public sealed record AppSettingsPreferences(
    AppThemePreference Theme,
    IReadOnlySet<AppModule> HiddenOptionalModules)
{
    public static AppSettingsPreferences Default { get; } = new(
        AppThemePreference.System,
        new HashSet<AppModule>());
}

public static class AppSettingsModulePolicy
{
    public static IReadOnlyList<AppModule> OptionalModules { get; } =
    [
        AppModule.Downloads,
        AppModule.Containers,
        AppModule.VirtualMachines,
        AppModule.NasSettings,
    ];

    public static bool CanHide(AppModule module) => OptionalModules.Contains(module);
}

public sealed class AppSettingsChangedEventArgs(bool moduleVisibilityChanged) : EventArgs
{
    public bool ModuleVisibilityChanged { get; } = moduleVisibilityChanged;
}
