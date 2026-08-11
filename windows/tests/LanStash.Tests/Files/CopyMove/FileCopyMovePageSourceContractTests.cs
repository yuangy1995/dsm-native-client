namespace LanStash.Tests.Files.CopyMove;

public sealed class FileCopyMovePageSourceContractTests
{
    [Fact]
    public void PageKeepsBusinessLogicInPartialAndExposesAccessibleCommands()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilesPage.xaml");
        var page = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var partial = Read("windows/src/LanStash.App/Views/FilesPage.CopyMove.cs");
        var dialog = Read(
            "windows/src/LanStash.App/Features/Files/CopyMove/FileCopyMoveDialogContent.cs");

        Assert.Contains("x:Name=\"CopyFileButton\"", xaml);
        Assert.Contains("x:Name=\"MoveFileButton\"", xaml);
        Assert.Contains("x:Name=\"CopyMultipleButton\"", xaml);
        Assert.Contains("x:Name=\"MoveMultipleButton\"", xaml);
        Assert.Contains("x:Name=\"CopySelectedItemsButton\"", xaml);
        Assert.Contains("x:Name=\"MoveSelectedItemsButton\"", xaml);
        Assert.Equal(8, Count(xaml, "FileCopyMove"));
        Assert.Contains("MinHeight=\"48\"", xaml);
        Assert.DoesNotContain("CopyMoveAsync", page);
        Assert.Contains("CopyMoveAsync", partial);
        Assert.Contains("ContentDialog", partial);
        Assert.Contains("IFileCopyMoveFolderSource", partial);
        Assert.Contains("AutomationLiveSetting.Assertive", dialog);
        Assert.Contains("FileCopyMoveDialogContent.Build", partial);
        Assert.Contains("model.State != FileCopyMovePresentationState.ConfirmedSuccess", partial);
        Assert.DoesNotContain("ReviewAsync", partial);
        Assert.DoesNotContain("FileCopyMove_Review_Button", partial);
        Assert.Contains("IsReadOnlyLocation()", partial);
        Assert.Contains("FileCopyMoveViewModel.IsDestination(item.Path)", partial);
        Assert.DoesNotContain("IsDirectory: false", partial);
        Assert.Contains("FileCopyMoveDialogContent.TitleKey(model.Source.IsDirectory", partial);
    }

    [Fact]
    public void BatchPartialKeepsBoundedSelectionAndTypedSummary()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilesPage.xaml");
        var page = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var selection = Read("windows/src/LanStash.App/Views/FilesPage.BatchDownload.cs");
        var partial = Read("windows/src/LanStash.App/Views/FilesPage.BatchCopyMove.cs");
        var model = Read(
            "windows/src/LanStash.App/Features/Files/CopyMove/FileCopyMoveBatchViewModel.cs");

        Assert.Contains("x:Name=\"FileCopyMoveBatchStatus\"", xaml);
        Assert.Contains("AutomationProperties.LiveSetting=\"Polite\"", xaml);
        Assert.Contains("FileCopyMoveBatchViewModel.MaximumItemCount", partial);
        Assert.Contains("FileCopyMoveBatchViewModel.Validate", partial);
        Assert.Contains("FileBatchSelectionOperation.Copy", selection);
        Assert.Contains("FileBatchSelectionOperation.Move", selection);
        Assert.Contains("ContentDialog", partial);
        Assert.Contains("AutomationLiveSetting.Assertive", partial);
        Assert.Contains("model.Cancel()", partial);
        Assert.Contains("CloseBatchCopyMoveDialog();", page);
        Assert.Contains("NeedsReviewCount", partial);
        Assert.Contains("MaximumItemCount = 20", model);
        Assert.Contains("await _repository.CopyMoveAsync", model);
        Assert.Contains("BlockReview(source, destination)", model);
        Assert.DoesNotContain("Task.WhenAll", model);
        Assert.DoesNotContain("overwrite", partial, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void FolderPickerDoesNotNavigateOrMutatePrimaryBrowser()
    {
        var partial = Read("windows/src/LanStash.App/Views/FilesPage.CopyMove.cs");
        Assert.DoesNotContain("_viewModel.OpenLocationAsync", partial);
        Assert.DoesNotContain("_viewModel.OpenAsync", partial);
        Assert.DoesNotContain("DeleteFilesAsync", partial);
        Assert.DoesNotContain("DeleteFileAsync", partial);
        Assert.DoesNotContain("RemoveAsync", partial);
        Assert.DoesNotContain("overwrite", partial, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(1, Count(partial, "_viewModel.RefreshAsync"));
        Assert.Contains("string.Equals(_viewModel.CurrentPath, sourceParent", partial);
    }

    private static string Read(string relativePath) =>
        File.ReadAllText(Path.Combine(FindRoot(), relativePath));
    private static int Count(string value, string needle) =>
        (value.Length - value.Replace(needle, string.Empty, StringComparison.Ordinal).Length) / needle.Length;
    private static string FindRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "AGENTS.md"))) directory = directory.Parent;
        return directory?.FullName ?? throw new DirectoryNotFoundException("repository root not found");
    }
}
