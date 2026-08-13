namespace LanStash.Tests.Files.Sharing;

public sealed class FileShareLinkPageSourceContractTests
{
    [Fact]
    public void FilesPageKeepsPasswordsOutOfClipboardAndSystemShare()
    {
        var root = RepositoryRoot();
        var page = File.ReadAllText(Path.Combine(root, "windows", "src", "LanStash.App", "Views", "FilesPage.xaml.cs"));
        var clipboard = File.ReadAllText(Path.Combine(root, "windows", "src", "LanStash.App", "Platform", "Sharing", "WindowsClipboard.cs"));
        var systemShare = File.ReadAllText(Path.Combine(root, "windows", "src", "LanStash.App", "Platform", "Sharing", "WindowsSystemShare.cs"));

        Assert.Contains("ConfirmedUrl", page, StringComparison.Ordinal);
        Assert.DoesNotContain("Password", clipboard, StringComparison.Ordinal);
        Assert.DoesNotContain("Password", systemShare, StringComparison.Ordinal);
        Assert.Contains("IsAllowedInHistory = false", clipboard, StringComparison.Ordinal);
        Assert.Contains("IsRoamable = false", clipboard, StringComparison.Ordinal);
        Assert.Contains("if (!accepted)", clipboard, StringComparison.Ordinal);
        Assert.True(
            clipboard.IndexOf("if (!accepted)", StringComparison.Ordinal) <
            clipboard.IndexOf("Clipboard.Flush()", StringComparison.Ordinal));
        Assert.Contains("DataTransferManager.As<IDataTransferManagerInterop>()", systemShare, StringComparison.Ordinal);
        Assert.Contains("WindowNative.GetWindowHandle(window)", systemShare, StringComparison.Ordinal);
        Assert.Contains("ShowShareUIForWindow(_windowHandle)", systemShare, StringComparison.Ordinal);
        Assert.Contains("args.Request.Data.SetWebLink(uri)", systemShare, StringComparison.Ordinal);
        Assert.DoesNotContain("SetText", systemShare, StringComparison.Ordinal);
        Assert.DoesNotContain("Properties.Description", systemShare, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkSystemShareTitle", systemShare, StringComparison.Ordinal);
        Assert.Contains("return false;", systemShare, StringComparison.Ordinal);
    }

    [Fact]
    public void DialogUsesLocalizedAccessibleNativeControls()
    {
        var root = RepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(root, "windows", "src", "LanStash.App", "Views", "FilesPage.xaml"));

        Assert.Contains("ShareLinkButton", xaml, StringComparison.Ordinal);
        Assert.Contains("MinHeight=\"44\"", xaml, StringComparison.Ordinal);
        Assert.DoesNotContain("Text=\"http", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Content=\"http", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("FileShareLinkConfirmedUrlAutomationName", File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Views", "FilesPage.xaml.cs")), StringComparison.Ordinal);
    }

    [Fact]
    public void ShellBindsSharingToTheSameActiveRepositoryAndProfile()
    {
        var root = RepositoryRoot();
        var shell = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Views", "ShellPage.xaml.cs"));

        Assert.Contains("repository as IFileShareLinkRepository", shell, StringComparison.Ordinal);
        Assert.Contains("shareRepository?.ProfileId != profile.Id", shell, StringComparison.Ordinal);
        Assert.Contains("shareRepository,", shell, StringComparison.Ordinal);
    }

    [Fact]
    public void PageClosesCreatingDialogAndKeepsAPathLevelReviewBlocker()
    {
        var root = RepositoryRoot();
        var page = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Views", "FilesPage.xaml.cs"));

        Assert.Contains("_shareReviewBlocker", page, StringComparison.Ordinal);
        Assert.Contains("initialNeedsReview: _shareReviewBlocker.Contains(_profileId, selected.Path)", page, StringComparison.Ordinal);
        Assert.Contains("_shareReviewBlocker.Block(_profileId, model.TargetPath)", page, StringComparison.Ordinal);
        Assert.Contains("CloseShareLinkDialog();", page, StringComparison.Ordinal);
        Assert.Contains("model?.RequestCancellation();", page, StringComparison.Ordinal);
        Assert.Contains("model?.Dispose();", page, StringComparison.Ordinal);
        Assert.Contains("dialog.Hide();", page, StringComparison.Ordinal);
    }

    [Fact]
    public void ShellInjectsTheAppSessionProfileAndPathReviewBlocker()
    {
        var root = RepositoryRoot();
        var shell = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Views", "ShellPage.xaml.cs"));
        var blocker = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Features", "Files", "Sharing",
            "FileShareLinkReviewBlocker.cs"));

        Assert.Contains("FileShareLinkReviewBlocker.Current", shell, StringComparison.Ordinal);
        Assert.Contains("HashSet<(Guid ProfileId, string Path)>", blocker, StringComparison.Ordinal);
        Assert.Contains("public static FileShareLinkReviewBlocker Current", blocker, StringComparison.Ordinal);
    }

    [Fact]
    public void ManagementDialogCoversNativeAccessibleListAndDeleteStates()
    {
        var root = RepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Views", "FilesPage.xaml"));
        var management = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Views",
            "FileShareLinkManagementDialog.cs"));
        var pageManagement = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Views",
            "FilesPage.ShareManagement.cs"));

        Assert.Contains("ManageShareLinksButton", xaml, StringComparison.Ordinal);
        Assert.Contains("CommandBar.SecondaryCommands", xaml, StringComparison.Ordinal);
        Assert.Contains("new FileShareLinkManagementDialog(", pageManagement, StringComparison.Ordinal);
        Assert.Contains("ContentDialog", management, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkManagementState.Loading", management, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkManagementState.Empty", management, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkManagementState.Error", management, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkManagementState.Content", management, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkDeletionState.Confirming", management, StringComparison.Ordinal);
        Assert.Contains("ConfirmDeleteAsync", management, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.SetName", management, StringComparison.Ordinal);
        Assert.Contains("MinHeight = 44", management, StringComparison.Ordinal);
        Assert.Contains("Symbol.Copy", management, StringComparison.Ordinal);
        Assert.Contains("Symbol.Delete", management, StringComparison.Ordinal);
        Assert.DoesNotContain("Password =", management, StringComparison.Ordinal);
    }

    [Fact]
    public void ManagementResourcesAreBilingualAndPageClosesItsDialog()
    {
        var root = RepositoryRoot();
        var page = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Views", "FilesPage.xaml.cs"));
        var management = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Views",
            "FilesPage.ShareManagement.cs"));
        var english = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Strings", "en-US", "Resources.resw"));
        var chinese = File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Strings", "zh-CN", "Resources.resw"));

        Assert.Contains("CloseShareManagementDialog();", page, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkManageDeleteMessage", english, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkManageDeleteMessage", chinese, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkManageReviewMessage", english, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkManageReviewMessage", chinese, StringComparison.Ordinal);
        Assert.Contains("FileShareLinkManagementDialog", management, StringComparison.Ordinal);
        Assert.Contains("AutomationLiveSetting.Polite", File.ReadAllText(Path.Combine(
            root, "windows", "src", "LanStash.App", "Views",
            "FileShareLinkManagementDialog.cs")), StringComparison.Ordinal);
    }

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
