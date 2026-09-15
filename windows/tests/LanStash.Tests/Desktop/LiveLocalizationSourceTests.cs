using LanStash.App.Localization;

namespace LanStash.Tests.Desktop;

public sealed class LiveLocalizationSourceTests
{
    [Theory]
    [InlineData("ModuleFiles", "ModuleFiles")]
    [InlineData("Settings.ThemeSystem", "Settings/ThemeSystem")]
    [InlineData("LoginTitle.Text", "LoginTitle/Text")]
    public void SegmentedResourceIdentifiersUseMrtPaths(string key, string path) =>
        Assert.Equal(path, WinUiLocalizationPlatform.ResourcePath(key));

    [Fact]
    public void LanguageChangeNeverRecreatesTheSessionShellOrTransferCoordinator()
    {
        var source = RepositorySource.Read("windows/src/LanStash.App/MainWindow.xaml.cs");
        var start = source.IndexOf("private void OnLanguageChanged", StringComparison.Ordinal);
        var end = source.IndexOf("private void OnWindowDestroyed", start, StringComparison.Ordinal);
        var language = source[start..end];
        Assert.Contains("DesktopLocalization.RefreshTree(RootFrame)", language);
        Assert.DoesNotContain("new ShellPage", language);
        Assert.DoesNotContain("new LoginPage", language);
        Assert.DoesNotContain(".Dispose()", language);
    }
}

internal static class RepositorySource
{
    internal static string Read(string path)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, path);
            if (File.Exists(candidate)) return File.ReadAllText(candidate);
            directory = directory.Parent;
        }
        throw new FileNotFoundException(path);
    }
}
