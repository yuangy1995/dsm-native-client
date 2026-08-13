using System.Xml.Linq;

namespace LanStash.Tests;

public sealed class ContainerManagerPageSourceContractTests
{
    [Fact]
    public void PageHasDedicatedAdaptiveListDetailAndAllContentStates()
    {
        var xaml = Read("windows/src/LanStash.App/Views/ContainerManagerPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/ContainerManagerPage.xaml.cs");

        Assert.Contains("x:Name=\"LoadingState\"", xaml);
        Assert.Contains("x:Name=\"EmptyState\"", xaml);
        Assert.Contains("x:Name=\"FilteredEmptyState\"", xaml);
        Assert.Contains("x:Name=\"ErrorState\"", xaml);
        Assert.Contains("x:Name=\"ContentState\"", xaml);
        Assert.Contains("x:Name=\"UnavailableState\"", xaml);
        Assert.Contains("x:Name=\"ListPane\"", xaml);
        Assert.Contains("x:Name=\"DetailPane\"", xaml);
        Assert.Contains("CompactWidth = 760", source);
        Assert.Contains("_compactShowsList", source);
    }

    [Fact]
    public void PageUsesTypedFiltersRefreshRetentionAndOnlySafeFields()
    {
        var xaml = Read("windows/src/LanStash.App/Views/ContainerManagerPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/ContainerManagerPage.xaml.cs");

        Assert.Contains("ContainerManagerFilterAll", xaml);
        Assert.Contains("ContainerManagerFilterRunning", xaml);
        Assert.Contains("ContainerManagerFilterStopped", xaml);
        Assert.Contains("ContainerManagerFilterAttention", xaml);
        Assert.Contains("ContainerManagerRefreshError", xaml);
        Assert.Contains("_viewModel.HasRefreshError", source);
        Assert.Contains("ContainerManagerSessionExpired", xaml);
        Assert.Contains("x:Name=\"SessionExpiredNotice\"", xaml);
        Assert.Contains("_viewModel.RequiresReconnect", source);
        Assert.Contains("SessionExpiredNotice.IsOpen = _viewModel.RequiresReconnect", source);
        Assert.Contains("SelectedContainer.Name", xaml);
        Assert.Contains("SelectedContainer.StatusText", xaml);
        Assert.Contains("SelectedContainer.ImageText", xaml);
        Assert.DoesNotContain("SelectedContainer.Id", xaml);
        Assert.DoesNotContain("Container.Id", xaml);
        Assert.DoesNotContain("Container.State", xaml);
        Assert.DoesNotContain("{Binding SelectedContainer.Image}", xaml);
        Assert.DoesNotContain("{x:Bind Container.Image}", xaml);
    }

    [Fact]
    public void PageSupportsKeyboardTouchNarratorThemesAndReducedMotion()
    {
        var xaml = Read("windows/src/LanStash.App/Views/ContainerManagerPage.xaml");

        Assert.True(Count(xaml, "MinHeight=\"44\"") >= 4);
        Assert.Contains("Key=\"F5\"", xaml);
        Assert.Contains("Key=\"Left\"", xaml);
        Assert.Contains("Modifiers=\"Menu\"", xaml);
        Assert.Contains("AutomationProperties.Name=\"{x:Bind AutomationName}\"", xaml);
        Assert.Contains("AutomationProperties.HeadingLevel=\"Level1\"", xaml);
        Assert.True(Count(xaml, "AutomationProperties.LiveSetting=\"Polite\"") >= 4);
        Assert.Contains("ThemeResource CardBackgroundFillColorDefaultBrush", xaml);
        Assert.Contains("TextWrapping=\"Wrap\"", xaml);
        Assert.DoesNotContain("Storyboard", xaml);
        Assert.DoesNotContain("DoubleTapped", xaml);
    }

    [Fact]
    public void PageAndRouteExposeFiveReadSectionsAndNoWriteActions()
    {
        var combined =
            Read("windows/src/LanStash.App/Views/ContainerManagerPage.xaml") +
            Read("windows/src/LanStash.App/Views/ContainerManagerPage.xaml.cs") +
            Read("windows/src/LanStash.App/Features/Containers/ContainerManagerState.cs") +
            Read("windows/src/LanStash.App/Features/Containers/ContainerManagerViewModel.cs") +
            Read("windows/src/LanStash.Infrastructure/Features/Containers/PrivateApi/DsmRepository.ContainerManager.Private.cs");

        foreach (var section in new[] { "Containers", "Images", "Networks", "Projects", "Events" })
        {
            Assert.Contains($"ContainerManager{section}Tab", combined, StringComparison.Ordinal);
        }
        foreach (var forbidden in new[]
        {
            "Registry", "Compose", "Terminal", "LoadLogs", "CreateContainer",
            "DeleteContainer", "StartContainer", "StopContainer", "RestartContainer",
            "ControlContainer", "pull_start", "WebView", "noVNC", "RawResponse",
            "RawDiagnostic", "\"create\"", "\"set\"", "\"remove\"",
            "\"delete\"", "\"start\"", "\"stop\"", "\"restart\""
        })
        {
            Assert.DoesNotContain(forbidden, combined, StringComparison.OrdinalIgnoreCase);
        }
    }

    [Fact]
    public void XamlIsWellFormedAndStaticCopyUsesResourceKeys()
    {
        var xaml = Read("windows/src/LanStash.App/Views/ContainerManagerPage.xaml");
        _ = XDocument.Parse(xaml);

        Assert.True(Count(xaml, "x:Uid=\"ContainerManager") >= 25);
        Assert.DoesNotContain(" Text=\"Container", xaml, StringComparison.Ordinal);
        Assert.DoesNotContain(" Header=\"Container", xaml, StringComparison.Ordinal);
    }

    [Fact]
    public void SessionExpiredCopyIsLocalizedAndDistinctFromRefreshFailure()
    {
        var english = Read("windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = Read("windows/src/LanStash.App/Strings/zh-CN/Resources.resw");

        Assert.Contains("ContainerManagerSessionExpired.Message", english);
        Assert.Contains("The session has expired. Please reconnect this NAS.", english);
        Assert.Contains("ContainerManagerSessionExpired.Message", chinese);
        Assert.Contains("会话已失效，请重新连接这台 NAS。", chinese);
    }

    [Fact]
    public void UnavailableShellRepositoryDeclaresNoReadFeatures()
    {
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains("ContainerManagerAvailabilityStatus.Unavailable", shell);
        Assert.Contains("new HashSet<ContainerManagerReadFeature>()", shell);
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
