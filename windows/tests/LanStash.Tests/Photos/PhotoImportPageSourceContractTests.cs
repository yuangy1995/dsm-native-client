namespace LanStash.Tests;

public sealed class PhotoImportPageSourceContractTests
{
    [Fact]
    public void ImportEntryIsVisibleAcrossFiveStatesAndUsesNativeAccessibleControls()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml");

        Assert.Contains("x:Name=\"ImportButton\"", xaml);
        Assert.Contains("MinWidth=\"48\"", Slice(xaml, "x:Name=\"ImportButton\"", "/>"));
        Assert.Contains("MinHeight=\"48\"", Slice(xaml, "x:Name=\"ImportButton\"", "/>"));
        Assert.Contains("Key=\"I\"", xaml);
        Assert.Contains("Modifiers=\"Control\"", xaml);
        Assert.Contains("x:Name=\"PhotoImportTargetText\"", xaml);
        Assert.Contains("x:Name=\"ImportStatus\"", xaml);
        Assert.Contains("AutomationProperties.LiveSetting=\"Polite\"", xaml);
        Assert.True(xaml.IndexOf("x:Name=\"ImportButton\"", StringComparison.Ordinal) <
            xaml.IndexOf("x:Name=\"BrowserContentHost\"", StringComparison.Ordinal));
    }

    [Fact]
    public void PageFreezesCurrentFolderOrTimelineRootAndRefreshesOnlyCurrentConfirmation()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/PhotosPage.Import.cs");
        var completionHandler = Slice(
            source,
            "private void PhotoImport_Changed()",
            "private void UpdatePhotoImportState()");

        Assert.Contains("_dataSource.ProfileId", source);
        Assert.Contains("_dataSource,", source);
        Assert.Contains("_viewModel.CurrentPath", source);
        Assert.Contains("PhotoImportMode.Timeline", source);
        Assert.Contains("TryConsumeCurrentConfirmedCompletion", source);
        Assert.True(
            completionHandler.IndexOf("UpdatePhotoImportContext();", StringComparison.Ordinal) <
            completionHandler.IndexOf("TryConsumeCurrentConfirmedCompletion", StringComparison.Ordinal));
        Assert.Contains("await TimelineView.RefreshAsync()", source);
        Assert.Contains("await RunLocationChangeAsync(_viewModel.RefreshAsync)", source);
        Assert.Contains("DeactivatePhotoImport", source);
        Assert.Contains("DisposePhotoImport", source);
        Assert.Contains("AutomationProperties.SetName(PhotoImportTargetText, targetText)", source);
        Assert.DoesNotContain("UploadFileAsync", source);
        Assert.DoesNotContain("overwrite", source, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ImportBusinessRemainsOutsideLargePhotosPageFile()
    {
        var main = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml.cs");
        var import = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.Import.cs");

        Assert.Contains("InitializePhotoImport();", main);
        Assert.Contains("UpdatePhotoImportState();", main);
        Assert.Contains("DisposePhotoImport();", main);
        Assert.Contains("StartPhotoImportAsync", import);
        Assert.DoesNotContain("PickAndStartMediaUploadAsync", main);
    }

    [Fact]
    public void DesktopDropAcceptsExactlyOneLocalMediaFileAndReusesImportCoordinator()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml");
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/PhotosPage.Import.cs");

        Assert.Contains("AllowDrop=\"True\"", xaml);
        Assert.Contains("DragOver=\"PhotoImport_DragOver\"", xaml);
        Assert.Contains("Drop=\"PhotoImport_Drop\"", xaml);
        Assert.Contains("x:Name=\"PhotoImportDropOverlay\"", xaml);
        Assert.Contains("ThemeResource", Slice(xaml, "x:Name=\"PhotoImportDropOverlay\"", "</Border>"));
        Assert.Contains("StandardDataFormats.StorageItems", source);
        Assert.Contains("items.Count != 1", source);
        Assert.Contains("items[0] is not StorageFile", source);
        Assert.Contains("string.IsNullOrWhiteSpace(file.Path)", source);
        Assert.Contains("IsSupportedMediaPath(file.Path)", source);
        Assert.Contains("DataPackageOperation.Copy", source);
        Assert.Contains("_photoImport!.StartDroppedAsync(sourcePath)", source);
        Assert.Contains("_photoImport?.ReportInvalidDrop()", source);
        Assert.Contains("PhotoViewerHost.Visibility != Visibility.Visible", source);
        Assert.Contains("_photoDragGeneration", source);
        Assert.DoesNotContain("UploadFileAsync", source);
        Assert.DoesNotContain("overwrite", source, StringComparison.OrdinalIgnoreCase);
    }

    private static string Slice(string source, string start, string end)
    {
        var startIndex = source.IndexOf(start, StringComparison.Ordinal);
        var endIndex = source.IndexOf(end, startIndex, StringComparison.Ordinal);
        Assert.True(startIndex >= 0 && endIndex > startIndex);
        return source[startIndex..endIndex];
    }

    private static string ReadRepositoryFile(string relativePath)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(candidate))
            {
                return File.ReadAllText(candidate);
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException(relativePath);
    }
}
