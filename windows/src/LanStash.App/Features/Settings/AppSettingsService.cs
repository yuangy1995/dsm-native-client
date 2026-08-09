using System.Security;
using LanStash.Domain;

namespace LanStash.App.Features.Settings;

public sealed class AppSettingsService
{
    public static AppSettingsService Current { get; } = new(new FileAppSettingsStore());

    private readonly IAppSettingsStore _store;
    private AppSettingsPreferences _preferences;

    internal AppSettingsService(IAppSettingsStore store)
    {
        _store = store;
        _preferences = LoadOrDefault(store);
    }

    public event EventHandler<AppSettingsChangedEventArgs>? Changed;
    public AppSettingsPreferences Preferences => _preferences;
    public RegenerableCacheCoordinator Caches { get; } = new();

    public bool IsModuleVisible(AppModule module) =>
        !AppSettingsModulePolicy.CanHide(module) ||
        !_preferences.HiddenOptionalModules.Contains(module);

    public bool SetTheme(AppThemePreference theme)
    {
        if (_preferences.Theme == theme)
        {
            return true;
        }
        var next = _preferences with { Theme = theme };
        if (!TrySave(next))
        {
            return false;
        }
        _preferences = next;
        Changed?.Invoke(this, new AppSettingsChangedEventArgs(false));
        return true;
    }

    public bool SetModuleVisible(AppModule module, bool isVisible)
    {
        if (!AppSettingsModulePolicy.CanHide(module))
        {
            return true;
        }
        var hidden = _preferences.HiddenOptionalModules.ToHashSet();
        var changed = isVisible ? hidden.Remove(module) : hidden.Add(module);
        if (!changed)
        {
            return true;
        }
        var next = _preferences with { HiddenOptionalModules = hidden };
        if (!TrySave(next))
        {
            return false;
        }
        _preferences = next;
        Changed?.Invoke(this, new AppSettingsChangedEventArgs(true));
        return true;
    }

    private static AppSettingsPreferences LoadOrDefault(IAppSettingsStore store)
    {
        try
        {
            return store.Load();
        }
        catch (Exception error) when (IsLocalStorageFailure(error))
        {
            return AppSettingsPreferences.Default;
        }
    }

    private bool TrySave(AppSettingsPreferences preferences)
    {
        try
        {
            return _store.Save(preferences);
        }
        catch (Exception error) when (IsLocalStorageFailure(error))
        {
            return false;
        }
    }

    private static bool IsLocalStorageFailure(Exception error) =>
        error is IOException or UnauthorizedAccessException or SecurityException;
}
