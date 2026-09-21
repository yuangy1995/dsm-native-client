using System.Xml.Linq;

namespace LanStash.Tests;

public sealed class WindowsNativeWorkspaceSourceTests
{
    [Fact]
    public void NativeXamlSymbolNamesExistInTheTargetWindowsAppSdk()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "windows/src/LanStash.App/Views"))) root = root.Parent;
        Assert.NotNull(root);
        var valid = Enum.GetNames<Microsoft.UI.Xaml.Controls.Symbol>().ToHashSet(StringComparer.Ordinal);
        var errors = new List<string>();
        foreach (var path in Directory.EnumerateFiles(Path.Combine(root.FullName, "windows/src/LanStash.App/Views"), "*.xaml", SearchOption.AllDirectories))
        {
            foreach (var attribute in XDocument.Load(path).Descendants().Attributes()
                .Where(attribute => attribute.Name.LocalName is "Icon" or "Symbol"))
            {
                if (attribute.Value.Length > 0 && !attribute.Value.StartsWith('{') && !valid.Contains(attribute.Value))
                    errors.Add($"{Path.GetFileName(path)}: {attribute.Name}={attribute.Value}");
            }
        }
        Assert.True(errors.Count == 0, string.Join(Environment.NewLine, errors));
    }

    [Fact]
    public void FileWorkspaceKeepsVirtualizationAndAllFiveStates()
    {
        var document = XDocument.Parse(Read("windows/src/LanStash.App/Views/FilesPage.xaml"));
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        foreach (var name in new[] { "LoadingState", "EmptyState", "FilteredEmptyState", "ErrorState", "ContentState" })
            Assert.Single(document.Descendants(), element => (string?)element.Attribute(x + "Name") == name);
        foreach (var name in new[] { "FileList", "FileGrid" })
        {
            var list = document.Descendants().Single(element => (string?)element.Attribute(x + "Name") == name);
            Assert.DoesNotContain(list.Ancestors(), element => element.Name.LocalName == "ScrollViewer");
        }
        var commands = document.Descendants().Single(element => (string?)element.Attribute(x + "Name") == "FileToolbar");
        Assert.Contains(commands.Descendants(), element => (string?)element.Attribute(x + "Name") == "GridLayoutButton");
        Assert.Contains(commands.Descendants(), element => (string?)element.Attribute(x + "Name") == "UploadButton");
    }

    [Fact]
    public void ThemeHasNativeHighContrastAndBothAppearanceModes()
    {
        var document = XDocument.Parse(Read("windows/src/LanStash.App/Themes/WorkspaceTheme.xaml"));
        XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
        foreach (var theme in new[] { "Light", "Default", "HighContrast" })
        {
            var dictionary = document.Descendants().Single(element => (string?)element.Attribute(x + "Key") == theme);
            Assert.Contains(dictionary.Elements(), element => (string?)element.Attribute(x + "Key") == "WorkspaceSurfaceBrush");
        }
    }

    [Fact]
    public void UnpackagedLanguageSelectionUsesWindowsAppSdk()
    {
        var source = Read("windows/src/LanStash.App/Localization/LocalizationService.cs");
        Assert.Contains("using Microsoft.Windows.Globalization;", source);
        Assert.DoesNotContain("using Windows.Globalization;", source);
    }

    [Fact]
    public void SmokeDataIsOnlyIncludedByExplicitTestBuild()
    {
        var document = XDocument.Parse(Read("windows/src/LanStash.App/LanStash.App.csproj"));
        var source = document.Descendants("Compile").Single(element => ((string?)element.Attribute("Include"))?.Contains("SmokeWorkspace") == true);
        Assert.Equal("'$(LanStashUiSmoke)' == 'true'", (string?)source.Parent?.Attribute("Condition"));
        Assert.Contains("#if LANSTASH_UI_SMOKE", Read("windows/src/LanStash.App/MainWindow.xaml.cs"));
    }

    private static string Read(string path)
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, path);
            if (File.Exists(candidate)) return File.ReadAllText(candidate);
        }
        throw new FileNotFoundException(path);
    }
}
