using LanStash.App.Features.Settings;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class WorkspaceNavigationTests
{
    private static readonly AppModule[] Modules = Enum.GetValues<AppModule>();

    [Fact]
    public void EveryDestinationHasOneStableRouteAndAnAvailableModule()
    {
        Assert.Equal(Enum.GetValues<WorkspaceDestination>().Length, WorkspaceRoutes.All.Count);
        Assert.Equal(WorkspaceRoutes.All.Count, WorkspaceRoutes.All.Select(route => route.Destination).Distinct().Count());
        Assert.All(WorkspaceRoutes.All, route =>
        {
            Assert.True(Enum.IsDefined(route.Module));
            Assert.False(string.IsNullOrWhiteSpace(route.TitleKey));
            Assert.False(string.IsNullOrWhiteSpace(route.Glyph));
            Assert.Same(route, WorkspaceRoutes.Get(route.Destination));
        });
    }

    [Fact]
    public void NewWorkspaceSelectsFilesAndExpandsTheirCollections()
    {
        var id = Guid.NewGuid();
        var navigation = new WorkspaceNavigation(id, Modules);
        Assert.Equal(id, navigation.ProfileId);
        Assert.Equal(WorkspaceDestination.Files, navigation.Current);
        Assert.Contains(WorkspaceRoutes.Get(WorkspaceDestination.Favorites), navigation.VisibleRoutes());
        Assert.DoesNotContain(WorkspaceRoutes.Get(WorkspaceDestination.PhotoAlbums), navigation.VisibleRoutes());
        Assert.False(navigation.CanGoBack);
    }

    [Fact]
    public void CollapsingSelectedModuleSurvivesNavigationRebuild()
    {
        var navigation = new WorkspaceNavigation(Guid.NewGuid(), Modules);
        navigation.ToggleExpanded(AppModule.Files);
        navigation.SetAvailableModules(Modules);
        Assert.False(navigation.IsExpanded(AppModule.Files));
        Assert.DoesNotContain(navigation.VisibleRoutes(), route => route.Module == AppModule.Files && route.IsChild);
        Assert.Equal(WorkspaceDestination.Files, navigation.Current);
    }

    [Fact]
    public void SettingsDoesNotJumpBackToFilesOnRebuild()
    {
        var navigation = new WorkspaceNavigation(Guid.NewGuid(), Modules);
        navigation.Navigate(WorkspaceDestination.Settings);
        navigation.SetAvailableModules(Modules);
        Assert.Equal(WorkspaceDestination.Settings, navigation.Current);
        Assert.True(navigation.IsExpanded(AppModule.Settings));
    }

    [Fact]
    public void RevokingModulePrunesHistoryAndSelectsSettings()
    {
        var navigation = new WorkspaceNavigation(Guid.NewGuid(), Modules);
        navigation.Navigate(WorkspaceDestination.Chat);
        navigation.Navigate(WorkspaceDestination.ContainerImages);
        navigation.SetAvailableModules([AppModule.Files]);
        Assert.Equal(WorkspaceDestination.Settings, navigation.Current);
        Assert.False(navigation.Navigate(WorkspaceDestination.ContainerList));
        Assert.False(navigation.Navigate((WorkspaceDestination)int.MaxValue));
        Assert.DoesNotContain(navigation.VisibleRoutes(), route => route.Module == AppModule.Containers);
        Assert.True(navigation.GoBack());
        Assert.Equal(WorkspaceDestination.Files, navigation.Current);
        Assert.False(navigation.GoBack());
    }

    [Fact]
    public void HistoryIsBoundedAndRepeatedSelectionIsIdempotent()
    {
        var navigation = new WorkspaceNavigation(Guid.NewGuid(), Modules);
        for (var i = 0; i < 400; i++)
            navigation.Navigate(i % 2 == 0 ? WorkspaceDestination.Chat : WorkspaceDestination.Photos);
        Assert.Equal(WorkspaceNavigation.HistoryLimit, navigation.HistoryCount);
        navigation.Navigate(navigation.Current);
        Assert.Equal(WorkspaceNavigation.HistoryLimit, navigation.HistoryCount);
        for (var i = 0; i < WorkspaceNavigation.HistoryLimit; i++) Assert.True(navigation.GoBack());
        Assert.False(navigation.GoBack());
    }

    [Fact]
    public void WorkspaceStateNeverLeaksAcrossProfiles()
    {
        var first = new WorkspaceNavigation(Guid.NewGuid(), Modules);
        var second = new WorkspaceNavigation(Guid.NewGuid(), [AppModule.Files]);
        first.Navigate(WorkspaceDestination.PhotoSharing);
        Assert.Equal(WorkspaceDestination.Files, second.Current);
        Assert.False(second.IsAvailable(WorkspaceDestination.Photos));
        Assert.False(second.CanGoBack);
        Assert.NotEqual(first.ProfileId, second.ProfileId);
    }

    [Fact]
    public void EmptyOrUnknownCapabilitiesRetainOnlyLocalSettings()
    {
        var navigation = new WorkspaceNavigation(Guid.NewGuid(), [(AppModule)int.MaxValue]);
        Assert.Equal(WorkspaceDestination.Settings, navigation.Current);
        Assert.All(navigation.VisibleRoutes(), route => Assert.Equal(AppModule.Settings, route.Module));
    }

    [Theory]
    [InlineData(0, 210)]
    [InlineData(241, 241)]
    [InlineData(1000, 280)]
    [InlineData(double.NaN, 241)]
    [InlineData(double.PositiveInfinity, 241)]
    [InlineData(double.NegativeInfinity, 241)]
    public void SidebarWidthUsesMacBoundsAndRejectsNonFiniteValues(double input, double expected) =>
        Assert.Equal(expected, WorkspaceLayout.ClampSidebar(input));
}
