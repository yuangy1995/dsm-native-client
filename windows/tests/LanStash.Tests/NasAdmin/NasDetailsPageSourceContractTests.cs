using System.Xml.Linq;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDetailsPageSourceContractTests
{
    [Fact]
    public void PageHasDedicatedFiveStateReadOnlyWinUiSurface()
    {
        var xaml = Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml.cs");

        Assert.Contains("x:Name=\"LoadingState\"", xaml);
        Assert.Contains("x:Name=\"EmptyState\"", xaml);
        Assert.Contains("x:Name=\"ErrorState\"", xaml);
        Assert.Contains("x:Name=\"UnavailableState\"", xaml);
        Assert.Contains("x:Name=\"ContentState\"", xaml);
        Assert.Contains("NasDetailsReadOnly", xaml);
        Assert.Contains("Key=\"F5\"", xaml);
        Assert.Contains("x:Name=\"RunStorageAnalysisButton\"", xaml);
        Assert.Contains("x:Name=\"RunDeepStorageAnalysisButton\"", xaml);
        Assert.Contains("x:Name=\"CancelStorageAnalysisButton\"", xaml);
        Assert.Contains("x:Name=\"HeaderActions\"", xaml);
        Assert.Contains("ItemsWrapGrid Orientation=\"Horizontal\"", xaml);
        Assert.Contains("AdaptiveTrigger MinWindowWidth=\"1060\"", xaml);
        Assert.Contains("RunStorageAnalysis_Click", source);
        Assert.Contains("RunDeepStorageAnalysis_Click", source);
        Assert.Contains("CancelStorageAnalysis_Click", source);
        Assert.Contains("_viewModel.CanRunStorageAnalysis", source);
        Assert.Contains("_viewModel.CanRunDeepStorageAnalysis", source);
        Assert.Contains("_viewModel.CanCancelStorageAnalysis", source);
        Assert.Contains("ScrollViewer.VerticalScrollMode=\"Enabled\"", xaml);
        Assert.Contains("AutomationProperties.LiveSetting=\"Polite\"", xaml);
        Assert.True(Count(xaml, "MinHeight=\"44\"") >= 2);
        Assert.Contains("_viewModel.HasRefreshError", source);
        Assert.Contains("_viewModel.Deactivate();", source);
    }

    [Fact]
    public void PageShowsOnlyWhitelistedSectionRowsAndNoWriteActions()
    {
        var combined =
            Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml") +
            Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml.cs") +
            Read("windows/src/LanStash.App/Features/NasAdmin/NasDetailsState.cs") +
            Read("windows/src/LanStash.App/Features/NasAdmin/NasDetailsViewModel.cs");

        foreach (var allowed in new[]
        {
            "NasDetailsSectionSystem",
            "NasDetailsSectionStorage",
            "NasDetailsSectionUpdate",
            "NasDetailsSectionShareAccess",
            "NasDetailsSectionStorageAnalysis",
            "NasDetailsSectionSystemActivity",
            "NasDetailsSectionPackages",
            "NasDetailsSectionTasks",
            "NasDetailsSectionLogs",
            "NasDetailsSectionConnections",
            "NasDetailsTruncated",
            "NasDetailsUpdateAvailable",
            "NasDetailsUpdateCurrent",
            "NasDetailsUpdateReleaseNotes",
            "NasDetailsShareAccessScopeTitle",
            "NasDetailsShareAccessReadWrite",
            "NasDetailsShareAccessReadOnly",
            "NasDetailsShareAccessUnknown",
            "NasDetailsStorageAnalysisScopeTitle",
            "NasDetailsDeepStorageAnalysisScopeTitle",
            "NasDetailsStorageAnalysisLargeFiles",
            "NasDetailsStorageAnalysisDuplicateFiles",
            "NasDetailsStorageAnalysisFolders",
            "NasDetailsStorageAnalysisOwnerTitle",
            "NasDetailsSystemActivityScopeTitle",
            "NasDetailsSystemActivityProcessId",
            "NasDetailsSystemActivityGroupsUnavailable",
        })
        {
            Assert.Contains(allowed, combined);
        }
        foreach (var forbidden in new[]
        {
            "kick_connection",
            "run task",
            "RunTask",
            "set_enable",
            "Package.Control",
            "Package.Uninstallation",
            "disconnect",
            "log message",
            "account",
            "source address",
            "device_id",
            "process_id",
            "serial",
            "vol_path",
            "pool_path",
            "private-device",
            "Upgrade.Server.download",
            "Upgrade.Server.install",
            "Upgrade.Server.upload",
            "SharedFolder.create",
            "SharedFolder.set",
            "SharedFolder.delete",
            "set_acl",
            "service_info",
            "kill_process",
            "command_line",
            "working_directory",
            "environment_variables",
        })
        {
            Assert.DoesNotContain(forbidden, combined, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public void ShellRoutesNasSettingsToDedicatedPageAndDisposesItOnProfileChanges()
    {
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains("private NasDetailsPage? _nasDetails;", shell);
        Assert.Contains("private INasDetailsRepository? _nasDetailsRepository;", shell);
        Assert.Contains("module == AppModule.NasSettings", shell);
        Assert.Contains("new NasDetailsPage(", shell);
        Assert.Contains("new UnavailableNasDetailsRepository", shell);
        Assert.Contains("!ReferenceEquals(_nasDetailsRepository, nasRepository)", shell);
        Assert.Contains("CloseNasDetailsPage();", shell);
        Assert.Contains(": INasDetailsRepository", shell);
    }

    [Fact]
    public void XamlAndResourcesAreWellFormed()
    {
        var xaml = Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml");
        _ = XDocument.Parse(xaml);

        foreach (var uid in new[]
        {
            "NasDetailsTitle",
            "NasDetailsDescription",
            "NasDetailsRefresh",
            "NasDetailsReadOnly",
            "NasDetailsRefreshError",
            "NasDetailsSectionList",
            "NasDetailsItemList",
            "NasDetailsLoading",
            "NasDetailsErrorTitle",
            "NasDetailsTryAgain",
            "NasDetailsUnavailableTitle",
        })
        {
            Assert.Contains($"x:Uid=\"{uid}\"", xaml, StringComparison.Ordinal);
        }
        Assert.Contains("Text=\"{Binding EmptyTitle}\"", xaml, StringComparison.Ordinal);
        Assert.Contains("Text=\"{Binding EmptyMessage}\"", xaml, StringComparison.Ordinal);
        Assert.DoesNotContain(" Text=\"NAS", xaml, StringComparison.Ordinal);
        Assert.DoesNotContain(" Content=\"Refresh", xaml, StringComparison.Ordinal);
    }

    private static int Count(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;

    [Fact]
    public void ServiceSettingsHaveActualFieldsConfirmationAndBoundedDialogLifetime()
    {
        var page = Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/NasDetailsPage.ServiceSettings.cs");
        var form = Read("windows/src/LanStash.App/Views/NasServiceSettingsDialogContent.xaml");
        var behavior = Read("windows/src/LanStash.App/Views/NasServiceSettingsDialogContent.xaml.cs");
        Assert.Contains("TerminalSettings_Click", page);
        Assert.Contains("ProxySettings_Click", page);
        foreach (var field in new[] { "SshToggle", "SshPort", "TelnetToggle", "ProxyToggle", "ProxyHost", "ProxyPort", "RiskAcknowledgement" })
            Assert.Contains($"x:Name=\"{field}\"", form);
        Assert.Contains("ContentDialogButton.Close", source);
        Assert.Contains("args.Cancel = true", source);
        Assert.Contains("content.Dispose()", source);
        Assert.Contains("RiskAcknowledgement.IsChecked == true", behavior);
        Assert.Contains("NasServiceSettingsInput.TryTerminal", behavior);
        Assert.Contains("NasServiceSettingsInput.TryProxy", behavior);
        Assert.Contains("WriteAvailable", behavior);
        Assert.Contains("_settingsRepository.ProfileId != _viewModel.ActiveProfileId", source);
        var localizationSource = Read("windows/src/LanStash.App/Localization/LocalizationService.cs");
        Assert.Contains("GetString(ToResourcePath(key))", localizationSource);
        Assert.Contains("characters[index] == '.' && !inNamespace", localizationSource);
        Assert.DoesNotContain("ShowEditDialogAsync", Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml.cs"));
    }

    [Fact]
    public void FileServicesUseAvailabilityFlagsAndSharedDialogLifecycle()
    {
        var source = Read("windows/src/LanStash.App/Views/NasFileServiceSettingsDialogContent.xaml.cs");
        var xaml = Read("windows/src/LanStash.App/Views/NasFileServiceSettingsDialogContent.xaml");
        Assert.Contains("AvailableFields", source);
        Assert.Contains("FailedFields", source);
        Assert.Contains("available.HasFlag(field)", source);
        Assert.Contains("NasFileServicePartialRead", source);
        Assert.Contains("NasSettingsUnavailable", source);
        Assert.Contains("RiskAcknowledgement.IsChecked == true", source);
        Assert.Contains("NasFileServiceSettingsRules.IsValidChange", source);
        Assert.Contains("NasServiceSettingsSaveRequest<NasFileServiceSettings>", source);
        Assert.Contains("NasFileFtps", xaml);
        Assert.Contains("ShowSettingsContentAsync(new NasFileServiceSettingsDialogContent", Read("windows/src/LanStash.App/Views/NasDetailsPage.ServiceSettings.cs"));
    }

    [Fact]
    public void TaskManagementUsesExistingDialogAndClearsSensitiveControls()
    {
        var xaml = Read("windows/src/LanStash.App/Views/NasTasksSettingsDialogContent.xaml");
        var source = Read("windows/src/LanStash.App/Views/NasTasksSettingsDialogContent.xaml.cs");
        Assert.Contains("TasksSettings_Click", Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml"));
        Assert.Contains("new NasTasksSettingsDialogContent(_settingsRepository)", Read("windows/src/LanStash.App/Views/NasDetailsPage.ServiceSettings.cs"));
        foreach (var name in new[] { "LoadingIndicator", "ErrorNotice", "EmptyNotice", "TaskList", "EditorPanel", "HistoryPanel", "RiskAcknowledgement", "ExecuteButton" })
            Assert.Contains($"x:Name=\"{name}\"", xaml);
        Assert.Contains("ReadFields(); if (_model.CanExecute)", source);
        Assert.Contains("ScriptInput.Text = EmailInput.Text = CommandOutput.Text = ResultOutput.Text = \"\"", source);
        Assert.DoesNotContain("HttpClient", source);
        Assert.DoesNotContain("File.Write", source);
        Assert.Contains("PrimaryButtonResourceKey => null", source);
    }

    private static string Read(string relativePath)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(candidate))
            {
                return File.ReadAllText(candidate);
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException(relativePath);
    }
}
