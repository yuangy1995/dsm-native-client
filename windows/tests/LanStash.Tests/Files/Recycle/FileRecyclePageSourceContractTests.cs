namespace LanStash.Tests.Files.Recycle;

public sealed class FileRecyclePageSourceContractTests
{
    [Fact]
    public void PageExposesRecycleCommandsAndKeepsBusinessLogicInPartial()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilesPage.xaml");
        var page = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var partial = Read("windows/src/LanStash.App/Views/FilesPage.Recycle.cs");
        var dialog = Read("windows/src/LanStash.App/Features/Files/Recycle/FileRecycleDialogContent.cs");
        var model = Read("windows/src/LanStash.App/Features/Files/Recycle/FileRecycleViewModel.cs");
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains("x:Name=\"MoveToRecycleButton\"", xaml);
        Assert.Contains("x:Name=\"RestoreFromRecycleButton\"", xaml);
        Assert.Contains("MinHeight=\"48\"", xaml);
        Assert.DoesNotContain("MoveToRecycleAsync", page);
        Assert.DoesNotContain("RestoreFromRecycleAsync", page);
        Assert.Contains("MoveToRecycleAsync", model);
        Assert.Contains("RestoreFromRecycleAsync", model);
        Assert.Contains("ContentDialog", partial);
        Assert.Contains("FileRecycleDialogContent.Build(model, localization)", partial);
        Assert.Contains("FileRecycleStatusAutomationName", dialog);
        Assert.Contains("FileRecycleReviewBlocker.Current", shell);
        Assert.Contains("recycleRepository:", shell);
        Assert.Contains("recycleReviewBlocker:", shell);
        Assert.Contains("CloseRecycleDialog();", page);
    }

    [Fact]
    public void RecycleActionsStayBehindReadOnlyAndReviewSafetyDoors()
    {
        var partial = Read("windows/src/LanStash.App/Views/FilesPage.Recycle.cs");
        var dialog = Read("windows/src/LanStash.App/Features/Files/Recycle/FileRecycleDialogContent.cs");
        var model = Read("windows/src/LanStash.App/Features/Files/Recycle/FileRecycleViewModel.cs");

        Assert.Contains("FileLocationSource.Remote", model);
        Assert.Contains("FileLocationSource.Recycle", model);
        Assert.Contains("CanMoveToRecycle()", partial);
        Assert.Contains("CanRestoreFromRecycle()", partial);
        Assert.Contains("FileRecyclePresentationState.NeedsReview", dialog);
        Assert.Contains("model.State != FileRecyclePresentationState.ConfirmedSuccess", partial);
        Assert.Contains("AutomationLiveSetting.Assertive", dialog);
        Assert.Contains("AutomationLiveSetting.Polite", dialog);
        Assert.DoesNotContain("IsDirectory: false", model);
        Assert.Contains("FileRecycleMoveFolderTitle", partial);
        Assert.Contains("FileRecycleMoveFolderMessage", dialog);
        Assert.DoesNotContain("DeleteFilesAsync", partial);
        Assert.DoesNotContain("DeleteFileAsync", partial);
        Assert.DoesNotContain("RemoveAsync", partial);
        Assert.DoesNotContain("UploadAsync", partial);
    }

    private static string Read(string relativePath) =>
        File.ReadAllText(Path.Combine(FindRoot(), relativePath));

    private static string FindRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "AGENTS.md")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new DirectoryNotFoundException("repository root not found");
    }
}
