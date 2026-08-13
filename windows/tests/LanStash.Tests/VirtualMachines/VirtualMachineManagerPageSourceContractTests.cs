using System.Xml.Linq;

namespace LanStash.Tests;

public sealed class VirtualMachineManagerPageSourceContractTests
{
    [Fact]
    public void PageHasDedicatedMachineListDetailAndSevenIndependentReadOnlySections()
    {
        var xaml = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml.cs");

        Assert.Contains("x:Name=\"MachinePane\"", xaml);
        Assert.Contains("x:Name=\"DetailPane\"", xaml);
        Assert.Contains("SelectedMachine.CpuText", xaml);
        Assert.Contains("SelectedMachine.MemoryText", xaml);
        Assert.Contains("SelectedMachine.StorageText", xaml);
        Assert.Contains("SelectedMachine.HostText", xaml);
        Assert.Contains("x:Name=\"HostsList\"", xaml);
        Assert.Contains("x:Name=\"StoragesList\"", xaml);
        Assert.Contains("x:Name=\"NetworksList\"", xaml);
        Assert.Contains("x:Name=\"ImagesList\"", xaml);
        Assert.Contains("x:Name=\"ProtectionList\"", xaml);
        Assert.Contains("x:Name=\"EventsList\"", xaml);
        Assert.Contains("VirtualMachineManagerReadOnly", xaml);
        Assert.Contains("VirtualMachineManagerSessionExpired", xaml);
        Assert.Contains("x:Name=\"SessionExpiredNotice\"", xaml);
        Assert.Contains("_viewModel.RequiresReconnect", source);
        Assert.Contains("SessionExpiredNotice.IsOpen = _viewModel.RequiresReconnect", source);
        Assert.Contains("ApplySectionState(_viewModel.HostsState", source);
        Assert.Contains("ApplySectionState(_viewModel.StoragesState", source);
        Assert.Contains("ApplySectionState(_viewModel.NetworksState", source);
        Assert.Contains("ApplySectionState(_viewModel.ImagesState", source);
        Assert.Contains("ApplySectionState(_viewModel.ProtectionState", source);
        Assert.Contains("ApplySectionState(_viewModel.EventsState", source);
    }

    [Fact]
    public void EverySectionSupportsLoadingEmptyErrorContentAndUnavailable()
    {
        var xaml = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml.cs");

        foreach (var section in new[] { "Machines", "Hosts", "Storages", "Networks", "Images", "Protection", "Events" })
        {
            Assert.Contains($"x:Name=\"{section}LoadingState\"", xaml);
            Assert.Contains($"x:Name=\"{section}EmptyState\"", xaml);
            Assert.Contains($"x:Name=\"{section}ErrorState\"", xaml);
            Assert.Contains($"x:Name=\"{section}UnavailableState\"", xaml);
        }
        Assert.Contains("state == VirtualMachineManagerContentState.Content", source);
        Assert.Contains("state == VirtualMachineManagerContentState.Loading", source);
        Assert.Contains("state == VirtualMachineManagerContentState.Empty", source);
        Assert.Contains("state == VirtualMachineManagerContentState.Error", source);
        Assert.Contains("state == VirtualMachineManagerContentState.Unavailable", source);
    }

    [Fact]
    public void PageUsesFluentTouchKeyboardNarratorTextScaleAndSystemMotion()
    {
        var xaml = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml");
        var source = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml.cs");

        Assert.True(Count(xaml, "MinHeight=\"44\"") >= 3);
        Assert.Contains("Key=\"Left\"", xaml);
        Assert.Contains("Key=\"F5\"", xaml);
        Assert.Contains("Modifiers=\"Menu\"", xaml);
        Assert.Contains("AutomationProperties.Name=\"{x:Bind AutomationName}\"", xaml);
        Assert.Contains("AutomationProperties.HeadingLevel=\"Level1\"", xaml);
        Assert.True(Count(xaml, "AutomationProperties.LiveSetting=\"Polite\"") >= 5);
        Assert.Contains("ThemeResource CardBackgroundFillColorDefaultBrush", xaml);
        Assert.Contains("TextWrapping=\"Wrap\"", xaml);
        Assert.Contains("CompactWidth = 760", source);
        Assert.DoesNotContain("Storyboard", xaml);
        Assert.DoesNotContain("DoubleTapped", xaml + source);
    }

    [Fact]
    public void PageAndStateExposeNoWriteConsoleOrRawDiagnosticSurface()
    {
        var combined =
            Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml") +
            Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml.cs") +
            Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineManagerState.cs") +
            Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineManagerViewModel.cs");

        foreach (var forbidden in new[]
        {
            "CreateVirtualMachine", "DeleteVirtualMachine", "StartVirtualMachine",
            "StopVirtualMachine", "PauseVirtualMachine", "ResumeVirtualMachine",
            "Power", "Console", "WebView", "noVNC", "pull_start", "NetworkWrite",
            "RawStatus", "RawError", "RawResponse", "RawDiagnostic", "HostId",
            "\"create\"", "\"set\"", "\"delete\"", "\"poweron\"",
            "\"poweroff\"", "method: \"shutdown\"", "\"pwr_ctl\"", "\"reset\""
        })
        {
            Assert.DoesNotContain(forbidden, combined, StringComparison.OrdinalIgnoreCase);
        }
        Assert.DoesNotContain("Resource.Type", combined, StringComparison.Ordinal);
    }

    [Fact]
    public void XamlIsWellFormedAndAllVisibleCopyUsesResourceKeys()
    {
        var xaml = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml");
        _ = XDocument.Parse(xaml);

        Assert.DoesNotContain(" Text=\"Virtual", xaml, StringComparison.Ordinal);
        Assert.DoesNotContain(" Header=\"Virtual", xaml, StringComparison.Ordinal);
        Assert.True(Count(xaml, "x:Uid=\"VirtualMachineManager") >= 25);
    }

    [Fact]
    public void SessionExpiredCopyIsLocalizedAndDistinctFromRefreshFailure()
    {
        var english = Read("windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = Read("windows/src/LanStash.App/Strings/zh-CN/Resources.resw");

        Assert.Contains("VirtualMachineManagerSessionExpired.Message", english);
        Assert.Contains("The session has expired. Please reconnect this NAS.", english);
        Assert.Contains("VirtualMachineManagerSessionExpired.Message", chinese);
        Assert.Contains("会话已失效，请重新连接这台 NAS。", chinese);
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
