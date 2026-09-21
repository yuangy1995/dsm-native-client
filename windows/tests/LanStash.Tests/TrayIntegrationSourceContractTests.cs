namespace LanStash.Tests;

public sealed class TrayIntegrationSourceContractTests
{
    [Fact]
    public void ShellRestartUsesCurrentTooltipAndRestoresTheIcon()
    {
        var source = Read("windows/src/LanStash.App/TrayIcon.cs");
        Assert.Contains("RegisterWindowMessage(\"TaskbarCreated\")", source);
        Assert.Contains("message == _taskbarCreatedMessage", source);
        Assert.Contains("CreateData(_tooltip)", source);
        Assert.Contains("_notifyIcon = notifyIcon ?? ShellNotifyIcon", source);
        Assert.Contains("_registered = _notifyIcon(0, ref data)", source);
        Assert.Contains("if (!_registered && !EnsureRegistered()) _showWindow()", source);
    }

    [Fact]
    public void VersionFourKeyboardAndIconIdentityAreHandled()
    {
        var source = Read("windows/src/LanStash.App/TrayIcon.cs");
        Assert.Contains("data.TimeoutOrVersion = 4", source);
        Assert.Contains("_usesVersion4 = _notifyIcon(4, ref data)", source);
        Assert.Contains("longParameter.ToInt64() >> 16", source);
        Assert.Contains("SelectMessage or KeySelectMessage", source);
        Assert.Contains("0x0080", source);
    }

    [Fact]
    public void UnrelatedWindowCommandsNeverDispatchTrayActions()
    {
        var source = Read("windows/src/LanStash.App/TrayIcon.cs");
        Assert.DoesNotContain("WindowCommandMessage", source);
        Assert.Contains("HandleCommand(command)", source);
        Assert.Contains("return CallWindowProc(", source);
        Assert.Contains("if (_mappingCount() > 0) _toggleMappings()", source);
        Assert.Contains("if (_issueCount() > 0) _showIssues()", source);
    }

    [Fact]
    public void CloseDoesNotHideTheWindowWithoutAnAvailableTray()
    {
        var source = Read("windows/src/LanStash.App/MainWindow.xaml.cs");
        Assert.Contains("if (_trayIcon.EnsureRegistered()) sender.Hide();", source);
        Assert.Contains("else if (sender.Presenter is OverlappedPresenter presenter) presenter.Minimize();", source);
    }

    [Fact]
    public void DisposalPreventsReregistrationAndRestoresTheWindowProcedure()
    {
        var source = Read("windows/src/LanStash.App/TrayIcon.cs");
        Assert.Contains("if (_disposed) return false;", source);
        Assert.Contains("if (_disposed) return;", source);
        Assert.Contains("_disposed = true;", source);
        Assert.Contains("_notifyIcon(2, ref data)", source);
        Assert.Contains("RestoreWindowProcedure();", source);
    }

    private static string Read(string path)
    {
        for (var directory = new DirectoryInfo(Directory.GetCurrentDirectory()); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, path);
            if (File.Exists(candidate)) return File.ReadAllText(candidate);
        }
        throw new FileNotFoundException(path);
    }
}
