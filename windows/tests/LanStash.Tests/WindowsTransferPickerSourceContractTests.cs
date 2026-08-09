namespace LanStash.Tests;

public sealed class WindowsTransferPickerSourceContractTests
{
    [Fact]
    public void PathSavePickerIsBoundToTheCurrentWindowBeforeItIsShown()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");

        Assert.Contains("new FileSavePicker(windowId)", source);
        Assert.Contains("SuggestedFileName = suggestedName", source);
        Assert.Contains("FileTypeChoices.Add", source);
        Assert.Contains("Win32Interop.GetWindowIdFromWindow", source);
        Assert.Contains("WindowNative.GetWindowHandle(window)", source);
        Assert.Contains("return result?.Path;", source);
        Assert.DoesNotContain("using Windows.Storage.Pickers;", source);
    }

    [Fact]
    public void CancellingPickerDoesNotCreateAnActivityOrDestination()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");
        var method = SliceMethod(
            source,
            "public async Task<bool> PickAndStartDownloadAsync",
            "public void Cancel");

        var cancellationIndex = method.IndexOf("if (targetPath is null)", StringComparison.Ordinal);
        var runIndex = method.IndexOf("_ = RunDownloadAsync", StringComparison.Ordinal);
        Assert.True(cancellationIndex >= 0 && runIndex > cancellationIndex);
        Assert.Contains("return false;", method[cancellationIndex..runIndex]);
        Assert.DoesNotContain("RunAsync(", method[..cancellationIndex]);
        Assert.DoesNotContain("CreateAsync(targetPath)", method[..cancellationIndex]);
    }

    [Fact]
    public void StorageDestinationUsesOnlyThePlatformTransactionBoundary()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransactionalDownloadDestination.cs");

        Assert.Contains("OpenTransactedWriteAsync", source);
        Assert.Contains("_transaction.CommitAsync()", source);
        Assert.Contains("MoveAndReplaceAsync", source);
        Assert.Contains(".lanstash-", source);
        Assert.Contains("_transaction.Dispose()", source);
        Assert.DoesNotContain("FileMode.Create", source);
        Assert.DoesNotContain("File.Write", source);
        Assert.DoesNotContain("new FileStream", source);
        Assert.DoesNotContain("file.Path", source);
    }

    [Fact]
    public void PickerServiceKeepsForegroundScopeWithoutResumeOrBackgroundSurface()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");

        Assert.Contains("SafeFileDownloadService", source);
        Assert.Contains("ForegroundTransferCoordinator", source);
        Assert.Contains("CancellationTokenSource", source);
        Assert.Contains("PickAndStartUploadAsync", source);
        Assert.Contains("UploadFileAsync", source);
        Assert.DoesNotContain("CloudDrive", source);
        Assert.DoesNotContain("Resume", source);
        Assert.DoesNotContain("Background", source);
    }

    [Fact]
    public void CancellationUsesTheUniqueActivityId()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");
        var activity = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/TransferActivityPage.xaml.cs");

        Assert.Contains("Guid.NewGuid()", source);
        Assert.Contains("running.ActivityId", source);
        Assert.Contains("item.ActivityId == activityId", source);
        Assert.Contains("_transfers.Cancel(_profileId, activity.Id)", activity);
        Assert.DoesNotContain("activity.RemotePath", activity);
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

    private static string SliceMethod(string source, string start, string next)
    {
        var startIndex = source.IndexOf(start, StringComparison.Ordinal);
        var endIndex = source.IndexOf(next, startIndex, StringComparison.Ordinal);
        Assert.True(startIndex >= 0 && endIndex > startIndex);
        return source[startIndex..endIndex];
    }
}
