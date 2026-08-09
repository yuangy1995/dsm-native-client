using System.Xml.Linq;

namespace LanStash.Tests;

public sealed class DownloadStationPageSourceContractTests
{
    [Fact]
    public void PageHasDedicatedReadOnlyAvailabilityAndFiveContentStates()
    {
        var xaml = Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml.cs");

        Assert.Contains("x:Name=\"LoadingState\"", xaml);
        Assert.Contains("x:Name=\"EmptyState\"", xaml);
        Assert.Contains("x:Name=\"FilteredEmptyState\"", xaml);
        Assert.Contains("x:Name=\"ErrorState\"", xaml);
        Assert.Contains("x:Name=\"ContentState\"", xaml);
        Assert.Contains("x:Name=\"UnavailableState\"", xaml);
        Assert.Contains("x:Name=\"TaskPane\"", xaml);
        Assert.Contains("x:Name=\"DetailPane\"", xaml);
        Assert.Contains("DownloadStationReadOnly", xaml);
        Assert.Contains("x:Name=\"ActivitySummary\"", xaml);
        Assert.Contains("x:Name=\"ActivityErrorNotice\"", xaml);
        Assert.Contains("CompactWidth = 760", source);
        Assert.Contains("_viewModel.IsUnavailable", source);
    }

    [Fact]
    public void PageUsesExplicitLoadMoreLocalFiltersAndReadOnlyDetails()
    {
        var xaml = Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml.cs");

        Assert.Contains("DownloadStationFilterAll", xaml);
        Assert.Contains("DownloadStationFilterActive", xaml);
        Assert.Contains("DownloadStationFilterFinished", xaml);
        Assert.Contains("DownloadStationFilterPaused", xaml);
        Assert.Contains("x:Name=\"LoadMoreButton\"", xaml);
        Assert.Contains("_viewModel.LoadMoreAsync", source);
        Assert.Contains("SelectedTask.DownloadSpeedText", xaml);
        Assert.Contains("SelectedTask.UploadSpeedText", xaml);
        Assert.Contains("SelectedTask.DestinationText", xaml);
        Assert.Contains("SelectedTask.ErrorText", xaml);
        Assert.Contains("SelectedTask.StatusText", xaml);
        Assert.DoesNotContain("RawStatus", xaml + source);
        Assert.Contains("IsIndeterminate=\"{x:Bind IsProgressUnknown}\"", xaml);
    }

    [Fact]
    public void PageSupportsKeyboardTouchNarratorTextScaleAndSystemThemes()
    {
        var xaml = Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml");

        Assert.True(Count(xaml, "MinHeight=\"44\"") >= 7);
        Assert.Contains("Key=\"Left\"", xaml);
        Assert.Contains("Key=\"F\"", xaml);
        Assert.Contains("Key=\"F5\"", xaml);
        Assert.Contains("Modifiers=\"Menu\"", xaml);
        Assert.Contains("Modifiers=\"Control\"", xaml);
        Assert.True(Count(xaml, "AutomationProperties.LiveSetting=\"Polite\"") >= 6);
        Assert.Contains("AutomationProperties.Name=\"{x:Bind AutomationName}\"", xaml);
        Assert.Contains("AutomationProperties.HeadingLevel=\"Level1\"", xaml);
        Assert.Contains("ThemeResource CardBackgroundFillColorDefaultBrush", xaml);
        Assert.Contains("TextWrapping=\"Wrap\"", xaml);
        Assert.DoesNotContain("Background=\"#", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Foreground=\"#", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("BorderBrush=\"#", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Storyboard", xaml);
    }

    [Fact]
    public void PageHasAbsolutelyNoManagementCommandsOrHandlers()
    {
        var downloadFeature =
            Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml") +
            Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml.cs") +
            Read("windows/src/LanStash.App/Features/Downloads/DownloadStationViewModel.cs");

        foreach (var forbidden in new[]
        {
            "CreateDownload", "CreateTask", "PauseTask", "ResumeTask", "DeleteTask",
            "SaveSettings", "LoadSettings", "ControlDownloads", "create_click",
            "pause_click", "resume_click", "delete_click", "settings_click"
        })
        {
            Assert.DoesNotContain(forbidden, downloadFeature, StringComparison.OrdinalIgnoreCase);
        }
        Assert.DoesNotContain("SYNO.DownloadStation2.Task", downloadFeature, StringComparison.Ordinal);
    }

    [Fact]
    public void XamlIsWellFormedAndShellUsesDedicatedProfileBoundRouteWithoutWorkspaceFallback()
    {
        var xaml = Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml");
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        _ = XDocument.Parse(xaml);
        Assert.Contains("if (module == AppModule.Downloads)", shell, StringComparison.Ordinal);
        Assert.Contains("downloadRepository.ProfileId != downloadProfile.Id", shell, StringComparison.Ordinal);
        Assert.Contains("new DownloadStationPage(downloadRepository)", shell, StringComparison.Ordinal);
        Assert.Contains("new UnavailableDownloadStationRepository", shell, StringComparison.Ordinal);
        var routeStart = shell.IndexOf("if (module == AppModule.Downloads)", StringComparison.Ordinal);
        var fallback = shell.IndexOf("ContentFrame.Content = _workspace;", routeStart, StringComparison.Ordinal);
        var routeEnd = shell.IndexOf("ContentFrame.Content = _downloads;", routeStart, StringComparison.Ordinal);
        Assert.True(routeStart >= 0 && routeEnd > routeStart && fallback > routeEnd);
    }

    private static int Count(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;

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
