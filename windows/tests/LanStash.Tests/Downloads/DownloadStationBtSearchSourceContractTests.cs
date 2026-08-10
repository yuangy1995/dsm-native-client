using System.Xml.Linq;

namespace LanStash.Tests;

public sealed class DownloadStationBtSearchSourceContractTests
{
    [Fact]
    public void EntryIsCapabilityGatedAndDialogUsesNativeAccessibleStateUi()
    {
        var page = Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml");
        var dialog = Read(
            "windows/src/LanStash.App/Views/DownloadStationPage.BtSearchDialogContent.xaml");
        var source = Read("windows/src/LanStash.App/Views/DownloadStationPage.BtSearch.cs");
        var contentSource = Read(
            "windows/src/LanStash.App/Views/DownloadStationPage.BtSearchDialogContent.xaml.cs");

        Assert.Contains("x:Name=\"BtSearchButton\"", page);
        Assert.Contains("Visibility=\"Collapsed\"", page);
        Assert.Contains("_viewModel.HasBtSearchCapability", source);
        Assert.Contains("new ContentDialog", source);
        Assert.Contains("DownloadStationBtSearchPrivacy", dialog);
        Assert.Contains("x:Name=\"BtSearchLoadingState\"", dialog);
        Assert.Contains("x:Name=\"BtSearchNoProvidersState\"", dialog);
        Assert.Contains("x:Name=\"BtSearchEmptyState\"", dialog);
        Assert.Contains("x:Name=\"BtSearchFilteredEmptyState\"", dialog);
        Assert.Contains("x:Name=\"BtSearchErrorState\"", dialog);
        Assert.Contains("x:Name=\"BtSearchContentState\"", dialog);
        Assert.True(Count(dialog, "MinHeight=\"48\"") >= 8);
        Assert.Equal(7, Count(dialog, "IsEnabled=\"{Binding CanEditBtSearchCriteria}\""));
        Assert.Equal(2, Count(dialog, "MaxLength=\"200\""));
        Assert.Contains("SelectionMode=\"Single\"", dialog);
        Assert.Contains("AutomationProperties.LiveSetting=\"Assertive\"", dialog);
        Assert.Contains("AutomationProperties.Name=\"{x:Bind AutomationName}\"", dialog);
        Assert.Contains("ThemeResource TextFillColorSecondaryBrush", dialog);
        Assert.Contains("<ScrollViewer", dialog);
        Assert.Contains("VerticalScrollBarVisibility=\"Auto\"", dialog);
        Assert.Contains("x:Name=\"NarrowDialogLayout\"", dialog);
        Assert.Contains("x:Name=\"WideDialogLayout\"", dialog);
        Assert.DoesNotContain("MinWidth=\"520\"", dialog);
        Assert.DoesNotContain("MinHeight=\"540\"", dialog);
        Assert.Contains("!_viewModel.HasNoBtSearchProviders", contentSource);
        Assert.Contains("x:Name=\"HeaderActions\"", page);
        Assert.Contains("<ItemsWrapGrid Orientation=\"Horizontal\"", page);
        Assert.Contains("x:Name=\"NarrowHeaderLayout\"", page);
        Assert.Contains("x:Name=\"WideHeaderLayout\"", page);
        Assert.DoesNotContain("Background=\"#", dialog, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Foreground=\"#", dialog, StringComparison.OrdinalIgnoreCase);

        _ = XDocument.Parse(page);
        _ = XDocument.Parse(dialog);
    }

    [Fact]
    public void FiltersMapStableDomainValuesAndResultCreateReusesSafeChainOnce()
    {
        var state = Read(
            "windows/src/LanStash.App/Features/Downloads/DownloadStationBtSearchState.cs");
        var model = Read(
            "windows/src/LanStash.App/Features/Downloads/DownloadStationViewModel.BtSearch.cs");
        var dialog = Read(
            "windows/src/LanStash.App/Views/DownloadStationPage.BtSearchDialogContent.xaml");

        Assert.Contains("DownloadBtSearchModuleScope.Enabled", model);
        Assert.Contains("DownloadBtSearchModuleScope.All", model);
        Assert.Contains("DownloadBtSearchModuleScope.Selected", model);
        Assert.Contains("DownloadBtSearchSort.Title", model);
        Assert.Contains("DownloadBtSearchSort.Size", model);
        Assert.Contains("DownloadBtSearchSort.Date", model);
        Assert.Contains("DownloadBtSearchSort.Peers", model);
        Assert.Contains("DownloadBtSearchSort.Provider", model);
        Assert.Contains("DownloadBtSearchSort.Seeds", model);
        Assert.Contains("DownloadBtSearchSort.Leeches", model);
        Assert.Contains("DownloadBtSearchDirection.Ascending", model);
        Assert.Contains("DownloadBtSearchDirection.Descending", model);
        Assert.Contains("CategoryPicker", dialog);
        Assert.Contains("ModuleList", dialog);
        Assert.Contains("BtSearchAllCategoryId = \"_allcat_\"", model);
        Assert.Contains("BtSearchModules.Count > 0", model);
        Assert.Contains("IsStableBtSearchText(BtSearchKeyword, required: true)", model);
        Assert.Contains("IsStableBtSearchText(BtSearchTitleFilter, required: false)", model);
        Assert.Contains("HasCurrentBtSearchCategory()", model);
        Assert.Contains("HasAvailableBtSearchModuleScope()", model);
        Assert.Contains("BtSearchSelectedModuleIds.All(available.Contains)", model);
        Assert.Contains("value.Any(char.IsControl)", model);
        Assert.Equal(8, Count(model, "InvalidateBtSearchResultsForCriteriaChange"));
        Assert.Contains("_btSearchCreationHandled = true", model);
        Assert.Contains("await CreateTaskAsync(selected.DownloadUri)", model);
        Assert.DoesNotContain("CleanBtSearch", model + state, StringComparison.Ordinal);
        Assert.DoesNotContain("SYNO.DownloadStation", model + state, StringComparison.Ordinal);
    }

    [Fact]
    public void SearchHasCancellationProfileRepositoryAndLateGenerationGates()
    {
        var model = Read(
            "windows/src/LanStash.App/Features/Downloads/DownloadStationViewModel.BtSearch.cs");
        var page = Read("windows/src/LanStash.App/Views/DownloadStationPage.BtSearch.cs");
        var pageRoot = Read("windows/src/LanStash.App/Views/DownloadStationPage.xaml.cs");
        var repository = Read(
            "windows/src/LanStash.Infrastructure/Features/Downloads/PublicApi/" +
            "DsmRepository.DownloadStation.BtSearch.cs");

        Assert.Contains("CancellationTokenSource", model);
        Assert.Contains("_btSearchGeneration", model);
        Assert.Contains("ReferenceEquals(repository, _repository)", model);
        Assert.Contains("ActiveProfileId == repository.ProfileId", model);
        Assert.Contains("EndBtSearchSession", page);
        Assert.Contains("CloseBtSearchDialog", page);
        Assert.Contains("CloseBtSearchDialog();", pageRoot);
        Assert.Contains("CloseButtonText", page);
        Assert.Contains("CancelCurrentBtSearch", model);
        Assert.Contains("ObserveBtSearchTask(session)", page);
        Assert.Contains("ObserveBtSearchTask(_viewModel.SearchBtAsync())", page);
        Assert.Contains("dialog.Content = null", page);
        Assert.DoesNotContain("await session", page, StringComparison.Ordinal);
        Assert.Contains("private const int MaximumBtSearchResults = 200", repository);
        Assert.Contains("items.Count > MaximumBtSearchResults", repository);
        Assert.Contains("request.Keyword.Any(char.IsControl)", repository);
        Assert.Equal(1, Count(repository, "await TryCleanBtSearchTaskAsync(taskId)"));
    }

    private static int Count(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;

    private static string Read(string relativePath)
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
