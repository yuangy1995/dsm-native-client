using System.Security;
using System.Text.Json;
using LanStash.Domain;

namespace LanStash.App.Features.Settings;

internal interface IAppSettingsStore
{
    AppSettingsPreferences Load();
    bool Save(AppSettingsPreferences preferences);
}

internal sealed class FileAppSettingsStore : IAppSettingsStore
{
    private readonly string _path;

    public FileAppSettingsStore(string? path = null) =>
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "LanStash",
            "settings.json");

    public AppSettingsPreferences Load()
    {
        try
        {
            if (!File.Exists(_path))
            {
                return AppSettingsPreferences.Default;
            }
            var stored = JsonSerializer.Deserialize<StoredSettings>(File.ReadAllText(_path));
            var theme = Enum.TryParse<AppThemePreference>(stored?.Theme, true, out var parsedTheme) &&
                Enum.IsDefined(parsedTheme)
                ? parsedTheme
                : AppThemePreference.System;
            var hidden = (stored?.HiddenOptionalModules ?? [])
                .Select(value => Enum.TryParse<AppModule>(value, true, out var module)
                    ? module
                    : (AppModule?)null)
                .OfType<AppModule>()
                .Where(AppSettingsModulePolicy.CanHide)
                .ToHashSet();
            return new AppSettingsPreferences(theme, hidden);
        }
        catch (JsonException)
        {
            return AppSettingsPreferences.Default;
        }
        catch (IOException)
        {
            return AppSettingsPreferences.Default;
        }
        catch (UnauthorizedAccessException)
        {
            return AppSettingsPreferences.Default;
        }
        catch (SecurityException)
        {
            return AppSettingsPreferences.Default;
        }
    }

    public bool Save(AppSettingsPreferences preferences)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var stored = new StoredSettings(
                preferences.Theme.ToString(),
                preferences.HiddenOptionalModules
                    .Where(AppSettingsModulePolicy.CanHide)
                    .OrderBy(module => module)
                    .Select(module => module.ToString())
                    .ToArray());
            File.WriteAllText(_path, JsonSerializer.Serialize(stored));
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
        catch (SecurityException)
        {
            return false;
        }
    }

    private sealed record StoredSettings(string? Theme, string[]? HiddenOptionalModules);
}
