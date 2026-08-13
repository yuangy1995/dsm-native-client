namespace LanStash.Tests.Photos;

public sealed class PhotoTimelinePresentationTests
{
    [Fact]
    public void TimelineUsesNativeAccessibleVirtualizedControlsAndBoundedRepository()
    {
        var root = RepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml"));
        var model = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Features/Photos/Timeline/PhotoTimelineViewModel.cs"));
        var source = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Features/Photos/Timeline/PhotoTimelineDataSource.cs"));

        Assert.Contains("<TextBox", xaml);
        Assert.Contains("<GridView", xaml);
        Assert.Contains("AutomationProperties.HeadingLevel=\"Level2\"", xaml);
        Assert.True(xaml.Split("AutomationProperties.HeadingLevel=\"Level1\"", StringSplitOptions.None).Length >= 5);
        Assert.Contains("MinHeight=\"44\"", xaml);
        Assert.Contains("PhotoTimelineFilterAll\" Tag=\"All\" MinHeight=\"44\"", xaml);
        Assert.Contains("PhotoTimelineFilterImages\" Tag=\"Images\" MinHeight=\"44\"", xaml);
        Assert.Contains("PhotoTimelineFilterVideos\" Tag=\"Videos\" MinHeight=\"44\"", xaml);
        Assert.Contains("x:Uid=\"PhotoTimelineJump\"", xaml);
        Assert.Contains("x:Name=\"JumpMenu\" Opening=\"JumpMenu_Opening\"", xaml);
        Assert.Contains("x:Uid=\"PhotoTimelineOpen\"", xaml);
        Assert.Contains("OpenAccelerator_Invoked", xaml);
        Assert.Contains("PhotoTimelineTruncated", xaml);
        Assert.Contains("PhotoTimelinePartial", xaml);
        Assert.Contains("PhotoTimelineLimits.Default", source);
        Assert.Contains("NormalizationForm.FormD", model);
        Assert.Contains("TimeSpan.FromMilliseconds(250)", model);
        Assert.Contains("generation != _queryGeneration", model);
        Assert.DoesNotContain("UserDefaults", model);
    }

    [Fact]
    public void TimelineJumpUsesVisibleGroupsNativeMenusAndKeyboardFocus()
    {
        var root = RepositoryRoot();
        var source = File.ReadAllText(Path.Combine(
            root,
            "windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs"));

        Assert.Contains("_viewModel.Groups", source);
        Assert.Contains("GroupBy(group => group.Month!.Value.Year)", source);
        Assert.Contains("OrderByDescending(group => group.Key)", source);
        Assert.Contains("new MenuFlyoutSubItem", source);
        Assert.Contains("new MenuFlyoutItem", source);
        Assert.True(source.Split("MinHeight = 44", StringSplitOptions.None).Length - 1 >= 3);
        Assert.Contains("group.Month is null", source);
        Assert.Contains("TimelineGrid.ScrollIntoView(entry, ScrollIntoViewAlignment.Leading)", source);
        Assert.Contains("DispatcherQueue.TryEnqueue", source);
        Assert.Contains("FocusJumpTarget(entry)", source);
        Assert.Contains("TimelineGrid.Focus(FocusState.Keyboard)", source);
        Assert.Contains("_batchSelectionOperation == PhotoBatchSelectionOperation.None", source);
        Assert.DoesNotContain("LoadAsync(space", source);
    }

    [Fact]
    public void ThumbnailCompletionRequiresFullRevisionIdentity()
    {
        var source = File.ReadAllText(Path.Combine(RepositoryRoot(), "windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs"));
        var identity = source[source.IndexOf("private static bool HasSameRevision", StringComparison.Ordinal)..];
        Assert.Contains("ProfileId", identity);
        Assert.Contains("Path", identity);
        Assert.Contains("ModifiedAt", identity);
        Assert.Contains("SizeBytes", identity);
        Assert.Contains("Kind", identity);
        Assert.Contains("!HasSameRevision(current.Item, entry.Item)", source);
    }

    [Fact]
    public void ModeRoutingResetAndBaselinePresentationHaveSourceGuards()
    {
        var root = RepositoryRoot();
        var page = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotosPage.xaml.cs"));
        var timeline = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs"));

        Assert.Contains("if (TimelineMode.IsChecked == true)", page);
        Assert.Contains("TimelineView.SaveSelectedAsync()", page);
        Assert.Contains("OpenTimelineViewerAsync", page);
        Assert.Contains("_viewModel.SelectedItem = null", page);
        Assert.Contains("TimelineView.ClearSelection()", page);
        Assert.Contains("PhotoTimelineViewModel.ContainsCanonicalPath(space.RootPath, item.Path)", page);
        Assert.Contains("_viewModel.CanSave(entry.Item)", timeline);
        Assert.Contains("CanOpenSelected", timeline);
        Assert.Contains("VisibleMediaItems()", timeline);
        Assert.Contains("SaveButton.IsEnabled = CanSaveSelected", timeline);
        Assert.Contains("OpenButton.IsEnabled = CanOpenSelected", timeline);
        Assert.Contains("SyncControlsFromModel()", timeline);
        Assert.Contains("SearchBox.Text = _viewModel.Query", timeline);
        Assert.Contains("FilterPicker.SelectedIndex = (int)_viewModel.Filter", timeline);
        Assert.Contains("showsBaseline && _viewModel.CommittedIsEmpty", timeline);
        Assert.Contains("RefreshProgress.IsActive = showsBaseline", timeline);
        Assert.Contains("RefreshCancelButton.Visibility = showsBaseline", timeline);
        Assert.Contains("x:Name=\"RefreshCancelButton\" MinHeight=\"44\"", File.ReadAllText(
            Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml")));
    }

    [Fact]
    public void PhotosPageOnlyAddsFoldersTimelineSwitchAndIndependentControl()
    {
        var xaml = File.ReadAllText(Path.Combine(RepositoryRoot(), "windows/src/LanStash.App/Views/PhotosPage.xaml"));
        Assert.Contains("PhotoModeFolders", xaml);
        Assert.Contains("PhotoModeTimeline", xaml);
        Assert.Contains("<local:PhotoTimelineView", xaml);
    }

    [Fact]
    public void TimelineRecycleCommandIsKeyboardAccessibleAndRevalidatesThroughPageCallbacks()
    {
        var root = RepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml"));
        var source = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs"));

        Assert.Contains("x:Name=\"MoveToRecycleButton\"", xaml);
        Assert.Contains("HorizontalScrollBarVisibility=\"Auto\"", xaml);
        Assert.Contains("HorizontalScrollMode=\"Enabled\"", xaml);
        Assert.Contains("MinHeight=\"44\" Click=\"MoveToRecycle_Click\"", xaml);
        Assert.Contains("Func<PhotoItem, bool>? canMoveToRecycle", source);
        Assert.Contains("Func<PhotoItem, Task>? moveToRecycle", source);
        Assert.Contains("_canMoveToRecycle?.Invoke(entry.Item) == true", source);
        Assert.Contains("await _moveToRecycle(entry.Item)", source);
        Assert.Contains("AutomationProperties.SetName(", source);
        Assert.Contains("MoveToRecycleButton.Visibility = CanMoveSelectedToRecycle", source);
        Assert.Contains("internal void RefreshActionState() => UpdateState();", source);
    }

    [Fact]
    public void TimelineBatchRecycleUsesNativeBoundedMultipleSelectionAndAccessibleActions()
    {
        var root = RepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml"));
        var source = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs"));

        Assert.Contains("x:Name=\"MoveMultipleToRecycleButton\"", xaml);
        Assert.Contains("x:Name=\"MoveSelectedToRecycleButton\"", xaml);
        Assert.Contains("x:Name=\"CancelRecycleSelectionButton\"", xaml);
        Assert.Contains("TimelineGrid.SelectionMode = ListViewSelectionMode.Multiple", source);
        Assert.Contains("FileRecycleBatchViewModel.MaximumItemCount", source);
        Assert.Contains("FileRecycleBatchSelectionLimit", source);
        Assert.Contains("PhotoRecycleBatchSelectionInvalid", source);
        Assert.Contains("AutomationProperties.SetName(", source);
        Assert.Contains("TimelineGrid.SelectionMode = ListViewSelectionMode.Single", source);
        Assert.Contains("ExitRecycleSelection();", source);
    }

    [Fact]
    public void TimelineBatchMoveSharesTheNativeSelectionSessionAndAccessibleToolbar()
    {
        var root = RepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml"));
        var source = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs"));

        Assert.Contains("x:Uid=\"FileCopyMoveMoveMultiple\"", xaml);
        Assert.Contains("x:Uid=\"FileCopyMoveMoveSelected\"", xaml);
        Assert.Contains("Click=\"MoveMultiple_Click\"", xaml);
        Assert.Contains("Click=\"MoveSelectedItems_Click\"", xaml);
        Assert.Contains("Func<IReadOnlyList<PhotoItem>, Task>? _moveMultiple", source);
        Assert.Contains("EnterBatchSelection(PhotoBatchSelectionOperation.Move)", source);
        Assert.Contains("EnterBatchSelection(PhotoBatchSelectionOperation.Recycle)", source);
        Assert.Contains("EnterBatchSelection(PhotoBatchSelectionOperation.Restore)", source);
        Assert.Contains("TimelineGrid.SelectionMode = ListViewSelectionMode.Multiple", source);
        Assert.Contains("TimelineGrid.SelectionMode = ListViewSelectionMode.Single", source);
        Assert.Contains("FileCopyMoveBatchSelectionLimit", source);
        Assert.Contains("PhotoMoveBatchSelectionInvalid", source);
        Assert.Contains("PhotoRestoreBatchSelectionInvalid", source);
    }

    [Fact]
    public void TimelineBatchCopyUsesTheSharedBoundedSelectionSession()
    {
        var root = RepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml"));
        var source = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs"));

        Assert.Contains("x:Uid=\"FileCopyMoveCopyMultiple\"", xaml);
        Assert.Contains("x:Uid=\"FileCopyMoveCopySelected\"", xaml);
        Assert.Contains("Click=\"CopyMultiple_Click\"", xaml);
        Assert.Contains("Click=\"CopySelectedItems_Click\"", xaml);
        Assert.Contains("Func<PhotoItem, bool>? _canCopy", source);
        Assert.Contains("Func<IReadOnlyList<PhotoItem>, Task>? _copyMultiple", source);
        Assert.Contains("EnterBatchSelection(PhotoBatchSelectionOperation.Copy)", source);
        Assert.Contains("PhotoCopyBatchSelectionInvalid", source);
    }

    [Fact]
    public void TimelineBatchSaveUsesTheSharedBoundedSelectionSession()
    {
        var root = RepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml"));
        var source = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs"));

        Assert.Contains("x:Uid=\"PhotoBrowserSaveMultiple\"", xaml);
        Assert.Contains("x:Uid=\"PhotoBrowserSaveSelected\"", xaml);
        Assert.Contains("Func<PhotoItem, bool>? _canSaveMultiple", source);
        Assert.Contains("Func<IReadOnlyList<PhotoItem>, Task>? _saveMultiple", source);
        Assert.Contains("EnterBatchSelection(PhotoBatchSelectionOperation.Save)", source);
        Assert.Contains("PhotoSaveBatchSelectionInvalid", source);
    }

    [Fact]
    public void TimelineMoveCommandUsesSharedPageCallbackAndNativeScrollableToolbar()
    {
        var root = RepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml"));
        var source = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs"));

        Assert.Contains("x:Uid=\"FileCopyMoveMove\" x:Name=\"MoveButton\"", xaml);
        Assert.Contains("MinHeight=\"44\" Click=\"Move_Click\"", xaml);
        Assert.Contains("HorizontalScrollBarVisibility=\"Auto\"", xaml);
        Assert.Contains("Func<PhotoItem, bool>? canMove", source);
        Assert.Contains("Func<PhotoItem, Task>? move", source);
        Assert.Contains("_canMove?.Invoke(entry.Item) == true", source);
        Assert.Contains("await _move(entry.Item)", source);
        Assert.Contains("MoveButton.Visibility = CanMoveSelected", source);
    }

    [Fact]
    public void TimelineSingleShareUsesThePageCallbackOutsideBatchSelection()
    {
        var root = RepositoryRoot();
        var xaml = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml"));
        var source = File.ReadAllText(Path.Combine(root, "windows/src/LanStash.App/Views/PhotoTimelineView.xaml.cs"));

        Assert.Contains("x:Uid=\"PhotoShareLinkButton\" x:Name=\"ShareLinkButton\"", xaml);
        Assert.Contains("Click=\"ShareLink_Click\"", xaml);
        Assert.Contains("_batchSelectionOperation == PhotoBatchSelectionOperation.None", source);
        Assert.Contains("_canShare?.Invoke(entry.Item) == true", source);
        Assert.Contains("await _share(entry.Item)", source);
        Assert.Contains("if (!CanShareSelected ||", source);
        Assert.Contains("ShareLinkButton.IsEnabled = CanShareSelected", source);
    }

    private static string RepositoryRoot([System.Runtime.CompilerServices.CallerFilePath] string file = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, "../../../../"));
}
