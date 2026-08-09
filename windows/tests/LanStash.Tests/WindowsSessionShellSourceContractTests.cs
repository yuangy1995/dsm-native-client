namespace LanStash.Tests;

public sealed class WindowsSessionShellSourceContractTests
{
    [Fact]
    public void ConnectionFlowsRemainCancelableWithoutUsingRemoteLogoutForSwitching()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/ViewModels/AppViewModel.cs");

        Assert.Contains("public void CancelConnection()", source);
        Assert.Contains("var input = new ConnectAttempt(", source);
        Assert.Contains("input.Password", source);
        Assert.Contains("input.Otp", source);
        Assert.Contains("_connectionAttempts.ThrowIfNotCurrent(attempt);", source);
        Assert.Contains("authenticationFailure: true", source);
        Assert.Contains(
            "ConnectionRecoveryPolicy.ShouldInvalidateSavedSession(error)",
            source);
        Assert.Contains("catch (OperationCanceledException)", source);
        var switchBody = SliceMethod(source, "public async Task SwitchProfileAsync", "public void BeginAddingProfile");
        Assert.DoesNotContain("LogoutAsync", switchBody);
        var logoutBody = SliceMethod(source, "public async Task LogoutAsync", "public async Task AddDesktopDriveAsync");
        Assert.Contains("_api.LogoutAsync", logoutBody);
    }

    [Fact]
    public void ShellAndLoginExposeCancelAndProfileManagementActions()
    {
        var login = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/LoginPage.xaml");
        var shell = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains("x:Name=\"CancelConnectButton\"", login);
        Assert.Contains("x:Name=\"ConnectionFields\"", login);
        Assert.Contains("MinHeight=\"44\"", login);
        Assert.Contains("SwitchProfile_Click", shell);
        Assert.Contains("AddProfile_Click", shell);
        Assert.Contains("DeleteProfile_Click", shell);
    }

    [Fact]
    public void VirtualMachinesUseProfileBoundDedicatedReadOnlyRoute()
    {
        var shell = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var branch = SliceMethod(
            shell,
            "if (module == AppModule.VirtualMachines)",
            "ContentFrame.Content = _workspace;");

        Assert.Contains("IVirtualMachineManagerRepository", branch);
        Assert.Contains("virtualMachineRepository.ProfileId != virtualMachineProfile.Id", branch);
        Assert.Contains("new VirtualMachineManagerPage", branch);
        Assert.Contains("UnavailableVirtualMachineManagerRepository", branch);
        Assert.Contains("return;", branch);
        Assert.DoesNotContain("ShowModuleAsync", branch);
        Assert.Contains("_virtualMachines?.Dispose();", shell);
    }

    [Fact]
    public void ContainersUseProfileBoundDedicatedReadOnlyRouteWithoutWorkspaceFallback()
    {
        var shell = ReadRepositoryFile(
            "windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var workspace = ReadRepositoryFile(
            "windows/src/LanStash.App/ViewModels/WorkspaceViewModel.cs");
        var repository = ReadRepositoryFile(
            "windows/src/LanStash.Infrastructure/DsmRepository.cs");
        var branch = SliceMethod(
            shell,
            "if (module == AppModule.Containers)",
            "if (module == AppModule.VirtualMachines)");

        Assert.Contains("IContainerManagerRepository", branch);
        Assert.Contains("containerRepository.ProfileId != containerProfile.Id", branch);
        Assert.Contains("new ContainerManagerPage", branch);
        Assert.Contains("UnavailableContainerManagerRepository", branch);
        Assert.Contains("ReferenceEquals(_containerRepository, containerRepository)", branch);
        Assert.True(Count(branch, "return;") >= 2);
        Assert.DoesNotContain("ShowModuleAsync", branch);
        Assert.Contains("_containers?.Dispose();", shell);
        Assert.DoesNotContain("AppModule.Containers", workspace);
        Assert.DoesNotContain("WorkspaceCategory.Containers", workspace);
        Assert.DoesNotContain("WorkspaceCategory.Projects", workspace);
        Assert.Contains("HasInternalObservedContainerContract", repository);
        Assert.Contains("new[] { AppModule.Containers }", repository);
    }

    private static int Count(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;

    private static string SliceMethod(string source, string start, string next)
    {
        var startIndex = source.IndexOf(start, StringComparison.Ordinal);
        var endIndex = source.IndexOf(next, startIndex, StringComparison.Ordinal);
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
        throw new DirectoryNotFoundException(
            $"Unable to locate repository file: {relativePath}");
    }
}
