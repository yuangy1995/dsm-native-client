namespace LanStash.Tests.Settings;

public sealed class AppSettingsPageSourceContractTests
{
    [Fact]
    public void SettingsPageUsesNativeAccessibleControlsAndOnlyLocalizedVisibleText()
    {
        var xaml = Read("windows/src/LanStash.App/Views/AppSettingsPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/AppSettingsPage.xaml.cs");

        Assert.Contains("x:Uid=\"Settings.PageTitle\"", xaml);
        Assert.Contains("x:Name=\"LanguageSelector\"", xaml);
        Assert.Contains("x:Name=\"ThemeSelector\"", xaml);
        Assert.Equal(4, Count(xaml, "<ToggleSwitch"));
        Assert.True(Count(xaml, "MinHeight=\"44\"") >= 7);
        Assert.Contains("AutomationProperties.HeadingLevel=\"Level1\"", xaml);
        Assert.Contains("AutomationProperties.LiveSetting=\"Polite\"", xaml);
        Assert.Contains("ThemeResource", xaml);
        Assert.DoesNotContain("Background=\"#", xaml);
        Assert.DoesNotContain("Foreground=\"#", xaml);
        Assert.Contains("AppThemePreference.System", source);
        Assert.Contains("LocalizationService.Current.TrySetSelection", source);
        Assert.Contains("_settings.Caches.ClearAsync()", source);
        Assert.Contains("ShowSaveFailure", source);
        Assert.Contains("Settings.SaveFailedTitle", source);
        Assert.Contains("Settings.SaveFailedMessage", source);
        Assert.DoesNotContain("CloudDrive", source);
        Assert.DoesNotContain("Credential", source);
        Assert.DoesNotContain("Repository", source);
    }

    [Fact]
    public void ShellIntersectsCapabilitiesWithLocalVisibilityAndNeverFallsBackToWorkspace()
    {
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var method = Slice(shell, "private void RebuildModuleNavigation", "private void DisposeHiddenModulePage");

        Assert.Contains("_app.AvailableModules", method);
        Assert.Contains("module != AppModule.Settings", method);
        Assert.Contains(".Where(_settings.IsModuleVisible)", method);
        Assert.Contains("Navigation.SelectedItem = Navigation.SettingsItem", method);
        Assert.Contains("ContentFrame.Content = new AppSettingsPage()", method);
        Assert.DoesNotContain("_workspace", method);
        Assert.Contains("ContentFrame.Content = new AppSettingsPage();", shell);
        Assert.DoesNotContain("new LanguageSettingsPage(_app)", shell);
    }

    [Fact]
    public void ThemeAppliesToWindowRootAndCacheScopeExcludesUnrelatedData()
    {
        var app = Read("windows/src/LanStash.App/App.xaml.cs");
        var settings = Read(
            "windows/src/LanStash.App/Features/Settings/AppSettingsService.cs");
        var page = Read("windows/src/LanStash.App/Views/AppSettingsPage.xaml.cs");

        Assert.Contains("_window?.Content is not FrameworkElement root", app);
        Assert.Contains("root.RequestedTheme", app);
        Assert.Contains("ElementTheme.Default", app);
        Assert.Contains("ElementTheme.Light", app);
        Assert.Contains("ElementTheme.Dark", app);
        Assert.Contains("AppSettingsModulePolicy.CanHide", settings);
        Assert.DoesNotContain("CloudDrive", page);
        Assert.DoesNotContain("Profiles", page);
        Assert.DoesNotContain("Password", page);
        Assert.DoesNotContain("Transfer", page);
    }

    [Fact]
    public void HidingNasHealthCancelsAndInvalidatesItsWorkspaceLoad()
    {
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var page = Read("windows/src/LanStash.App/Views/WorkspacePage.xaml.cs");
        var viewModel = Read("windows/src/LanStash.App/ViewModels/WorkspaceViewModel.cs");
        var cancel = Slice(
            viewModel,
            "public void CancelNasSettingsLoad",
            "public async Task OpenSelectedAsync");
        var reload = Slice(
            viewModel,
            "public async Task ReloadAsync",
            "public void CancelNasSettingsLoad");

        Assert.Contains("case AppModule.NasSettings:", shell);
        Assert.Contains("_workspace.CancelNasSettingsLoad();", shell);
        Assert.Contains("public void CancelNasSettingsLoad()", page);
        Assert.Contains("_nasSettingsLoadGeneration++", cancel);
        Assert.Contains("cancellation?.Cancel();", cancel);
        Assert.Contains("LoadNasSettingsAsync(cancellationToken)", viewModel);
        Assert.Contains("nasSettingsGeneration != _nasSettingsLoadGeneration", reload);
        Assert.True(
            reload.IndexOf(
                "nasSettingsGeneration != _nasSettingsLoadGeneration",
                StringComparison.Ordinal) <
            reload.IndexOf("Items.Clear();", StringComparison.Ordinal));
    }

    private static int Count(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;

    private static string Slice(string source, string start, string end)
    {
        var startIndex = source.IndexOf(start, StringComparison.Ordinal);
        var endIndex = source.IndexOf(end, startIndex, StringComparison.Ordinal);
        Assert.True(startIndex >= 0 && endIndex > startIndex);
        return source[startIndex..endIndex];
    }

    private static string Read(string path) =>
        File.ReadAllText(Path.Combine(RepositoryRoot(), path));

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "windows")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new DirectoryNotFoundException();
    }
}
