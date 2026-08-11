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
        Assert.DoesNotContain("CloudDrive", xaml, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("x:Name=\"PhotoViewerHost\"", xaml);
        Assert.Contains("x:Name=\"PhotoPreviewPane\"", xaml);
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
        Assert.Contains("grid.ItemFromContainer(container) is not PhotoBrowserEntry entry", source);
        Assert.Contains("args.Handled = true;", source);
        Assert.Contains("OpenFolderViewerAsync(entry)", source);
        Assert.Contains("CanSaveSelectedMedia()", source);
        Assert.Contains("{ IsMedia: true, Item.SizeBytes: >= 0 }", source);
        Assert.Contains("CurrentPhotoViewerItem() is { } viewerItem", source);
        Assert.Contains("await SaveTimelineItemAsync(viewerItem)", source);
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
        Assert.Contains("PhotoBrowserVideoAutomationName", source);
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
    public void ViewerUsesExistingFilePreviewAndKeepsPhotoMetadataAccessible()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml");
        var page = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml.cs");
        var viewer = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.Viewer.cs");
        var timelineXaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotoTimelineView.xaml");
        var timeline = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs");
        var shell = ReadRepositoryFile("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var window = ReadRepositoryFile("windows/src/LanStash.App/MainWindow.xaml.cs");

        Assert.Contains("x:Uid=\"PhotoBrowserOpen\"", xaml);
        Assert.Contains("x:Uid=\"PhotoTimelineOpen\"", timelineXaml);
        Assert.Contains("KeyboardAccelerator Key=\"Enter\" Invoked=\"OpenAccelerator_Invoked\"", timelineXaml);
        Assert.Contains("DoubleTapped=\"TimelineGrid_DoubleTapped\"", timelineXaml);
        Assert.Contains("Func<PhotoItem, IReadOnlyList<PhotoItem>, Task>? _open", timeline);
        Assert.Contains("await _open(entry.Item, VisibleMediaItems())", timeline);

        Assert.Contains("IFilePreviewRepository? previewRepository", page);
        Assert.Contains("InitializePhotoViewer(previewRepository);", page);
        Assert.Contains("PhotoPreviewPane.Attach(_previewViewModel);", viewer);
        Assert.Contains("await _previewViewModel.OpenAsync(", viewer);
        Assert.Contains("ToFileItem(item)", viewer);
        Assert.Contains("PhotoViewerPreviousButton", xaml);
        Assert.Contains("PhotoViewerNextButton", xaml);
        Assert.Contains("PhotoViewerImmersiveButton", xaml);
        Assert.Contains("Key=\"F11\"", xaml);
        var viewerHost = Slice(
            xaml,
            "x:Name=\"PhotoViewerHost\"",
            "<local:FilePreviewPane");
        Assert.Contains("Background=\"{ThemeResource ApplicationPageBackgroundThemeBrush}\"", viewerHost);
        Assert.Contains("Key=\"Left\"", viewerHost);
        Assert.Contains("PhotoViewerPreviousAccelerator_Invoked", viewerHost);
        Assert.Contains("Key=\"Right\"", viewerHost);
        Assert.Contains("PhotoViewerNextAccelerator_Invoked", viewerHost);
        Assert.Contains("AutomationProperties.LiveSetting=\"Polite\"", viewerHost);
        Assert.Contains("PhotoViewerMetadata", xaml);
        Assert.Contains("PhotoViewerDimensionsLabel", xaml);
        Assert.Contains("PhotoViewerDimensionsValue", xaml);
        Assert.Contains("PhotoViewerTakenLabel", xaml);
        Assert.Contains("PhotoViewerTakenValue", xaml);
        Assert.Contains("PhotoViewerDurationLabel", xaml);
        Assert.Contains("PhotoViewerDurationValue", xaml);
        Assert.Contains("PhotoViewerCameraLabel", xaml);
        Assert.Contains("PhotoViewerCameraValue", xaml);
        Assert.Contains("_previewViewModel.PropertyChanged += PhotoPreviewViewModel_PropertyChanged;", viewer);
        Assert.Contains("PhotoPreviewViewModel_PropertyChanged", viewer);
        Assert.Contains("CurrentPhotoPreviewMetadata(item)", viewer);
        Assert.Contains("FormatPhotoViewerDimensions", viewer);
        Assert.Contains("FormatPhotoViewerCapturedAt", viewer);
        Assert.Contains("FormatPhotoViewerDuration", viewer);
        Assert.Contains("FormatPhotoViewerCamera", viewer);
        Assert.Contains("AutomationProperties.SetName(", viewer);
        Assert.Contains("PhotoViewerMetadataAutomationName", viewer);
        Assert.Contains("_isPhotoViewerImmersive", viewer);
        Assert.Contains("PhotoPreviewPane.KeyboardCloseRequested += PhotoPreviewPane_KeyboardCloseRequested;", viewer);
        Assert.Contains("ExitPhotoViewerImmersive()", viewer);
        Assert.Contains("ClosePhotoViewerAsync(restoreBrowserFocus: true)", viewer);
        Assert.Contains("FocusPhotoBrowserAfterViewerClose", viewer);
        Assert.Contains("TimelineView.Focus(FocusState.Programmatic)", viewer);
        Assert.Contains("PhotoGrid.Focus(FocusState.Programmatic)", viewer);
        Assert.Contains("Grid.SetColumnSpan(PhotoViewerHost, isImmersive ? 2 : 1);", viewer);
        Assert.Contains("PhotoViewerColumn.Width = isOpen && !isImmersive", viewer);
        Assert.Contains("ApplyPhotoBrowserSurfaceVisibility(isImmersive);", viewer);
        Assert.Contains("PhotoBrowserHeader.Visibility = browserVisibility;", viewer);
        Assert.Contains("PhotoViewerEnterImmersive.Content", viewer);
        Assert.Contains("PhotoViewerExitImmersive.Content", viewer);
        Assert.Contains("PhotoViewerPositionAutomationName", viewer);
        Assert.Contains("PhotoViewerHostAutomationName", viewer);
        Assert.Contains("EnterPhotoViewerFullScreen()", viewer);
        Assert.Contains("ExitPhotoViewerFullScreen()", viewer);
        Assert.Contains("internal MainWindow? MainWindow => _window;", ReadRepositoryFile(
            "windows/src/LanStash.App/App.xaml.cs"));
        Assert.Contains("internal void SetWindowVisible(bool isVisible)", viewer);
        Assert.Contains("PhotoPreviewPane.PauseMediaPlayback();", viewer);
        Assert.Contains("_photos?.SetWindowVisible(isVisible);", shell);
        Assert.Contains("AppWindowPresenterKind.FullScreen", window);
        Assert.Contains("OverlappedPresenterState.Maximized", window);
        Assert.Contains("presenter.Maximize();", window);
        Assert.Contains("ExitPhotoViewerFullScreen();", window);
        Assert.DoesNotContain("AppWindowPresenterKind", viewer);
        Assert.DoesNotContain("OverlappedPresenter", viewer);

        Assert.Contains("var photoPreviewRepository = _app.Repository as IFilePreviewRepository;", shell);
        Assert.Contains("previewRepository: photoPreviewRepository", shell);
        Assert.Contains("!ReferenceEquals(_photosRepository, photoRepository)", shell);
    }

    [Theory]
    [InlineData("PhotoViewerEnterImmersive.Content")]
    [InlineData("PhotoViewerEnterImmersive.AutomationProperties.Name")]
    [InlineData("PhotoViewerExitImmersive.Content")]
    [InlineData("PhotoViewerExitImmersive.AutomationProperties.Name")]
    [InlineData("PhotoViewerPositionAutomationName")]
    [InlineData("PhotoViewerHostAutomationName")]
    public void PhotoViewerImmersiveResourcesAreLocalized(string resourceName)
    {
        var english = ReadRepositoryFile(
            "windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = ReadRepositoryFile(
            "windows/src/LanStash.App/Strings/zh-CN/Resources.resw");

        Assert.Contains($"name=\"{resourceName}\"", english);
        Assert.Contains($"name=\"{resourceName}\"", chinese);
    }

    [Fact]
    public void RecycleActionsUseDiscoveredLocationsAndSharedTypedResultFlow()
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
        Assert.Contains("x:Name=\"PhotoMoveToRecycleButton\"", xaml);
        Assert.Contains("x:Name=\"PhotoRecycleLocationsStatus\"", xaml);
        Assert.Contains("x:Name=\"PhotoRecycleLocationsRetryButton\"", xaml);
        Assert.Contains("x:Uid=\"FileRecycleRestore\"", xaml);
        Assert.Contains("x:Uid=\"FileRecycleMoveToRecycle\"", xaml);
        Assert.Contains("Click=\"MovePhotoToRecycle_Click\"", xaml);
        Assert.Contains("Click=\"RestorePhotoFromRecycle_Click\"", xaml);
        Assert.Contains("x:Name=\"RestoreButton\"", timelineXaml);
        Assert.Contains("x:Name=\"MoveToRecycleButton\"", timelineXaml);
        Assert.Contains("InitializePhotoRecycle(locationsRepository, recycleRepository, recycleReviewBlocker);", page);
        Assert.Contains("CanMovePhotoToRecycle", page);
        Assert.Contains("MovePhotoToRecycleAsync", page);
        Assert.Contains("CanRestorePhotoItem", page);
        Assert.Contains("RestorePhotoItemAsync", page);
        Assert.Contains("photoLocationsRepository = _app.Repository as IFileLocationsRepository", shell);
        Assert.Contains("locationsRepository: photoLocationsRepository", shell);
        Assert.Contains("recycleRepository: photoRecycleRepository", shell);
        Assert.Contains("recycleReviewBlocker: FileRecycleReviewBlocker.Current", shell);

        Assert.Contains("new FileRecycleViewModel(", recycle);
        Assert.Contains("FileRecycleOperation.MoveToRecycle", recycle);
        Assert.Contains("FileRecycleOperation.Restore", recycle);
        Assert.Contains("FileRecycleViewModel.FindRecycleLocation(", recycle);
        Assert.Contains("repository.LoadSnapshotAsync(request.Token)", recycle);
        Assert.Contains("_photoRecycleLocations = [];", recycle);
        Assert.Contains("_photoLocationsRepository?.Availability.RecycleBins == true", recycle);
        Assert.Contains("snapshot.RecycleBins.Items", recycle);
        Assert.Contains("FileLocationSource.Shares", recycle);
        Assert.Contains("FileLocationSource.Recycle", recycle);
        Assert.Contains("PhotoTimelineViewModel.ContainsCanonicalPath", recycle);
        Assert.Contains("CanDelete: true", recycle);
        Assert.Contains("FileRecycleDialogContent.Build(model, localization)", recycle);
        Assert.Contains("await ClosePhotoViewerAsync(restoreBrowserFocus: false);", recycle);
        Assert.Contains("var operationTask = model.SubmitAsync();", recycle);
        Assert.Contains("await operationTask;", recycle);
        Assert.Contains("await TimelineView.RefreshAsync()", recycle);
        Assert.Contains("await RunLocationChangeAsync(_viewModel.RefreshAsync)", recycle);
        Assert.DoesNotContain("DeleteFilesAsync", recycle);
        Assert.DoesNotContain("DeleteFileAsync", recycle);
        Assert.Contains("!HasRecyclePathSegment(source.Path)", recycle);
        Assert.DoesNotContain("Join(_photoRecycle", recycle);

        Assert.Contains("CanRestoreSelected", timeline);
        Assert.Contains("RestoreSelectedAsync", timeline);
        Assert.Contains("FileRecycleRestoreAction", timeline);
        Assert.Contains("FileRecycleStatusAutomationName", dialog);
    }

    [Fact]
    public void BatchRecycleUsesBoundedTypedSafetyChainInFoldersAndTimeline()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml");
        var batch = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.BatchRecycle.cs");
        var timelineXaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotoTimelineView.xaml");
        var timeline = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs");

        Assert.Contains("x:Name=\"PhotoMoveMultipleToRecycleButton\"", xaml);
        Assert.Contains("x:Name=\"PhotoMoveSelectedToRecycleButton\"", xaml);
        Assert.Contains("x:Name=\"PhotoCancelRecycleSelectionButton\"", xaml);
        Assert.Contains("x:Name=\"PhotoRecycleBatchStatus\"", xaml);
        Assert.Contains("PhotoGrid.SelectionMode = ListViewSelectionMode.Multiple", batch);
        Assert.Contains("FileRecycleBatchViewModel.MaximumItemCount", batch);
        Assert.Contains("FileRecycleBatchSourceScope.CurrentFolder", batch);
        Assert.Contains("FileRecycleBatchSourceScope.DescendantsOfRoot", batch);
        Assert.Contains("new FileRecycleBatchViewModel(", batch);
        Assert.Contains("PhotoBatchRecycleSourceIsCurrent(", batch);
        Assert.Contains("_photoBatchRecycleDialog is not null", batch);
        Assert.Contains("_photoBatchRecycleModel is not null", batch);
        Assert.Contains("!_isPhotoPageActive", batch);
        Assert.Contains("FileRecycleViewModel.FindRecycleLocation(", batch);
        Assert.Contains("var submit = model.SubmitAsync();", batch);
        Assert.Contains("summary.ConfirmedCount > 0", batch);
        Assert.DoesNotContain("DeleteFilesAsync", batch);
        Assert.DoesNotContain("DeleteFileAsync", batch);

        Assert.Contains("x:Name=\"MoveMultipleToRecycleButton\"", timelineXaml);
        Assert.Contains("x:Name=\"MoveSelectedToRecycleButton\"", timelineXaml);
        Assert.Contains("x:Name=\"CancelRecycleSelectionButton\"", timelineXaml);
        Assert.Contains("x:Name=\"RecycleBatchStatus\"", timelineXaml);
        Assert.Contains("TimelineGrid.SelectionMode = ListViewSelectionMode.Multiple", timeline);
        Assert.Contains("HasSelectedRecycleItems", timeline);
        Assert.Contains("ExitRecycleSelection", timeline);
    }

    [Fact]
    public void BatchMoveUsesOneBoundedSelectionSessionAndRevalidatesFolderAndTimelineSources()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml");
        var page = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml.cs");
        var selection = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.BatchRecycle.cs");
        var move = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.BatchMove.cs");
        var timelineXaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotoTimelineView.xaml");
        var timeline = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs");

        Assert.Contains("x:Name=\"PhotoMoveMultipleButton\"", xaml);
        Assert.Contains("x:Name=\"PhotoMoveSelectedButton\"", xaml);
        Assert.Contains("PhotoBatchSelectionOperation", selection);
        Assert.Contains("PhotoBatchSelectionOperation.Move", selection);
        Assert.Contains("PhotoBatchSelectionOperation.Recycle", selection);
        Assert.Contains("PhotoGrid.SelectionMode = ListViewSelectionMode.Multiple", selection);
        Assert.Contains("FileCopyMoveBatchViewModel.MaximumItemCount", selection);

        Assert.Contains("new FileCopyMoveBatchViewModel(", move);
        Assert.Contains("FileCopyMoveBatchSourceScope.CurrentFolder", move);
        Assert.Contains("FileCopyMoveBatchSourceScope.DescendantsOfRoot", move);
        Assert.Contains("PhotoBatchMoveSourceIsCurrent(", move);
        Assert.Contains("_photoBatchCopyMoveDialog is not null", move);
        Assert.Contains("_photoBatchCopyMoveModel is not null", move);
        Assert.Contains("await ClosePhotoViewerAsync(restoreBrowserFocus: false);", move);
        Assert.Contains("var submit = model.SubmitAsync();", move);
        Assert.Contains("dialog.Closing += (sender, args)", move);
        Assert.Contains("summary.ConfirmedCount > 0", move);
        Assert.DoesNotContain("overwrite", move, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("DeleteFilesAsync", move);

        Assert.Contains("MoveMultiplePhotosAsync", page);
        Assert.Contains("ClosePhotoBatchCopyMoveDialog();", page);
        Assert.Contains("if (IsSelectingPhotoBatch", page);
        Assert.Contains("x:Name=\"MoveMultipleButton\"", timelineXaml);
        Assert.Contains("x:Name=\"MoveSelectedItemsButton\"", timelineXaml);
        Assert.Contains("HasSelectedBatchItems", timeline);
        Assert.Contains("_batchSelectionOperation", timeline);
        Assert.Contains("FileCopyMoveBatchViewModel.MaximumItemCount", timeline);
    }

    [Fact]
    public void SinglePhotoMoveReusesFileCopyMoveSafetyChainAndRevalidatesSelection()
    {
        var xaml = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml");
        var page = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml.cs");
        var move = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.CopyMove.cs");
        var sharedDialog = ReadRepositoryFile(
            "windows/src/LanStash.App/Features/Files/CopyMove/FileCopyMoveDialogContent.cs");
        var filesMove = ReadRepositoryFile("windows/src/LanStash.App/Views/FilesPage.CopyMove.cs");
        var shell = ReadRepositoryFile("windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains("x:Uid=\"FileCopyMoveMove\"", xaml);
        Assert.Contains("x:Name=\"PhotoMoveButton\"", xaml);
        Assert.Contains("Click=\"MovePhoto_Click\"", xaml);
        Assert.Contains("InitializePhotoCopyMove(copyMoveRepository, copyMoveFolderSource, copyMoveReviewBlocker);", page);
        Assert.Contains("copyMoveRepository: photoCopyMoveRepository", shell);
        Assert.Contains("copyMoveFolderSource: photoCopyMoveFolderSource", shell);
        Assert.Contains("new RepositoryFileCopyMoveFolderSource(", shell);

        Assert.Contains("new FileCopyMoveViewModel(", move);
        Assert.Contains("FileCopyMoveOperation.Move", move);
        Assert.Contains("repository.Availability.CanMove", move);
        Assert.Contains("!HasRecyclePathSegment(item.Path)", move);
        Assert.Contains("IsCurrentPhotoMoveRequest(", move);
        Assert.Contains("await ClosePhotoViewerAsync(restoreBrowserFocus: false);", move);
        Assert.Contains("var operation = model.SubmitAsync();", move);
        Assert.Contains("await operation;", move);
        Assert.Contains("model.State != FileCopyMovePresentationState.ConfirmedSuccess", move);
        Assert.Contains("await TimelineView.RefreshAsync()", move);
        Assert.Contains("await RunLocationChangeAsync(_viewModel.RefreshAsync)", move);
        Assert.DoesNotContain("FileCopyMoveOperation.Copy", Slice(
            move,
            "private async Task ShowPhotoMoveAsync",
            "private bool IsCurrentPhotoMoveRequest"));

        Assert.Contains("FileCopyMoveDialogContent.Build(model, localization, RenderAsync)", move);
        Assert.Contains("FileCopyMoveDialogContent.Build(model, localization, RenderAsync)", filesMove);
        Assert.Contains("FileCopyMove_A11y_DestinationTree", sharedDialog);
        Assert.Contains("AutomationLiveSetting.Assertive", sharedDialog);
    }

    [Theory]
    [InlineData("PhotoBrowserSpace")]
    [InlineData("PhotoBrowserBreadcrumbs")]
    [InlineData("PhotoBrowserBack")]
    [InlineData("PhotoBrowserUp")]
    [InlineData("PhotoBrowserRefresh")]
    [InlineData("PhotoBrowserOpen")]
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
