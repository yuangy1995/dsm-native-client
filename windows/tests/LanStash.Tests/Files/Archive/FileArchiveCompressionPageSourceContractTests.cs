using System.Xml.Linq;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveCompressionPageSourceContractTests
{
    [Fact]
    public void PageUsesNativeBoundedSelectionAndAccessibleDialog()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilesPage.xaml");
        var page = Read(
            "windows/src/LanStash.App/Views/FilesPage.ArchiveCompression.cs");
        _ = XDocument.Parse(xaml);

        Assert.Contains("x:Name=\"CreateArchiveButton\"", xaml);
        Assert.Contains("x:Name=\"CreateArchiveSelectedButton\"", xaml);
        Assert.Contains("x:Name=\"FileArchiveCompressionStatus\"", xaml);
        Assert.Contains("sources.Length is < 1 or > 20", page);
        Assert.Contains("FileLocationSource.Remote or FileLocationSource.Recycle", page);
        Assert.Contains("new ContentDialog", page);
        Assert.Contains("AutomationProperties.SetName", page);
        Assert.Contains("new ProgressRing", page);
        Assert.Contains("_archiveCompressionCancellation?.Cancel()", page);
    }

    [Fact]
    public void ResultRequiresReadbackAndNeverExposesAdvancedArchiveSettings()
    {
        var page = Read(
            "windows/src/LanStash.App/Views/FilesPage.ArchiveCompression.cs");
        var transport = Read(
            "windows/src/LanStash.Infrastructure/DsmApiClient.cs");
        var repository = Read(
            "windows/src/LanStash.Infrastructure/Features/Files/Archive/DsmRepository.FileArchiveCompression.cs");

        Assert.Contains("outcome?.Result.RequiresRefresh == true", page);
        Assert.Contains("TryReadBackArchiveCompressionAsync", repository);
        Assert.Contains("!item.Item.IsDirectory && item.Item.Size > 0", repository);
        Assert.Contains("[\"format\"] = \"zip\"", transport);
        Assert.Contains("[\"level\"] = \"moderate\"", transport);
    }

    private static string Read(string relativePath) =>
        File.ReadAllText(Path.Combine(RepositoryRoot(), relativePath));

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "windows")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new DirectoryNotFoundException("repository root");
    }
}
