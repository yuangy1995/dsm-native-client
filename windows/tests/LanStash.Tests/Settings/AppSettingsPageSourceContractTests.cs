namespace LanStash.Tests.Settings;

public sealed class AppSettingsPageSourceContractTests
{
    [Fact]
    public void CloudRefreshUsesBoundProductionActionCancellationAndLocalizedResults()
    {
        var source = Read("windows/src/LanStash.App/Views/CloudDriveSettingsPage.xaml.cs");
        var xaml = Read("windows/src/LanStash.App/Views/CloudDriveSettingsPage.xaml");
        var service = Read("windows/src/LanStash.App/CloudDrive/DesktopCloudDriveService.cs");
        var native = Read("windows/src/LanStash.App/CloudDrive/CloudFilePlaceholderNative.cs");
        Assert.Contains("this(app, app.RefreshDesktopDriveFilesAsync)", source);
        Assert.Contains("MappingButton(localization.Get(\"CloudDriveRefresh\")", source);
        Assert.Contains("await _refreshFiles(mapping, cancellation.Token)", source);
        Assert.Contains("_refreshCancellation?.Cancel()", source);
        Assert.Contains("if (!IsCurrent) return", source);
        Assert.Contains("CloudDriveRefreshPartial", source);
        Assert.Contains("DesktopDriveMappingState.Offline or DesktopDriveMappingState.AuthenticationRequired", source);
        Assert.Contains("refresh.IsEnabled = !needsResume", source);
        Assert.Contains("x:Name=\"CancelRefreshButton\"", xaml);
        Assert.Contains("_refreshLifetime.Cancel()", service);
        Assert.Contains("CloudDriveRemoteRefresh.RefreshAsync", service);
        Assert.Contains("0x00040081, 0", native);
        Assert.Contains("state.InSyncState != 1 || state.ModifiedDataSize != 0", native);
        Assert.DoesNotContain("File.SetAttributes", native);
    }

    [Fact]
    public void CloudManagementReusesExistingActionsAndRequiresSessionConsent()
    {
        var source = Read("windows/src/LanStash.App/Views/CloudDriveSettingsPage.xaml.cs");
        var gate = Read("windows/src/LanStash.App/CloudDrive/DesktopCloudDriveService.cs");
        var confirmation = Slice(source, "private async void EnableTestButton_Click", "private async void AddNasButton_Click");
        Assert.Contains("ContentDialogButton.Close", confirmation);
        Assert.Contains("ContentDialogResult.Primary || !IsCurrent", confirmation);
        Assert.Contains("EnableForCurrentProcess()", confirmation);
        Assert.DoesNotContain("AddDesktopDriveAsync", confirmation);
        Assert.Contains("AppContext.SetSwitch(RegistrationSwitch, true)", gate);
        Assert.Contains("_app.DesktopDriveProgressChanged -= DesktopDriveProgressChanged", source);
        Assert.Contains("_confirmation?.Hide()", source);
        Assert.Contains("if (!CanManage || _confirmation is not null) return", source);
        Assert.Contains("item.ProfileId == _profileId", source);
        Assert.Contains("launchAtLogin: LaunchAtLoginChoice.IsChecked == true", source);
        Assert.Contains("selectedPolicy,\n            launchAtLogin,", gate.Replace("\r\n", "\n"));
        foreach (var method in new[] { "AddDesktopDriveAsync", "RemoveDesktopDriveAsync", "KeepDesktopDriveOfflineAsync", "ReleaseDesktopDriveOfflineAsync", "PauseDesktopDriveAsync", "ResumeDesktopDriveAsync" })
            Assert.Contains("_app." + method, source);
    }

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
        Assert.Contains("CloudDriveRequested?.Invoke", source);
        Assert.DoesNotContain("DesktopCloudDriveService", source);
        Assert.DoesNotContain("AddDesktopDriveAsync", source);
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
        Assert.Contains("Navigation.SelectedItem = SettingsItem", method);
        Assert.Contains("ContentFrame.Content = CreateSettingsPage()", method);
        Assert.DoesNotContain("_workspace", method);
        Assert.Contains("var settings = new AppSettingsPage();", shell);
        Assert.Contains("new CloudDriveSettingsPage(_app)", shell);
        Assert.Contains("ReferenceEquals(ContentFrame.Content, settings)", shell);
        Assert.Contains("cloud.BackRequested", shell);
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
        Assert.DoesNotContain("DesktopCloudDriveService", page);
        Assert.DoesNotContain("AddDesktopDriveAsync", page);
        Assert.DoesNotContain("Profiles", page);
        Assert.DoesNotContain("Password", page);
        Assert.DoesNotContain("Transfer", page);
    }

    [Fact]
    public void HidingNasHealthCancelsAndInvalidatesItsWorkspaceLoad()
    {
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var nasPage = Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml.cs");
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
        Assert.Contains("CloseNasDetailsPage();", shell);
        Assert.Contains("_viewModel.Deactivate();", nasPage);
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
