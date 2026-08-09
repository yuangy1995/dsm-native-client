using LanStash.App.Localization;
using LanStash.App.Features.Settings;
using Microsoft.UI.Xaml;

namespace LanStash.App;

public partial class App : Application
{
    private Window? _window;
    internal Window? MainWindow => _window;

    public App()
    {
        LocalizationService.Current.Initialize();
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        ApplyTheme(AppSettingsService.Current.Preferences.Theme);
        _window.Activate();
    }

    internal void ApplyTheme(AppThemePreference preference)
    {
        if (_window?.Content is not FrameworkElement root)
        {
            return;
        }
        root.RequestedTheme = preference switch
        {
            AppThemePreference.Light => ElementTheme.Light,
            AppThemePreference.Dark => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
    }
}
