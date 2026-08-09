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
        Assert.Contains("WindowsPackageType", systemShare, StringComparison.Ordinal);
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
