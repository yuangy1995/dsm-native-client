using System.Xml.Linq;

namespace LanStash.Tests.Files.DirectorySize;

public sealed class FileDirectorySizePageSourceContractTests
{
    private static readonly string Root = FindRoot();

    [Fact]
    public void PropertiesCommandIsKeyboardAccessibleAndFolderScoped()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilesPage.xaml");
        var page = Read("windows/src/LanStash.App/Views/FilesPage.DirectorySize.cs");

        Assert.Contains("x:Uid=\"FileDirectorySizeAction\"", xaml, StringComparison.Ordinal);
        Assert.Contains("MinHeight=\"44\"", xaml, StringComparison.Ordinal);
        Assert.Contains("Key=\"Enter\"", xaml, StringComparison.Ordinal);
        Assert.Contains("Modifiers=\"Menu\"", xaml, StringComparison.Ordinal);
        Assert.Contains("SelectedItem is { IsDirectory: true }", page, StringComparison.Ordinal);
    }

    [Fact]
    public void DialogUsesExplicitCalculationAndAccessibleNativeControls()
    {
        var source = Read(
            "windows/src/LanStash.App/Features/Files/DirectorySize/FileDirectorySizeDialogContent.cs");
        var page = Read("windows/src/LanStash.App/Views/FilesPage.DirectorySize.cs");

        Assert.Contains("new ContentDialog", page, StringComparison.Ordinal);
        Assert.Contains("AutomationLiveSetting.Polite", source, StringComparison.Ordinal);
        Assert.Contains("AutomationProperties.SetName(_status, _status.Text)", source, StringComparison.Ordinal);
        Assert.Contains("new Grid { ColumnSpacing = 8 }", source, StringComparison.Ordinal);
        Assert.Contains("Orientation = Orientation.Vertical", source, StringComparison.Ordinal);
        Assert.Contains("TextWrapping = TextWrapping.Wrap", source, StringComparison.Ordinal);
        Assert.Contains("MinHeight = 44", source, StringComparison.Ordinal);
        Assert.DoesNotContain("CalculateAsync();\n        UpdateState", page, StringComparison.Ordinal);
    }

    [Fact]
    public void DirectorySizeResourcesMatchInEnglishAndChinese()
    {
        var english = Keys("windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = Keys("windows/src/LanStash.App/Strings/zh-CN/Resources.resw");
        var keys = english.Where(key => key.StartsWith("FileDirectorySize", StringComparison.Ordinal))
            .Order(StringComparer.Ordinal).ToArray();

        Assert.NotEmpty(keys);
        Assert.Equal(keys, chinese.Where(key => key.StartsWith(
            "FileDirectorySize", StringComparison.Ordinal)).Order(StringComparer.Ordinal));
    }

    private static HashSet<string> Keys(string path) =>
        XDocument.Load(Path.Combine(Root, path)).Root!.Elements("data")
            .Select(element => (string?)element.Attribute("name"))
            .Where(name => name is not null).Select(name => name!).ToHashSet(StringComparer.Ordinal);

    private static string Read(string path) => File.ReadAllText(Path.Combine(Root, path));

    private static string FindRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !File.Exists(Path.Combine(directory.FullName, "AGENTS.md")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new DirectoryNotFoundException();
    }
}
