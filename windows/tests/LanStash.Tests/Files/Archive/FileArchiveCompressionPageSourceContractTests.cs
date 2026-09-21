using System.Xml.Linq;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveCompressionPageSourceContractTests
{
    [Fact]
    public void PageUsesFullCompressionSelectionAndAccessibleDialog()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilesPage.xaml");
        var page = Read(
            "windows/src/LanStash.App/Views/FilesPage.ArchiveCompression.cs");
        _ = XDocument.Parse(xaml);

        Assert.Contains("x:Name=\"CreateArchiveButton\"", xaml);
        Assert.Contains("x:Name=\"CreateArchiveSelectedButton\"", xaml);
        Assert.Contains("x:Name=\"FileArchiveCompressionStatus\"", xaml);
        Assert.Contains("sources.Length == 0", page);
        var selection = Read("windows/src/LanStash.App/Views/FilesPage.BatchDownload.cs");
        Assert.DoesNotContain("FileCopyMoveBatchViewModel.MaximumItemCount", selection);
        Assert.DoesNotContain("FileRecycleBatchViewModel.MaximumItemCount", selection);
        Assert.Contains("CanSelectForBatchRecycle(added.Item)", selection);
        Assert.Contains("CanSelectForBatchRestore(added.Item)", selection);
        Assert.DoesNotContain("BoundedFileDownloadBatch.MaximumFileCount", selection);
        Assert.Contains("CreateArchiveSelectedButton.IsEnabled = _batchSelection.Count > 0", selection);
        Assert.DoesNotContain("FileArchiveCompressionSelectionLimit", selection);
        Assert.Contains("FileLocationSource.Remote or FileLocationSource.Recycle", page);
        Assert.Contains("new ContentDialog", page);
        Assert.Contains("AutomationProperties.SetName", page);
        Assert.Contains("new ProgressRing", page);
        Assert.Contains("_archiveCompressionCancellation?.Cancel()", page);
    }

    [Fact]
    public void AdvancedOptionsRemainBoundToReadbackAndPasswordsAreNotKeptInRecovery()
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
        Assert.Contains("[\"format\"] = options.FormatValue", transport);
        Assert.Contains("[\"level\"] = options.LevelValue", transport);
        Assert.Contains("new PasswordBox", page);
        Assert.Contains("passwordBox.Password = string.Empty", page);
        Assert.Contains("FileArchiveFormat.SevenZip", page);
        Assert.Contains("Options = options", page);
        Assert.Contains("Password = null", repository);
        Assert.Contains("OptionsSignature", repository);
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
