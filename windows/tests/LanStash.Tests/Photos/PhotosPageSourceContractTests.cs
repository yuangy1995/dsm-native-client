namespace LanStash.Tests;

public sealed class PhotosPageSourceContractTests
{
    [Fact]
    public void PageUsesDedicatedPhotoStateAndNativeFiveStateGrid()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml");
        var source = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml.cs");

        Assert.Contains("x:Name=\"LoadingState\"", xaml);
        Assert.Contains("x:Name=\"EmptyState\"", xaml);
        Assert.Contains("x:Name=\"FilteredEmptyState\"", xaml);
        Assert.Contains("x:Name=\"ErrorState\"", xaml);
        Assert.Contains("x:Name=\"ContentState\"", xaml);
        Assert.Contains("x:Name=\"PhotoGrid\"", xaml);
        Assert.Contains("x:Name=\"SpacePicker\"", xaml);
        Assert.Contains("x:Name=\"PathBreadcrumbs\"", xaml);
        Assert.Contains("x:Name=\"LoadMoreError\"", xaml);
        Assert.True(CountOccurrences(
            xaml,
            "AutomationProperties.LiveSetting=\"Polite\"") >= 6);
        var loadMoreError = Slice(
            xaml,
            "x:Name=\"LoadMoreError\"",
            "/>");
        Assert.Contains("AutomationProperties.LiveSetting=\"Polite\"", loadMoreError);
        Assert.Contains("new RepositoryPhotoBrowserDataSource(repository)", source);
        Assert.Contains("new PhotoBrowserViewModel()", source);
        Assert.Contains("new PhotoThumbnailScheduler()", source);

        Assert.DoesNotContain("Search", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("x:Name=\"ImportButton\"", xaml);
        Assert.Contains("Import_Click", xaml);
        Assert.DoesNotContain("Delete", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("CloudDrive", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Video", xaml, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void KeyboardTouchAndSelectionFollowWindowsPhotoBrowserRules()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml");
        var source = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml.cs");

        Assert.True(CountOccurrences(xaml, "MinHeight=\"44\"") >= 10);
        Assert.Contains("Key=\"Left\"", xaml);
        Assert.Contains("Key=\"Up\"", xaml);
        Assert.True(CountOccurrences(xaml, "Modifiers=\"Menu\"") >= 2);
        Assert.Contains("Key=\"Enter\"", xaml);
        Assert.Contains("Key=\"S\"", xaml);
        Assert.Contains("Modifiers=\"Control\"", xaml);
        Assert.Contains("DoubleTapped=\"Photos_DoubleTapped\"", xaml);
        Assert.DoesNotContain("IsItemClickEnabled=\"True\"", xaml);
        Assert.Contains("grid.ItemFromContainer(container)", source);
        Assert.Contains("{ IsFolder: true } entry", source);
        Assert.Contains("args.Handled = true;", source);
        Assert.Contains("CanSaveSelectedImage()", source);
        Assert.Contains("{ IsImage: true, Item.SizeBytes: >= 0 }", source);
    }

    [Fact]
    public void ThumbnailLifecycleIsBoundToContainerLocationAndPageLifetime()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml");
        var source = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml.cs");

        Assert.Contains("Loaded=\"Thumbnail_Loaded\"", xaml);
        Assert.Contains("Unloaded=\"Thumbnail_Unloaded\"", xaml);
        Assert.Contains("ContainerContentChanging=\"PhotoGrid_ContainerContentChanging\"", xaml);
        Assert.Contains("args.InRecycleQueue", source);
        Assert.Contains("PhotoThumbnailSize.Medium", source);
        Assert.Contains("PhotoThumbnailPriority.Visible", source);
        Assert.Contains("CreateLinkedTokenSource(_locationCancellation.Token)", source);
        Assert.Contains("private async Task RunLocationChangeAsync", source);
        Assert.Contains("CancelThumbnailRequests();", source);
        Assert.Contains("_thumbnails.Dispose();", source);
        Assert.Contains("PhotosPage : Page, IDisposable", source);
        Assert.DoesNotContain("AutomationProperties.Name=\"{x:Bind Path}\"", xaml);
        Assert.Contains("PhotoBrowserFolderAutomationName", source);
        Assert.Contains("PhotoBrowserImageAutomationName", source);
        Assert.DoesNotContain("entry.Path));", source);
        Assert.Contains("DecodePixelWidth = ThumbnailDecodePixels", source);
        Assert.Contains("DecodePixelHeight = ThumbnailDecodePixels", source);
    }

    [Fact]
    public void SaveCopyHasOneSharedBusyGateAndRequiresMatchingProfile()
    {
        var source = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml.cs");

        Assert.Contains("private bool _isSaving;", source);
        Assert.Contains("!_isSaving", source);
        Assert.Contains("_isSaving = true;", source);
        Assert.Contains("_isSaving = false;", source);
        Assert.Contains("EnsureMatchingProfile(dataSource.ProfileId, profileId);", source);
        Assert.Contains("sourceProfileId != parsedProfileId", source);
    }

    [Fact]
    public void RecycleRestoreIsRestrictedToPhotoItemsInRecyclePaths()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml");
        var page = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml.cs");
        var recycle = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.Recycle.cs");
        var timelineXaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotoTimelineView.xaml");
        var timeline = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs");
        var dialog = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Files/Recycle/FileRecycleDialogContent.cs");
        var shell = ReadRepositoryFile("windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains("x:Name=\"PhotoRestoreFromRecycleButton\"", xaml);
        Assert.Contains("x:Uid=\"FileRecycleRestore\"", xaml);
        Assert.Contains("Click=\"RestorePhotoFromRecycle_Click\"", xaml);
        Assert.Contains("x:Name=\"RestoreButton\"", timelineXaml);
        Assert.Contains("InitializePhotoRecycle(recycleRepository, recycleReviewBlocker);", page);
        Assert.Contains("CanRestorePhotoItem", page);
        Assert.Contains("RestorePhotoItemAsync", page);
        Assert.Contains("recycleRepository: photoRecycleRepository", shell);
        Assert.Contains("recycleReviewBlocker: FileRecycleReviewBlocker.Current", shell);

        Assert.Contains("new FileRecycleViewModel(", recycle);
        Assert.Contains("FileRecycleOperation.Restore", recycle);
        Assert.Contains("FileLocationSource.Recycle", recycle);
        Assert.Contains("PhotoTimelineViewModel.ContainsCanonicalPath", recycle);
        Assert.Contains("CanDelete: true", recycle);
        Assert.Contains("FileRecycleDialogContent.Build(model, localization)", recycle);
        Assert.Contains("await TimelineView.RefreshAsync()", recycle);
        Assert.Contains("await RunLocationChangeAsync(_viewModel.RefreshAsync)", recycle);
        Assert.DoesNotContain("MoveToRecycleAsync", recycle);
        Assert.DoesNotContain("DeleteFilesAsync", recycle);
        Assert.DoesNotContain("DeleteFileAsync", recycle);

        Assert.Contains("CanRestoreSelected", timeline);
        Assert.Contains("RestoreSelectedAsync", timeline);
        Assert.Contains("FileRecycleRestoreAction", timeline);
        Assert.Contains("FileRecycleStatusAutomationName", dialog);
    }

    [Theory]
    [InlineData("PhotoBrowserSpace")]
    [InlineData("PhotoBrowserBreadcrumbs")]
    [InlineData("PhotoBrowserBack")]
    [InlineData("PhotoBrowserUp")]
    [InlineData("PhotoBrowserRefresh")]
    [InlineData("PhotoBrowserSave")]
    [InlineData("PhotoBrowserFilter")]
    [InlineData("PhotoBrowserGrid")]
    [InlineData("PhotoBrowserLoadMore")]
    public void InteractiveControlsHaveLocalizedAutomationNames(string resourceUid)
    {
        var english = ReadRepositoryFile(
            "windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = ReadRepositoryFile(
            "windows/src/LanStash.App/Strings/zh-CN/Resources.resw");
        var resourceName =
            $"{resourceUid}.[using:Microsoft.UI.Xaml.Automation]AutomationProperties.Name";

        Assert.Contains($"name=\"{resourceName}\"", english);
        Assert.Contains($"name=\"{resourceName}\"", chinese);
    }

    private static int CountOccurrences(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;

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
