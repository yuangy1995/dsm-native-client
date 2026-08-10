namespace LanStash.Tests.Files.Preview;

public sealed class FilePreviewPageSourceContractTests
{
    [Fact]
    public void PreviewUsesNativeReadOnlyPresentersAndNoWholeMediaArtifact()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilePreviewPane.xaml");
        var pane = Read("windows/src/LanStash.App/Views/FilePreviewPane.xaml.cs");
        var media = Read(
            "windows/src/LanStash.App/Features/Files/Preview/StrictRangeMediaSource.cs");
        var model = Read(
            "windows/src/LanStash.App/Features/Files/Preview/FilePreviewViewModel.cs");
        var artifacts = Read(
            "windows/src/LanStash.App/Features/Files/Preview/FilePreviewArtifactStore.cs");

        Assert.Contains("<Image", xaml);
        Assert.Contains("<MediaPlayerElement", xaml);
        Assert.Contains("AreTransportControlsEnabled=\"True\"", xaml);
        Assert.Contains("AutoPlay=\"False\"", xaml);
        Assert.Contains("PdfDocument.LoadFromFileAsync", pane);
        Assert.Contains("BitmapDecoder.CreateAsync", pane);
        Assert.Contains("DecodePixelWidth", pane);
        Assert.Contains("DecodePixelHeight", pane);
        Assert.Contains("2048d / Math.Max", pane);
        Assert.Contains("new PdfPageRenderOptions", pane);
        Assert.Contains("DestinationWidth", pane);
        Assert.Contains("DestinationHeight", pane);
        Assert.Contains("MediaSource.CreateFromStream", pane);
        Assert.Contains("IFilePreviewMetadataReader", model);
        Assert.Contains("FilePreviewMediaMetadata", model);
        Assert.Contains("BitmapDecoder.CreateAsync", model);
        Assert.Contains("RetrievePropertiesAsync", model);
        Assert.Contains("System.Photo.DateTaken", model);
        Assert.Contains("System.Photo.CameraManufacturer", model);
        Assert.Contains("System.Photo.CameraModel", model);
        Assert.Contains("MediaMetadata: metadata", model);
        Assert.Contains("MediaMetadata: media.Metadata", model);
        Assert.Contains("IRandomAccessStream", media);
        Assert.Contains("IInputStream", media);
        Assert.Contains("MaximumRangeLength = 4 * 1024 * 1024", media);
        Assert.Contains("IsoBmffVideoMetadataReader.TryRead", media);
        Assert.Contains("expectedContentVersion: _contentVersion", media);
        Assert.Contains("expectedTotalLength: _totalLength", media);
        Assert.Contains("CloneStream()", media);
        Assert.Contains("StrictRangeReadCursor", media);
        Assert.Contains("generation != _generation", media);
        Assert.Contains("await _serial.WaitAsync", media);
        Assert.DoesNotContain("_initialization.Dispose()", media);
        foreach (var forbiddenMetadata in new[]
        {
            "Latitude", "Longitude", "MakerNote", "CameraSerialNumber", "LensSerialNumber",
        })
        {
            Assert.DoesNotContain(forbiddenMetadata, model);
            Assert.DoesNotContain(forbiddenMetadata, media);
        }
        Assert.Contains("_cleanupAttempts >= 3", artifacts);
        Assert.Contains("_disposed = true", artifacts);
        Assert.DoesNotContain("_disposed = true;\n        try", artifacts);
        var mediaLoader = Slice(
            model,
            "private async Task LoadMediaAsync",
            "private static void ValidateRange");
        Assert.DoesNotContain("_artifacts", mediaLoader);
        Assert.Contains("StrictRangeMediaSource.CreateAsync", mediaLoader);

        foreach (var forbidden in new[]
        {
            "WebView", "CreateFromUri", "TextEditor", "Transcode", "CloudDrive",
            "BackgroundTask", "FileSavePicker", "UploadFileAsync",
        })
        {
            Assert.DoesNotContain(forbidden, xaml);
            Assert.DoesNotContain(forbidden, pane);
            Assert.DoesNotContain(forbidden, media);
        }
    }

    [Fact]
    public void FilesUsesExplicitPreviewActionsAndAdaptiveSinglePageNavigation()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilesPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");

        Assert.Contains("x:Name=\"PreviewButton\"", xaml);
        Assert.Contains("x:Name=\"PreviewPane\"", xaml);
        Assert.Contains("x:Name=\"BrowserColumn\"", xaml);
        Assert.Contains("x:Name=\"PreviewColumn\"", xaml);
        Assert.Contains(
            "ActualWidth >= (_locationsAreWide == true ? 1280 : 1000)",
            source);
        Assert.Contains("BrowserSurface.Visibility = isOpen && !isWide", source);
        Assert.Contains("OpenPreviewAsync(entry)", source);
        Assert.Contains("OpenPreviewAsync(selected)", source);
        Assert.Contains("ClosePreviewAsync()", source);
        Assert.Contains("await PreviewPane.CloseAsync();", source);
        Assert.Contains("DownloadItemAsync(e.Target.ProfileId, e.Target.Item)", source);
        Assert.Contains("TryGetSaveCopyTarget", source);
        Assert.DoesNotContain("PreviewPane_SaveCopyRequested(object? sender, EventArgs e)", source);
        Assert.Contains("FileList.Focus(FocusState.Programmatic)", source);
        Assert.Contains("FileGrid.Focus(FocusState.Programmatic)", source);
    }

    [Fact]
    public void PaneKeepsKeyboardNarratorThemeAndTouchContracts()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilePreviewPane.xaml");

        Assert.Contains("Key=\"Escape\"", xaml);
        Assert.Contains("Key=\"Left\" Modifiers=\"Menu\"", xaml);
        Assert.Contains("AutomationProperties.HeadingLevel=\"Level2\"", xaml);
        Assert.True(Count(xaml, "AutomationProperties.LiveSetting=\"Polite\"") >= 3);
        Assert.True(Count(xaml, "MinHeight=\"44\"") >= 8);
        Assert.Contains("ThemeResource", xaml);
        Assert.Contains("BackButton.Focus(FocusState.Programmatic)",
            Read("windows/src/LanStash.App/Views/FilePreviewPane.xaml.cs"));
        Assert.DoesNotContain("Background=\"#", xaml);
        Assert.DoesNotContain("Foreground=\"#", xaml);
    }

    [Fact]
    public void ShellNeverFallsThroughFilesWhenPreviewInterfaceIsUnavailable()
    {
        var source = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var branch = Slice(
            source,
            "if (module == AppModule.Files",
            "if (module == AppModule.Transfers");

        Assert.Contains("repository as IFilePreviewRepository", branch);
        Assert.Contains("UnavailableFilePreviewRepository", branch);
        Assert.Contains("ContentFrame.Content = _files;", branch);
        Assert.Contains("return;", branch);
    }

    private static string Read(string path) =>
        File.ReadAllText(Path.Combine(RepositoryRoot(), path));

    private static string Slice(string source, string start, string end)
    {
        var startIndex = source.IndexOf(start, StringComparison.Ordinal);
        var endIndex = source.IndexOf(end, startIndex, StringComparison.Ordinal);
        Assert.True(startIndex >= 0 && endIndex > startIndex);
        return source[startIndex..endIndex];
    }

    private static int Count(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !Directory.Exists(Path.Combine(directory.FullName, "windows")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new DirectoryNotFoundException();
    }
}
