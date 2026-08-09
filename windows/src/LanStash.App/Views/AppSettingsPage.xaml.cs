using System.Globalization;
using LanStash.App.Features.Settings;
using LanStash.App.Localization;
using LanStash.Domain;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace LanStash.App.Views;

public sealed partial class AppSettingsPage : Page
{
    private readonly AppSettingsService _settings = AppSettingsService.Current;
    private bool _isLoading;
    private bool _isClearing;

    public AppSettingsPage()
    {
        InitializeComponent();
        Loaded += AppSettingsPage_Loaded;
        Unloaded += AppSettingsPage_Unloaded;
    }

    private void AppSettingsPage_Loaded(object sender, RoutedEventArgs e)
    {
        _settings.Changed += Settings_Changed;
        LoadState();
    }

    private void AppSettingsPage_Unloaded(object sender, RoutedEventArgs e) =>
        _settings.Changed -= Settings_Changed;

    private void Settings_Changed(object? sender, AppSettingsChangedEventArgs e) =>
        DispatcherQueue.TryEnqueue(LoadState);

    private void LoadState()
    {
        _isLoading = true;
        var localization = LocalizationService.Current;
        var languageChoices = localization.Choices();
        LanguageSelector.ItemsSource = languageChoices;
        LanguageSelector.SelectedItem = languageChoices.First(choice =>
            choice.Value == localization.Selection);

        var themeChoices = new[]
        {
            new ThemeChoice(
                AppThemePreference.System,
                localization.Get("Settings.ThemeSystem")),
            new ThemeChoice(
                AppThemePreference.Light,
                localization.Get("Settings.ThemeLight")),
            new ThemeChoice(
                AppThemePreference.Dark,
                localization.Get("Settings.ThemeDark")),
        };
        ThemeSelector.ItemsSource = themeChoices;
        ThemeSelector.SelectedItem = themeChoices.First(choice =>
            choice.Value == _settings.Preferences.Theme);

        DownloadsToggle.IsOn = _settings.IsModuleVisible(AppModule.Downloads);
        ContainersToggle.IsOn = _settings.IsModuleVisible(AppModule.Containers);
        VirtualMachinesToggle.IsOn = _settings.IsModuleVisible(AppModule.VirtualMachines);
        NasHealthToggle.IsOn = _settings.IsModuleVisible(AppModule.NasSettings);
        _isLoading = false;
        UpdateCacheSummary();
    }

    private void LanguageSelector_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isLoading || LanguageSelector.SelectedItem is not LanguageChoice choice)
        {
            return;
        }
        if (!LocalizationService.Current.TrySetSelection(choice.Value))
        {
            LoadState();
            ShowSaveFailure();
        }
    }

    private void ThemeSelector_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_isLoading || ThemeSelector.SelectedItem is not ThemeChoice choice)
        {
            return;
        }
        if (_settings.SetTheme(choice.Value))
        {
            (Application.Current as App)?.ApplyTheme(choice.Value);
            return;
        }
        LoadState();
        ShowSaveFailure();
    }

    private void ModuleToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_isLoading || sender is not ToggleSwitch { Tag: string value } toggle ||
            !Enum.TryParse<AppModule>(value, out var module))
        {
            return;
        }
        if (!_settings.SetModuleVisible(module, toggle.IsOn))
        {
            LoadState();
            ShowSaveFailure();
        }
    }

    private void ShowSaveFailure()
    {
        CacheFeedback.Severity = InfoBarSeverity.Error;
        CacheFeedback.Title = LocalizationService.Current.Get("Settings.SaveFailedTitle");
        CacheFeedback.Message = LocalizationService.Current.Get("Settings.SaveFailedMessage");
        CacheFeedback.IsOpen = true;
    }

    private async void ClearCacheButton_Click(object sender, RoutedEventArgs e)
    {
        if (_isClearing)
        {
            return;
        }
        _isClearing = true;
        ClearCacheButton.IsEnabled = false;
        ClearCacheProgress.IsActive = true;
        ClearCacheProgress.Visibility = Visibility.Visible;
        CacheFeedback.IsOpen = false;
        try
        {
            var result = await _settings.Caches.ClearAsync();
            UpdateCacheSummary();
            CacheFeedback.Severity = result.IsComplete
                ? InfoBarSeverity.Success
                : InfoBarSeverity.Warning;
            CacheFeedback.Title = LocalizationService.Current.Get(result.IsComplete
                ? "Settings.CacheClearedTitle"
                : "Settings.CachePartialTitle");
            CacheFeedback.Message = LocalizationService.Current.Get(result.IsComplete
                ? "Settings.CacheClearedMessage"
                : "Settings.CachePartialMessage");
            CacheFeedback.IsOpen = true;
        }
        finally
        {
            _isClearing = false;
            ClearCacheButton.IsEnabled = true;
            ClearCacheProgress.IsActive = false;
            ClearCacheProgress.Visibility = Visibility.Collapsed;
        }
    }

    private void UpdateCacheSummary()
    {
        var summary = _settings.Caches.Snapshot();
        CacheSummaryText.Text = LocalizationService.Current.Format(
            "Settings.CacheSummary",
            summary.ItemCount,
            FormatBytes(summary.Bytes));
    }

    private static string FormatBytes(long bytes)
    {
        var value = Math.Max(0, bytes);
        if (value < 1024)
        {
            return LocalizationService.Current.Format("Settings.Bytes", value);
        }
        if (value < 1024 * 1024)
        {
            return LocalizationService.Current.Format(
                "Settings.Kilobytes",
                (value / 1024d).ToString("0.#", CultureInfo.CurrentCulture));
        }
        return LocalizationService.Current.Format(
            "Settings.Megabytes",
            (value / (1024d * 1024d)).ToString("0.#", CultureInfo.CurrentCulture));
    }

    private sealed record ThemeChoice(AppThemePreference Value, string DisplayName)
    {
        public override string ToString() => DisplayName;
    }
}
