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
        Assert.Contains("PickMultipleFilesAsync()", source);
        Assert.Contains("picker.FileTypeFilter.Add(filter)", source);
        Assert.Contains("return result?.Path;", source);
        Assert.Contains("Win32Interop.GetWindowIdFromWindow", source);
        Assert.Contains("WindowNative.GetWindowHandle(window)", source);
        Assert.DoesNotContain("using Windows.Storage.Pickers;", source);
        Assert.DoesNotContain("InitializeWithWindow.Initialize", source);
    }

    [Fact]
    public void FolderPickerUsesCurrentWindowAndBuildsThePlanBeforeAnyNasWrite()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");

        Assert.Contains("new FolderPicker(windowId)", source);
        Assert.Contains("PickSingleFolderAsync()", source);
        var pick = SliceMethod(
            source,
            "public async Task<FolderUploadPlanResult?> PickFolderUploadPlanAsync",
            "public Task<FolderUploadPlanResult> PlanFolderUploadAsync");
        Assert.Contains("BoundedFolderUploadPlan.Create(sourcePath)", pick);
        Assert.DoesNotContain("CreateFolderAsync", pick);
        Assert.DoesNotContain("UploadFileAsync", pick);
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
        var prepare = method.IndexOf("StartUploadFromPathCoreAsync(", cancelled, StringComparison.Ordinal);
        Assert.True(cancelled >= 0 && prepare > cancelled);
        Assert.Contains("return null;", method[cancelled..prepare]);
        Assert.DoesNotContain("UploadFileAsync", method[..prepare]);
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
        Assert.Contains("PickMultipleFilesAsync", source);
        Assert.Contains("StartUploadBatch", source);
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
        var mediaPicker = SliceMethod(
            source,
            "private async Task<PhotoMediaUploadStart?> PickAndStartUploadCoreAsync",
            "private Task<PhotoMediaUploadStart?> StartUploadFromPathCoreAsync");
        Assert.Contains("PickSingleFilePathAsync", mediaPicker);
        Assert.DoesNotContain("PickMultipleFilePathsAsync", mediaPicker);
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
        Assert.Equal(1, CountOccurrences(source, "_ = RunUploadAsync(prepared.Running, prepared.Request)"));
        Assert.Contains("overwrite: false", source);
        Assert.Contains("UploadTarget: uploadTarget", source);
        Assert.Contains("CreateUploadTargetKey(profileId, folderPath, fileName)", source);
        Assert.Contains("item.UploadTarget == uploadTarget", source);
        Assert.Contains("upload.target_busy", source);
        var start = SliceMethod(
            source,
            "private Task<PhotoMediaUploadStart?> StartUploadFromPathCoreAsync",
            "private PreparedUpload PrepareUpload");
        Assert.True(
            start.IndexOf("PrepareUpload(", StringComparison.Ordinal) <
            start.IndexOf("_ = RunUploadAsync(prepared.Running, prepared.Request)", StringComparison.Ordinal));
    }

    [Fact]
    public void DroppedFilePathReusesTheSameSingleFileNoOverwriteUpload()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");

        Assert.Contains("public async Task<bool> StartUploadAsync(", source);
        Assert.Contains("StartUploadFromPathCoreAsync(", source);
        Assert.Contains("requiresMediaExtension: false", source);
        Assert.Equal(1, CountOccurrences(source, "new FileStream("));
        Assert.Equal(1, CountOccurrences(source, "new FileUploadRequest("));
        Assert.Equal(1, CountOccurrences(source, "_ = RunUploadAsync(prepared.Running, prepared.Request)"));
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
    public void BoundedBatchReservesTargetsStopsAfterCancellationAndReportsOnlySummary()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");

        Assert.Contains("BoundedFileUploadBatch.ValidatePaths(sourcePaths)", source);
        Assert.Contains("_batchReservations.Add(target, batchId)", source);
        Assert.Contains("_batchCancellations.Add(batchId, batchCancellation)", source);
        Assert.Contains("CancellationRequestedAfterSubmission", source);
        Assert.Contains("result.Status == MutationResultStatus.CancellationRequestedAfterSubmission", source);
        Assert.Contains("batchCancellation.Token", source);
        Assert.Contains("if (!running.IsBatch)", source);
        Assert.Contains("UploadBatchFinished?.Invoke(new ForegroundUploadBatchFinished(", source);
        Assert.Contains("shouldNotify = !_disposed", source);
        Assert.DoesNotContain("sourcePaths,\n            summary", source);
    }

    [Fact]
    public void FolderUploadCreatesParentsFirstThenUploadsStrictlyWithoutOverwrite()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");
        var execute = SliceMethod(
            source,
            "private async Task RunFolderUploadBatchAsync",
            "private static FileUploadBatchAttempt ToFolderUploadAttempt");

        var create = execute.IndexOf("mutationRepository.CreateFolderAsync(", StringComparison.Ordinal);
        var upload = execute.IndexOf("await RunUploadAsync(prepared.Running, prepared.Request)", StringComparison.Ordinal);
        Assert.True(create >= 0 && upload > create);
        Assert.Contains("BoundedFolderUploadBatch.RunAsync(", execute);
        Assert.Contains("BoundedFolderUploadPlan.IsCurrent(file)", execute);
        Assert.Contains("RemoteFolderForFile(folderPath, plan.RootName, file.RelativePath)", execute);
        Assert.Contains("FileMutationReviewBlocker.Current.Block", execute);
        Assert.Contains("FolderUploadBatchFinished?.Invoke", execute);
        Assert.Contains("await Task.Yield()", execute);
        Assert.Contains("token", execute);
        Assert.DoesNotContain("overwrite: true", execute);
        Assert.DoesNotContain("Retry", execute);
        Assert.DoesNotContain("Rollback", execute);

        var start = SliceMethod(
            source,
            "public FolderUploadBatchStart StartFolderUpload",
            "public async Task<bool> StartUploadAsync");
        Assert.Contains("var directoryTargets = plan.Directories", start);
        Assert.Contains("directoryTargets.Any(target =>", start);
        Assert.Contains("_folderBatchTargets.ContainsKey(target)", start);
        Assert.Contains("_folderBatchTargets.Add(target, batchId)", start);
        Assert.Contains("_batchReservations.Add(target, batchId)", start);
        Assert.Contains("plan.Directories.Any(directory =>", start);
        Assert.Contains("FileMutationReviewBlocker.Current.Find", start);

        var prepare = SliceMethod(
            source,
            "private PreparedUpload PrepareUpload",
            "public void Cancel");
        Assert.Contains("_folderBatchTargets.TryGetValue(uploadTarget", prepare);
        Assert.Contains("folderOwner != batchId", prepare);
    }

    [Fact]
    public void FolderCreationRequiresExactTypedConfirmationAndUnknownResultStopsTheBatch()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Transfers/WindowsTransferPickerService.cs");
        var mapping = SliceMethod(
            source,
            "private static FileUploadBatchAttempt ToFolderUploadAttempt",
            "private static string RemoteParentForDirectory");

        Assert.Contains("MutationResultStatus.ConfirmedSuccess", mapping);
        Assert.Contains("ConfirmedItem is { IsDirectory: true }", mapping);
        Assert.Contains("string.Equals(item.Path, proposedPath, StringComparison.Ordinal)", mapping);
        Assert.Contains("string.Equals(item.Name, name, StringComparison.Ordinal)", mapping);
        Assert.Contains("MutationResultStatus.SubmittedButUnverified", mapping);
        Assert.Contains("MutationResultStatus.CancellationRequestedAfterSubmission", mapping);
        Assert.Contains("FileUploadBatchAttemptStatus.NeedsReview, StopBatch: true", mapping);
        Assert.Contains("MutationResultStatus.CancelledBeforeSubmission", mapping);
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
