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
        Assert.Contains("x:Name=\"AdvancedSummary\"", xaml);
        Assert.Contains("x:Name=\"StationSettingsSummary\"", xaml);
        Assert.Contains("x:Name=\"DownloadRssSummary\"", xaml);
        Assert.Contains("x:Name=\"AdvancedSummaryErrorNotice\"", xaml);
        Assert.Contains("DownloadStationActivityEmuleDownload", xaml);
        Assert.Contains("DownloadStationActivityEmuleUpload", xaml);
        Assert.Contains("ActivityEmuleDownloadSpeedText", xaml);
        Assert.Contains("ActivityEmuleUploadSpeedText", xaml);
        Assert.Contains("SettingsDefaultDestinationText", xaml);
        Assert.Contains("SettingsSpeedLimitText", xaml);
        Assert.Contains("RssSitesText", xaml);
        Assert.Contains("AdvancedSummary.Visibility", source);
        Assert.Contains("_viewModel.HasAdvancedSummary", source);
        Assert.Contains("CompactWidth = 760", source);
        Assert.Contains("_viewModel.IsUnavailable", source);
    }

    [Fact]
    public void PageUsesExplicitLoadMoreLocalFiltersAndLimitedTaskControls()
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
        Assert.Contains("SelectedTask.PriorityText", xaml);
        Assert.Contains("SelectedTask.FileCountText", xaml);
        Assert.Contains("SelectedTask.TrackerCountText", xaml);
        Assert.Contains("SelectedTask.PeerCountText", xaml);
        Assert.Contains("SelectedTask.SeedsText", xaml);
        Assert.Contains("SelectedTask.LeechesText", xaml);
        Assert.Contains("x:Name=\"PauseButton\"", xaml);
        Assert.Contains("x:Name=\"ResumeButton\"", xaml);
        Assert.Contains("x:Name=\"DeleteButton\"", xaml);
        Assert.Contains("Click=\"Pause_Click\"", xaml);
        Assert.Contains("Click=\"Resume_Click\"", xaml);
        Assert.Contains("Click=\"Delete_Click\"", xaml);
        Assert.Contains("x:Name=\"DownloadControlNotice\"", xaml);
        Assert.Contains("x:Name=\"DownloadDeleteNotice\"", xaml);
        Assert.Contains("_viewModel.ControlSelectedTaskAsync(DownloadTaskControlAction.Pause)", source);
        Assert.Contains("_viewModel.ControlSelectedTaskAsync(DownloadTaskControlAction.Resume)", source);
        Assert.Contains("_viewModel.DeleteSelectedTaskAsync", source);
        Assert.Contains("DownloadTaskControlNoticeKind.NeedsReview", source);
        Assert.Contains("DownloadTaskDeleteNoticeKind.NeedsReview", source);
        Assert.DoesNotContain("RawStatus", xaml + source);
        Assert.Contains("IsIndeterminate=\"{x:Bind IsProgressUnknown}\"", xaml);
    }

    [Fact]
    public void PageSupportsKeyboardTouchNarratorTextScaleAndSystemThemes()
    {
        var xaml = Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml");

        Assert.True(Count(xaml, "MinHeight=\"44\"") >= 8);
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
    public void PageOnlyExposesLinkCreateSingleTaskPauseResumeAndSafeDelete()
    {
        var downloadFeature =
            Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml") +
            Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml.cs") +
            Read("windows/src/LanStash.App/Views/DownloadStationPage.CreateFile.cs") +
            Read("windows/src/LanStash.App/Features/Downloads/DownloadStationViewModel.cs") +
            Read("windows/src/LanStash.App/Features/Downloads/DownloadStationViewModel.Create.cs") +
            Read("windows/src/LanStash.App/Features/Downloads/DownloadStationViewModel.Delete.cs");

        foreach (var forbidden in new[]
        {
            "DeleteDownloaded", "DeleteDownloadData",
            "SaveSettings", "LoadSettings", "ControlDownloads", "create_click",
            "settings_click", "force_complete", "removeData"
        })
        {
            Assert.DoesNotContain(forbidden, downloadFeature, StringComparison.OrdinalIgnoreCase);
        }
        Assert.Contains("DownloadStationCreateTask", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("ShowCreateTaskDialogAsync", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("_viewModel.CreateTaskAsync(uriBox.Text)", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("new DownloadTaskCreateRequest(", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("DownloadStationCreateFileTask", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("CreateFileTask_Click", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("new FileOpenPicker(windowId)", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("PickSingleFileAsync()", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("\".torrent\"", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("\".nzb\"", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("\".txt\"", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("_viewModel.CreateTaskFromFileAsync(filePath)", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("new DownloadTaskFileCreateRequest(", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("Pause_Click", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("Resume_Click", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("Delete_Click", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("ShowDeleteTaskDialogAsync", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("DownloadStationDeleteConfirmMessage", downloadFeature, StringComparison.Ordinal);
        Assert.Contains("new DownloadTaskDeleteRequest(", downloadFeature, StringComparison.Ordinal);
        Assert.DoesNotContain("DownloadTaskControlAction.Finish", downloadFeature, StringComparison.Ordinal);
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
        Assert.Contains("new DownloadStationPage(downloadRepository, _transfers)", shell, StringComparison.Ordinal);
        Assert.Contains("new UnavailableDownloadStationRepository(Guid.Empty),", shell, StringComparison.Ordinal);
        Assert.True(Count(shell, "_transfers)") >= 2);
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
