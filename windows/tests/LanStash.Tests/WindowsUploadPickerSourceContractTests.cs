namespace LanStash.Tests;

public sealed class WindowsUploadPickerSourceContractTests
{
    [Fact]
    public void PathOpenPickerUsesCurrentWindowAndNeverUsesLegacyPicker()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");

        Assert.Contains("new FileOpenPicker(windowId)", source);
        Assert.Contains("PickSingleFileAsync()", source);
        Assert.Contains("picker.FileTypeFilter.Add(filter)", source);
        Assert.Contains("return result?.Path;", source);
        Assert.Contains("Win32Interop.GetWindowIdFromWindow", source);
        Assert.Contains("WindowNative.GetWindowHandle(window)", source);
        Assert.DoesNotContain("using Windows.Storage.Pickers;", source);
        Assert.DoesNotContain("InitializeWithWindow.Initialize", source);
    }

    [Fact]
    public void PickerCancellationPrecedesStreamActivityAndRepositoryWrite()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");
        var method = SliceMethod(
            source,
            "private async Task<PhotoMediaUploadStart?> PickAndStartUploadCoreAsync",
            "public void Cancel");

        var cancelled = method.IndexOf("if (sourcePath is null)", StringComparison.Ordinal);
        var openStream = method.IndexOf("new FileStream(", StringComparison.Ordinal);
        var running = method.IndexOf("new RunningTransfer(", StringComparison.Ordinal);
        var start = method.IndexOf("_ = RunUploadAsync", StringComparison.Ordinal);
        Assert.True(cancelled >= 0 && openStream > cancelled);
        Assert.True(running > openStream && start > running);
        Assert.Contains("return null;", method[cancelled..openStream]);
        Assert.DoesNotContain("UploadFileAsync", method[..openStream]);
        Assert.DoesNotContain("RunUploadAsync", method[..openStream]);
    }

    [Fact]
    public void UploadFreezesOneReadableFileAndNeverEnablesOverwriteOrReplay()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");

        Assert.Contains("FileMode.Open", source);
        Assert.Contains("FileAccess.Read", source);
        Assert.Contains("FileShare.Read", source);
        Assert.Contains("FileOptions.Asynchronous | FileOptions.SequentialScan", source);
        Assert.Contains("length = source.Length;", source);
        Assert.Contains("Path.GetFileName(sourcePath)", source);
        Assert.Contains("overwrite: false", source);
        Assert.Equal(1, CountOccurrences(source, "_repository.UploadFileAsync("));
        Assert.Contains("upload.Content.Dispose();", source);
        Assert.DoesNotContain("PickMultipleFilesAsync", source);
        Assert.DoesNotContain("overwrite: true", source);
        Assert.DoesNotContain("Retry", source);
        Assert.DoesNotContain("Resume", source);
    }

    [Fact]
    public void MediaPickerUsesOneFilteredFileAndValidatesTheReturnedExtension()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");

        Assert.Contains("PickAndStartMediaUploadAsync", source);
        Assert.Contains("MediaFileTypeFilters", source);
        Assert.Contains("\".jpg\"", source);
        Assert.Contains("\".heic\"", source);
        Assert.Contains("\".mp4\"", source);
        Assert.Contains("\".mov\"", source);
        Assert.Contains("MediaFileExtensions.Contains(Path.GetExtension(sourcePath))", source);
        Assert.Contains("upload.unsupported_media_type", source);
        Assert.DoesNotContain("PickMultipleFilesAsync", source);
    }

    [Fact]
    public void DroppedMediaPathReusesTheSameSingleFileNoOverwriteUpload()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");

        Assert.Contains("StartMediaUploadAsync", source);
        Assert.Contains("StartUploadFromPathCoreAsync", source);
        Assert.Contains("IsSupportedMediaPath(sourcePath)", source);
        Assert.Equal(1, CountOccurrences(source, "new FileStream("));
        Assert.Equal(1, CountOccurrences(source, "new FileUploadRequest("));
        Assert.Equal(1, CountOccurrences(source, "_ = RunUploadAsync(running, request)"));
        Assert.Contains("overwrite: false", source);
    }

    [Fact]
    public void UploadUsesUniqueActivityCancellationAndReportsCompletionWithoutPaths()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");

        Assert.Contains("new RunningTransfer(", source);
        Assert.Contains("Guid.NewGuid(),", source);
        Assert.Contains("IsMedia: requiresMediaExtension", source);
        Assert.Contains("item.ActivityId == activityId", source);
        Assert.Contains("running.ActivityId", source);
        Assert.Contains("UploadFinished?.Invoke(new ForegroundUploadFinished(", source);
        Assert.DoesNotContain("sourcePath,\n                result", source);
    }

    [Fact]
    public void FilesPageRefreshesOnlyTheFrozenFolderAfterConfirmedSuccess()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/FilesPage.xaml.cs");

        Assert.Contains("_transfers.UploadFinished += Transfers_UploadFinished", source);
        Assert.Contains("finished.Result.Status == MutationResultStatus.ConfirmedSuccess", source);
        Assert.Contains("_viewModel.CurrentPath", source);
        Assert.Contains("finished.FolderPath", source);
        Assert.Contains("await RunAsync(_viewModel.RefreshAsync)", source);
        Assert.Contains("UploadNeedsReview.IsOpen = true", source);
        Assert.Contains("_transfers.UploadFinished -= Transfers_UploadFinished", source);
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

    private static int CountOccurrences(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;
}
