using System.Globalization;
using System.Security;
using LanStash.Domain;
using Microsoft.Windows.ApplicationModel.Resources;
using Windows.Globalization;
using Windows.System.UserProfile;

namespace LanStash.App.Localization;

public sealed record LanguageChoice(AppLanguageSelection Value, string DisplayName);

internal interface ILanguagePreferenceStore
{
    AppLanguageSelection? Load();
    bool Save(AppLanguageSelection selection);
}

internal interface ILocalizationPlatform
{
    string? SystemLanguage { get; }
    void ApplyLanguage(string language);
    string? GetString(string key);
}

internal sealed class WinUiLocalizationPlatform : ILocalizationPlatform
{
    public string? SystemLanguage => GlobalizationPreferences.Languages.FirstOrDefault();

    public void ApplyLanguage(string language) =>
        ApplicationLanguages.PrimaryLanguageOverride = language;

    public string? GetString(string key) => new ResourceLoader().GetString(key);
}

internal sealed class FileLanguagePreferenceStore(string path) : ILanguagePreferenceStore
{
    public AppLanguageSelection? Load()
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }
            return Enum.TryParse<AppLanguageSelection>(
                    File.ReadAllText(path),
                    ignoreCase: true,
                    out var saved) &&
                Enum.IsDefined(saved)
                ? saved
                : null;
        }
        catch (Exception error) when (IsLocalStorageFailure(error))
        {
            return null;
        }
    }

    public bool Save(AppLanguageSelection selection)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, selection.ToString());
            return true;
        }
        catch (Exception error) when (IsLocalStorageFailure(error))
        {
            return false;
        }
    }

    private static bool IsLocalStorageFailure(Exception error) =>
        error is IOException or UnauthorizedAccessException or SecurityException;
}

public sealed class LocalizationService
{
    public static LocalizationService Current { get; private set; } = new();

    private readonly ILanguagePreferenceStore _preferenceStore;
    private readonly ILocalizationPlatform _platform;

    public event EventHandler? LanguageChanged;
    public AppLanguageSelection Selection { get; private set; } = AppLanguageSelection.System;
    public string ResolvedLanguage { get; private set; } = "en-US";

    private LocalizationService() : this(
        new FileLanguagePreferenceStore(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "LanStash",
            "language.txt")),
        new WinUiLocalizationPlatform())
    {
    }

    internal LocalizationService(
        ILanguagePreferenceStore preferenceStore,
        ILocalizationPlatform platform)
    {
        _preferenceStore = preferenceStore;
        _platform = platform;
    }

    public void Initialize()
    {
        try
        {
            var saved = _preferenceStore.Load();
            Selection = saved is { } value && Enum.IsDefined(value)
                ? value
                : AppLanguageSelection.System;
        }
        catch (Exception error) when (IsLocalStorageFailure(error))
        {
            Selection = AppLanguageSelection.System;
        }
        ApplySelection();
    }

    public void SetSelection(AppLanguageSelection selection)
    {
        _ = TrySetSelection(selection);
    }

    public bool TrySetSelection(AppLanguageSelection selection)
    {
        if (Selection == selection)
        {
            return true;
        }
        try
        {
            if (!_preferenceStore.Save(selection))
            {
                return false;
            }
        }
        catch (Exception error) when (IsLocalStorageFailure(error))
        {
            return false;
        }
        Selection = selection;
        ApplySelection();
        LanguageChanged?.Invoke(this, EventArgs.Empty);
        return true;
    }

    public string Get(string key)
    {
        var value = _platform.GetString(key);
        return string.IsNullOrEmpty(value) ? key : value;
    }

    internal static void UseForTests(LocalizationService service) => Current = service;

    public string Format(string key, params object[] arguments) =>
        string.Format(CultureInfo.CurrentCulture, Get(key), arguments);

    public string ResolveUserText(string value) =>
        value.StartsWith(UserText.ResourcePrefix, StringComparison.Ordinal)
            ? Get(value[UserText.ResourcePrefix.Length..])
            : value;

    public string ErrorMessage(DsmException error) =>
        $"{ResolveUserText(error.Message)} {ResolveUserText(error.Recovery)}";

    public IReadOnlyList<LanguageChoice> Choices() =>
    [
        new(AppLanguageSelection.System, Get("LanguageFollowSystem")),
        new(AppLanguageSelection.English, Get("LanguageEnglish")),
        new(AppLanguageSelection.SimplifiedChinese, Get("LanguageSimplifiedChinese")),
    ];

    public string ModuleTitle(AppModule module) => Get(module switch
    {
        AppModule.Files => "ModuleFiles",
        AppModule.Photos => "ModulePhotos",
        AppModule.Chat => "ModuleChat",
        AppModule.Downloads => "ModuleDownloads",
        AppModule.Containers => "ModuleContainers",
        AppModule.VirtualMachines => "ModuleVirtualMachines",
        AppModule.NasSettings => "ModuleNasSettings",
        AppModule.Transfers => "ModuleTransfers",
        AppModule.Settings => "ModuleSettings",
        _ => throw new ArgumentOutOfRangeException(nameof(module)),
    });

    private void ApplySelection()
    {
        ResolvedLanguage = AppLanguageResolver.Resolve(
            Selection,
            _platform.SystemLanguage);
        _platform.ApplyLanguage(ResolvedLanguage);
        var culture = CultureInfo.GetCultureInfo(ResolvedLanguage);
        CultureInfo.CurrentCulture = culture;
        CultureInfo.CurrentUICulture = culture;
        CultureInfo.DefaultThreadCurrentCulture = culture;
        CultureInfo.DefaultThreadCurrentUICulture = culture;
    }

    private static bool IsLocalStorageFailure(Exception error) =>
        error is IOException or UnauthorizedAccessException or SecurityException;

}
