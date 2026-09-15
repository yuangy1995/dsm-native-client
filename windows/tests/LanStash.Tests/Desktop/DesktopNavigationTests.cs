using LanStash.App.Features.Shell;
using LanStash.Domain;

namespace LanStash.Tests.Desktop;

public sealed class DesktopNavigationTests
{
    [Fact]
    public void EveryDestinationHasAUniqueStableIdentifier()
    {
        var entries = Enum.GetValues<AppModule>().SelectMany(DesktopNavigationCatalog.Children).ToArray();
        Assert.Equal(entries.Length, entries.Select(entry => entry.Destination).Distinct().Count());
        Assert.All(entries, entry => { Assert.True(DesktopNavigationCatalog.IsValid(entry.Destination)); Assert.NotEmpty(entry.TitleKey); Assert.NotEmpty(entry.Glyph); });
    }

    [Theory]
    [InlineData(AppModule.Files, DesktopSection.PhotoAlbums)]
    [InlineData(AppModule.Photos, DesktopSection.Favorites)]
    [InlineData(AppModule.Settings, DesktopSection.VirtualHosts)]
    public void CrossModuleLeafDestinationsAreRejected(AppModule module, DesktopSection section) =>
        Assert.False(DesktopNavigationCatalog.IsValid(new(module, section)));

    [Theory]
    [InlineData(0, 210)] [InlineData(241, 241)] [InlineData(900, 280)]
    [InlineData(double.NaN, 241)] [InlineData(double.PositiveInfinity, 241)]
    public void SidebarWidthUsesMacBoundsAndRejectsNonFiniteValues(double input, double expected) =>
        Assert.Equal(expected, DesktopNavigationCatalog.ClampSidebarWidth(input));

    [Fact]
    public void HiddenPagesCannotBeReactivatedByRestoringTheWindow()
    {
        var source = RepositorySource.Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        Assert.Contains("_isWindowVisible && ReferenceEquals(ContentFrame.Content, _photos)", source);
        Assert.Contains("_isWindowVisible && ReferenceEquals(ContentFrame.Content, _chat)", source);
        Assert.Contains("_isWindowVisible && ReferenceEquals(ContentFrame.Content, _activity)", source);
        Assert.Contains("version != _navigationVersion", source);
        Assert.Contains("ConfirmNavigationAwayAsync", source);
        Assert.DoesNotContain("new WorkspacePage", source);
    }
}
