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
        Assert.Contains("PhotoTimelineTruncated", xaml);
        Assert.Contains("PhotoTimelinePartial", xaml);
        Assert.Contains("PhotoTimelineLimits.Default", source);
        Assert.Contains("NormalizationForm.FormD", model);
        Assert.Contains("TimeSpan.FromMilliseconds(250)", model);
        Assert.Contains("generation != _queryGeneration", model);
        Assert.DoesNotContain("UserDefaults", model);
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
        Assert.Contains("_viewModel.SelectedItem = null", page);
        Assert.Contains("TimelineView.ClearSelection()", page);
        Assert.Contains("PhotoTimelineViewModel.ContainsCanonicalPath(space.RootPath, item.Path)", page);
        Assert.Contains("_viewModel.CanSave(entry.Item)", timeline);
        Assert.Contains("SaveButton.IsEnabled = CanSaveSelected", timeline);
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

    private static string RepositoryRoot([System.Runtime.CompilerServices.CallerFilePath] string file = "") =>
        Path.GetFullPath(Path.Combine(Path.GetDirectoryName(file)!, "../../../../"));
}
