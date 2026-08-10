using System.Xml.Linq;

namespace LanStash.Tests.NasAdmin;

public sealed class NasDetailsPageSourceContractTests
{
    [Fact]
    public void PageHasDedicatedFiveStateReadOnlyWinUiSurface()
    {
        var xaml = Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml.cs");

        Assert.Contains("x:Name=\"LoadingState\"", xaml);
        Assert.Contains("x:Name=\"EmptyState\"", xaml);
        Assert.Contains("x:Name=\"ErrorState\"", xaml);
        Assert.Contains("x:Name=\"UnavailableState\"", xaml);
        Assert.Contains("x:Name=\"ContentState\"", xaml);
        Assert.Contains("NasDetailsReadOnly", xaml);
        Assert.Contains("Key=\"F5\"", xaml);
        Assert.Contains("AutomationProperties.LiveSetting=\"Polite\"", xaml);
        Assert.True(Count(xaml, "MinHeight=\"44\"") >= 2);
        Assert.Contains("_viewModel.HasRefreshError", source);
        Assert.Contains("_viewModel.Deactivate();", source);
    }

    [Fact]
    public void PageShowsOnlyWhitelistedSectionRowsAndNoWriteActions()
    {
        var combined =
            Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml") +
            Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml.cs") +
            Read("windows/src/LanStash.App/Features/NasAdmin/NasDetailsState.cs") +
            Read("windows/src/LanStash.App/Features/NasAdmin/NasDetailsViewModel.cs");

        foreach (var allowed in new[]
        {
            "NasDetailsSectionPackages",
            "NasDetailsSectionTasks",
            "NasDetailsSectionLogs",
            "NasDetailsSectionConnections",
            "NasDetailsTruncated",
        })
        {
            Assert.Contains(allowed, combined);
        }
        foreach (var forbidden in new[]
        {
            "kick_connection",
            "run task",
            "RunTask",
            "set_enable",
            "Package.Control",
            "Package.Uninstallation",
            "disconnect",
            "log message",
            "account",
            "source address",
            "device_id",
            "process_id",
        })
        {
            Assert.DoesNotContain(forbidden, combined, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public void ShellRoutesNasSettingsToDedicatedPageAndDisposesItOnProfileChanges()
    {
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains("private NasDetailsPage? _nasDetails;", shell);
        Assert.Contains("private INasDetailsRepository? _nasDetailsRepository;", shell);
        Assert.Contains("module == AppModule.NasSettings", shell);
        Assert.Contains("new NasDetailsPage(nasRepository)", shell);
        Assert.Contains("new UnavailableNasDetailsRepository", shell);
        Assert.Contains("!ReferenceEquals(_nasDetailsRepository, nasRepository)", shell);
        Assert.Contains("CloseNasDetailsPage();", shell);
        Assert.Contains(": INasDetailsRepository", shell);
    }

    [Fact]
    public void XamlAndResourcesAreWellFormed()
    {
        var xaml = Read("windows/src/LanStash.App/Views/NasDetailsPage.xaml");
        _ = XDocument.Parse(xaml);

        foreach (var uid in new[]
        {
            "NasDetailsTitle",
            "NasDetailsDescription",
            "NasDetailsRefresh",
            "NasDetailsReadOnly",
            "NasDetailsRefreshError",
            "NasDetailsSectionList",
            "NasDetailsItemList",
            "NasDetailsLoading",
            "NasDetailsEmptyTitle",
            "NasDetailsErrorTitle",
            "NasDetailsTryAgain",
            "NasDetailsUnavailableTitle",
        })
        {
            Assert.Contains($"x:Uid=\"{uid}\"", xaml, StringComparison.Ordinal);
        }
        Assert.DoesNotContain(" Text=\"NAS", xaml, StringComparison.Ordinal);
        Assert.DoesNotContain(" Content=\"Refresh", xaml, StringComparison.Ordinal);
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
