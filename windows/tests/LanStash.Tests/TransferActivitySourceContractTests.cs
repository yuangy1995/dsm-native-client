namespace LanStash.Tests;

public sealed class TransferActivitySourceContractTests
{
    [Fact]
    public void ActivityPageShowsScopedStatesAndStopsPollingWhenHidden()
    {
        var xaml = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/TransferActivityPage.xaml");
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/TransferActivityPage.xaml.cs");
        var window = ReadRepositoryFile(
            "windows/src/LanStash.App/MainWindow.xaml.cs");

        Assert.Contains("x:Name=\"ActivityList\"", xaml);
        Assert.Contains("x:Name=\"EmptyState\"", xaml);
        Assert.Contains("<ProgressBar", xaml);
        Assert.Contains("Text=\"{Binding SourceText}\"", xaml);
        Assert.Contains("MinHeight=\"44\"", xaml);
        Assert.Contains(
            "AutomationProperties.Name=\"{Binding CancelAutomationName}\"",
            xaml);
        Assert.Contains("TransferActivityCancelAutomationName", source);
        Assert.Contains("activity.DisplayName", source);
        Assert.Contains("ForegroundTransferState.Running", source);
        Assert.Contains("ForegroundTransferState.Paused", source);
        Assert.Contains("ForegroundTransferState.Completed", source);
        Assert.Contains("ForegroundTransferState.Cancelled", source);
        Assert.Contains("ForegroundTransferState.CancelledBeforeSubmission", source);
        Assert.Contains("ForegroundTransferState.ResultNeedsReview", source);
        Assert.Contains("ForegroundTransferState.Failed", source);
        Assert.Contains("ForegroundTransferDirection.Upload", source);
        Assert.Contains("TransferActivitySourceNas", source);
        Assert.Contains("activity.Source == ForegroundTransferSource.App", source);
        Assert.Contains("_coordinator.GetActivities(_profileId)", source);
        Assert.Contains("_timer.Start();", source);
        Assert.Contains("_timer.Stop();", source);
        Assert.Contains("_isLoaded && _isWindowVisible", source);
        Assert.Contains("await _nasRefresher.StartAsync();", source);
        Assert.Contains("await _nasRefresher.StopAsync();", source);
        Assert.Contains("await _lifecycleGate.WaitAsync();", source);
        Assert.Contains("await shell.SetWindowVisibleAsync(false);", window);
        Assert.Contains("await shell.SetWindowVisibleAsync(true);", window);
        Assert.Contains("await _nasRefresher.RefreshAsync();", source);
        Assert.Contains("RefreshButton.IsEnabled", source);
        Assert.Contains("RefreshErrorNotice.IsOpen", source);
        Assert.Contains("TruncatedNotice.IsOpen", source);
        Assert.Contains("NasUnavailableNotice.IsOpen", source);
        Assert.Contains("<KeyboardAccelerator Key=\"F5\"", xaml);
        Assert.Contains("x:Name=\"RefreshButton\"", xaml);
        Assert.Contains("AutomationProperties.LiveSetting=\"Polite\"", xaml);
    }

    [Fact]
    public void ActivityDoesNotExposePathsOrInternalFailuresToUsers()
    {
        var xaml = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/TransferActivityPage.xaml");
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/TransferActivityPage.xaml.cs");

        Assert.DoesNotContain("RemotePath}", xaml);
        Assert.DoesNotContain("FailureMessage", source);
        Assert.DoesNotContain("API", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("TransferActivityFailed", source);
    }

    [Fact]
    public void ShellOwnsOneCoordinatorAndCachesBothPages()
    {
        var shell = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains(
            "private readonly ForegroundTransferCoordinator _transfers = new();",
            shell);
        Assert.Contains("_files ??= new FilesPage(", shell);
        Assert.Contains("_activity ??= new TransferActivityPage(", shell);
        Assert.Contains("_app.Repository as IDownloadStationRepository", shell);
        Assert.Contains("await _activity.DisposeAsync();", shell);
        Assert.Contains("new DownloadStationPage(downloadRepository, _transfers)", shell);
        Assert.Contains("_transferPicker?.Dispose();", shell);
        Assert.Contains("_transfers.Dispose();", shell);
    }

    private static string ReadRepositoryFile(string relativePath)
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
