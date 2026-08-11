namespace LanStash.Tests;

public sealed class FilesPageSourceContractTests
{
    [Fact]
    public void FilesPageExposesFiveStatesAndScopedSingleFileTransferCommands()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.xaml");

        Assert.Contains("x:Name=\"LoadingState\"", xaml);
        Assert.Contains("x:Name=\"EmptyState\"", xaml);
        Assert.Contains("x:Name=\"FilteredEmptyState\"", xaml);
        Assert.Contains("x:Name=\"ErrorState\"", xaml);
        Assert.Contains("x:Name=\"ContentState\"", xaml);
        Assert.Contains("x:Name=\"PathBreadcrumbs\"", xaml);
        Assert.Contains("x:Name=\"FileList\"", xaml);
        Assert.Contains("x:Name=\"FileGrid\"", xaml);
        Assert.Contains("x:Name=\"LoadMoreButton\"", xaml);

        Assert.DoesNotContain("Create_Click", xaml);
        Assert.DoesNotContain("Rename_Click", xaml);
        Assert.DoesNotContain("Delete_Click", xaml);
        Assert.Contains("Upload_Click", xaml);
        Assert.Contains("x:Name=\"UploadNeedsReview\"", xaml);
        Assert.Contains("Download_Click", xaml);
        Assert.DoesNotContain("CloudDrive", xaml);
    }

    [Fact]
    public void DesktopDropAcceptsExactlyOneLocalFileAndReusesUploadActivityLane()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.xaml");
        var drop = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/FilesPage.DragUpload.cs");

        Assert.Contains("AllowDrop=\"True\"", xaml);
        Assert.Contains("DragOver=\"FileUpload_DragOver\"", xaml);
        Assert.Contains("Drop=\"FileUpload_Drop\"", xaml);
        Assert.Contains("x:Name=\"FileUploadDropOverlay\"", xaml);
        Assert.Contains("ThemeResource", xaml);
        Assert.Contains("StandardDataFormats.StorageItems", drop);
        Assert.Contains("items.Count != 1", drop);
        Assert.Contains("items[0] is not StorageFile", drop);
        Assert.Contains("string.IsNullOrWhiteSpace(file.Path)", drop);
        Assert.Contains("DataPackageOperation.Copy", drop);
        Assert.Contains("!IsReadOnlyLocation()", drop);
        Assert.Contains("!_viewModel.IsLoading", drop);
        Assert.Contains("!_isChoosingUpload", drop);
        Assert.Contains("_fileUploadDragGeneration", drop);
        Assert.Contains("_fileUploadDropGeneration", drop);
        Assert.Contains("string.Equals(targetPath, _viewModel.CurrentPath", drop);
        Assert.Contains("_transfers.StartUploadAsync(", drop);
        Assert.DoesNotContain("UploadFileAsync", drop);
        Assert.DoesNotContain("overwrite", drop, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void TouchTargetsAndKeyboardRoutesRemainAvailable()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.xaml");
        var codeBehind = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.xaml.cs");

        Assert.DoesNotContain("MinHeight=\"40\"", xaml);
        Assert.True(CountOccurrences(xaml, "MinHeight=\"44\"") >= 16);
        Assert.Contains("MinHeight=\"48\"", xaml);
        Assert.Contains("Key=\"Left\"", xaml);
        Assert.Contains("Modifiers=\"Menu\"", xaml);
        Assert.Contains("BackAccelerator_Invoked", xaml);
        Assert.Equal(2, CountOccurrences(xaml, "Key=\"Enter\""));
        Assert.Contains("Key=\"S\"", xaml);
        Assert.Contains("Modifiers=\"Control\"", xaml);
        Assert.Contains("DownloadAccelerator_Invoked", xaml);
        Assert.Contains("Key=\"U\"", xaml);
        Assert.Contains("UploadAccelerator_Invoked", xaml);
        Assert.Contains("OpenSelectedAccelerator_Invoked", xaml);
        Assert.Equal(2, CountOccurrences(xaml, "DoubleTapped=\"Files_DoubleTapped\""));
        Assert.DoesNotContain("IsItemClickEnabled=\"True\"", xaml);
        Assert.Contains("args.Handled = true;", codeBehind);
        Assert.Contains("_viewModel.OpenAsync(selected)", codeBehind);
        Assert.Contains("OpenPreviewAsync(selected)", codeBehind);
    }

    [Fact]
    public void PageLifetimeIsReleasedExplicitlyInsteadOfOnOrdinaryUnload()
    {
        var codeBehind = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var shell = ReadRepositoryFile("windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains("FilesPage : Page, IDisposable", codeBehind);
        Assert.Contains("public void Dispose()", codeBehind);
        Assert.Contains("_viewModel.Dispose();", codeBehind);
        Assert.DoesNotContain("Unloaded +=", codeBehind);
        Assert.DoesNotContain("FilesPage_Unloaded", codeBehind);
        Assert.Contains("_files ??= new FilesPage(", shell);
        var close = SliceMethod(
            shell,
            "private async Task CloseFilesPageAsync()",
            "private void Settings_Changed");
        Assert.Contains("await files.CloseAsync();", close);
        Assert.Contains("finally", close);
        Assert.True(
            close.IndexOf("files.Dispose();", StringComparison.Ordinal) >
            close.IndexOf("finally", StringComparison.Ordinal));
    }

    [Fact]
    public void DoubleClickOpensOnlyTheContainerThatWasActuallyHit()
    {
        var codeBehind = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var handler = SliceMethod(
            codeBehind,
            "private async void Files_DoubleTapped",
            "private async void Back_Click");

        Assert.Contains("e.OriginalSource", handler);
        Assert.Contains("FindItemContainer(itemsControl, source)", handler);
        Assert.Contains("itemsControl.ItemFromContainer(container)", handler);
        Assert.Contains("_viewModel.OpenAsync(entry)", handler);
        Assert.Contains("OpenPreviewAsync(entry)", handler);
        Assert.DoesNotContain("OpenAsync(_viewModel.SelectedItem)", handler);

        var containerLookup = SliceMethod(
            codeBehind,
            "private static DependencyObject? FindItemContainer",
            "private async void Back_Click");
        Assert.Contains("VisualTreeHelper.GetParent(current)", containerLookup);
        Assert.Contains("current is ListViewItem or GridViewItem", containerLookup);
        Assert.Contains("current != owner", containerLookup);
    }

    [Theory]
    [InlineData("FileBrowserBreadcrumbs")]
    [InlineData("FileLocationsOpen")]
    [InlineData("FileBrowserFilter")]
    [InlineData("FileBrowserBack")]
    [InlineData("FileBrowserUp")]
    [InlineData("FileBrowserRefresh")]
    [InlineData("FileBrowserDownload")]
    [InlineData("FileBrowserUpload")]
    [InlineData("FileBrowserSort")]
    [InlineData("FileBrowserSortName")]
    [InlineData("FileBrowserSortModified")]
    [InlineData("FileBrowserSortSize")]
    [InlineData("FileBrowserSortAscending")]
    [InlineData("FileBrowserSortDescending")]
    [InlineData("FileBrowserTypeFilter")]
    [InlineData("FileBrowserTypeAll")]
    [InlineData("FileBrowserTypeFiles")]
    [InlineData("FileBrowserTypeFolders")]
    [InlineData("FileBrowserListLayout")]
    [InlineData("FileBrowserGridLayout")]
    [InlineData("FileBrowserList")]
    [InlineData("FileBrowserGrid")]
    [InlineData("FileBrowserLoadMore")]
    public void InteractiveControlsHaveQualifiedAutomationResourceNames(string resourceUid)
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

    [Fact]
    public void VisibleProseUsesLocalizationResourceIdentifiers()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.xaml");
        var state = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Files/FileBrowserState.cs");

        Assert.DoesNotContain("Text=\"Loading", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Content=\"Load", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("x:Uid=\"FileBrowserLoading\"", xaml);
        Assert.Contains("x:Uid=\"FileBrowserErrorMessage\"", xaml);
        Assert.Contains("x:Uid=\"FileBrowserFilteredEmptyMessage\"", xaml);
        Assert.Contains("LocalizationService.Current.Format(", state);
        Assert.Contains("\"FileBrowserFileDetail\"", state);
        Assert.Contains("LocalizationService.Current.Get(\"UnknownValue\")", state);
        Assert.DoesNotContain("{0:N0} B", state);
    }

    [Fact]
    public void SortAndTypeUseNativeCheckedMenusAndSharedRootAvailability()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.xaml");
        var codeBehind = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.xaml.cs");

        Assert.Contains("x:Name=\"SortButton\"", xaml);
        Assert.Contains("x:Name=\"TypeFilterButton\"", xaml);
        Assert.Equal(2, CountOccurrences(xaml, "<MenuFlyout>"));
        Assert.Contains("GroupName=\"FileSortField\"", xaml);
        Assert.Contains("GroupName=\"FileSortDirection\"", xaml);
        Assert.Contains("GroupName=\"FileTypeFilter\"", xaml);
        Assert.Contains("SortName_Click", xaml);
        Assert.Contains("SortModified_Click", xaml);
        Assert.Contains("SortSize_Click", xaml);
        Assert.Contains("SortAscending_Click", xaml);
        Assert.Contains("SortDescending_Click", xaml);
        Assert.Contains("TypeAll_Click", xaml);
        Assert.Contains("TypeFiles_Click", xaml);
        Assert.Contains("TypeFolders_Click", xaml);

        Assert.Contains("SortNameItem.IsChecked", codeBehind);
        Assert.Contains("SortModifiedItem.IsChecked", codeBehind);
        Assert.Contains("SortSizeItem.IsChecked", codeBehind);
        Assert.Contains("SortAscendingItem.IsChecked", codeBehind);
        Assert.Contains("SortDescendingItem.IsChecked", codeBehind);
        Assert.Contains("TypeAllItem.IsChecked", codeBehind);
        Assert.Contains("TypeFilesItem.IsChecked", codeBehind);
        Assert.Contains("TypeFoldersItem.IsChecked", codeBehind);
        Assert.Contains("_viewModel.CanChooseNonNameSort", codeBehind);
        Assert.Contains("_viewModel.CanChooseTypeFilter", codeBehind);
    }

    [Fact]
    public void ClearFiltersAndSelectionRestoreUseViewModelAndNativeListControls()
    {
        var codeBehind = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.xaml.cs");

        Assert.Contains("await RunAsync(_viewModel.ClearFiltersAsync);", codeBehind);
        Assert.Contains("FileList.ScrollIntoView(selected);", codeBehind);
        Assert.Contains("FileGrid.ScrollIntoView(selected);", codeBehind);
        Assert.Contains("nameof(FileBrowserViewModel.SelectedItem)", codeBehind);
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

        throw new DirectoryNotFoundException(
            $"Unable to locate repository file: {relativePath}");
    }

    private static int CountOccurrences(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;

    private static string SliceMethod(string source, string start, string next)
    {
        var startIndex = source.IndexOf(start, StringComparison.Ordinal);
        var endIndex = source.IndexOf(next, startIndex, StringComparison.Ordinal);
        Assert.True(startIndex >= 0 && endIndex > startIndex);
        return source[startIndex..endIndex];
    }
}
