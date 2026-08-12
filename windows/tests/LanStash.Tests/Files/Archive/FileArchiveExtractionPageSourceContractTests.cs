using System.Xml.Linq;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveExtractionPageSourceContractTests
{
    [Fact]
    public void PageUsesSingleArchiveNativeDialogAndAccessibleKeyboardEntry()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilesPage.xaml");
        var page = Read(
            "windows/src/LanStash.App/Views/FilesPage.ArchiveExtraction.cs");
        _ = XDocument.Parse(xaml);

        Assert.Contains("x:Name=\"ExtractArchiveButton\"", xaml);
        Assert.Contains("Modifiers=\"Control,Shift\"", xaml);
        Assert.Contains("ExtractArchiveAccelerator_Invoked", xaml);
        Assert.Contains("FileLocationSource.Remote or FileLocationSource.Recycle", page);
        Assert.Contains("new ContentDialog", page);
        Assert.Contains("new ProgressRing", page);
        Assert.Contains("AutomationProperties.SetName", page);
        Assert.Contains("SupportedArchiveExtensions", page);
        Assert.Contains("\".zip\", \".7z\"", page);
    }

    [Fact]
    public void PageFreezesSourceAndRejectsLateResultsWithoutAdvancedSettings()
    {
        var page = Read(
            "windows/src/LanStash.App/Views/FilesPage.ArchiveExtraction.cs");

        Assert.Contains("ArchiveExtractionSourceIsCurrent", page);
        Assert.Contains("CanPresentArchiveExtraction", page);
        Assert.Contains("_archiveExtractionGeneration", page);
        Assert.Contains("outcome?.Result.RequiresRefresh == true", page);
        Assert.Contains("_archiveExtractionCancellation?.Cancel()", page);
        Assert.Contains("MutationResultStatus.PartialSuccess", page);
        Assert.Contains("ReferenceEquals(_archiveExtractionCancellation, completedCancellation)",
            page);
        Assert.Contains("FileArchiveExtractionPartialNeedsReview", page);
        Assert.Contains("FileArchiveExtractionPartialFailed", page);
        Assert.DoesNotContain("PasswordBox", page);
        Assert.DoesNotContain("codepage", page, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("overwrite: true", page, StringComparison.OrdinalIgnoreCase);
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
