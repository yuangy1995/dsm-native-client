using System.Xml.Linq;

namespace LanStash.Tests;

public sealed class VirtualMachineManagerPageSourceContractTests
{
    [Fact]
    public void NetworkManagementUsesConfirmedScopedWorkflowAndDisposal()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "windows"))) directory = directory.Parent;
        Assert.NotNull(directory);
        string Read(string path) => File.ReadAllText(Path.Combine(directory.FullName, path));
        var page = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.Networks.cs");
        var model = Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineNetworksViewModel.cs");
        Assert.Contains("ContentDialogButton.Close", page);
        Assert.Contains("_repository.ProfileId != _viewModel.ActiveProfileId", page);
        Assert.Contains("_networksContent?.Dispose()", page);
        Assert.Contains("content.CanSubmit", page);
        Assert.Contains("content.ReviewAsync()", page);
        Assert.Contains("VirtualMachineNetworkRules.Freeze(item)", model);
        Assert.Contains("requests.Any(request => !inventory.Networks.Any", model);
        Assert.Contains("result.Status != MutationResultStatus.ConfirmedSuccess", model);
        Assert.DoesNotContain("SecurityCallAsync", page);
        Assert.DoesNotContain("Take(20)", model);
    }

    [Fact]
    public void CreationUsesReviewedRepositoryWorkflowAndExplicitConfirmationWithoutRawCalls()
    {
        var page = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.Creation.cs");
        var content = Read("windows/src/LanStash.App/Views/VirtualMachineCreationDialogContent.xaml.cs");
        var model = Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineCreationViewModel.cs");
        Assert.Contains("DefaultButton = ContentDialogButton.Close", page);
        Assert.Contains("content.CanSubmit", page); Assert.Contains("content.NeedsParentRefresh", page);
        Assert.Contains("RiskAcknowledgement.IsChecked == true", content);
        Assert.Contains("CreateMachineAsync", model); Assert.Contains("ReviewCreationAsync", model); Assert.Contains("ContinueCreationAsync", model);
        Assert.Contains("CloseCreationDialog()", Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml.cs"));
        Assert.DoesNotContain("CreateVirtualMachineCoreAsync", page + content + model);
        Assert.DoesNotContain("\"create\"", page + content + model); Assert.DoesNotContain("\"set\"", page + content + model);
        _ = XDocument.Parse(Read("windows/src/LanStash.App/Views/VirtualMachineCreationDialogContent.xaml"));
    }
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
        Assert.Contains("ThemeResource WorkspaceTileBrush", xaml);
        Assert.Contains("TextWrapping=\"Wrap\"", xaml);
        Assert.Contains("CompactWidth = 760", source);
        Assert.DoesNotContain("Storyboard", xaml);
        Assert.DoesNotContain("DoubleTapped", xaml + source);
    }

    [Fact]
    public void PageAndStateExposeReviewedControlsWithoutInlineWebViewOrRawDiagnostics()
    {
        var combined =
            Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml") +
            Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml.cs") +
            Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.Power.cs") +
            Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.Settings.cs") +
            Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.Tasks.cs") +
            Read("windows/src/LanStash.App/Views/VirtualMachineTasksControl.xaml.cs") +
            Read("windows/src/LanStash.App/Views/VirtualMachineSettingsDialogContent.xaml.cs") +
            Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineSettingsViewModel.cs") +
            Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineManagerState.cs") +
            Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineManagerViewModel.cs");

        foreach (var forbidden in new[]
        {
            "CreateVirtualMachine", "DeleteVirtualMachine", "StartVirtualMachine",
            "StopVirtualMachine", "PauseVirtualMachine", "ResumeVirtualMachine",
            "WebView", "noVNC", "pull_start", "NetworkWrite",
            "RawStatus", "RawError", "RawResponse", "RawDiagnostic", "HostId",
            "\"create\"", "\"set\"", "\"delete\"", "\"poweron\"",
            "\"poweroff\"", "method: \"shutdown\"", "\"pwr_ctl\"", "\"reset\""
        })
        {
            Assert.DoesNotContain(forbidden, combined, StringComparison.OrdinalIgnoreCase);
        }
        Assert.DoesNotContain("Resource.Type", combined, StringComparison.Ordinal);
        Assert.Contains("VirtualMachinePowerRules.CanRequest", combined);
        Assert.Contains("DefaultButton = ContentDialogButton.Close", combined);
        Assert.Contains("content.CanSubmit", combined);
        Assert.Contains("content.CanSave", combined);
        Assert.Contains("CloseSettingsDialog()", combined);
        Assert.Contains("VirtualMachineSettingsRules.Validate", combined);
        Assert.Contains("TasksPane.Dispose()", combined);
        Assert.Contains("SetVisibleAsync(visible)", combined);
        Assert.Contains("_repository.CanOpenConsole", combined);
        Assert.Contains("CloseConsoleWindow()", combined);
    }

    [Fact]
    public void ConsoleWindowRequiresRuntimeIsolationAndCannotLaunchExternalOrWeakenCertificateChecks()
    {
        var window = Read("windows/src/LanStash.App/Views/VirtualMachineConsoleWindow.cs");
        Assert.Contains("IsInPrivateModeEnabled = true", window);
        Assert.Contains("_core.Profile.IsInPrivateModeEnabled", window);
        Assert.Contains("_profile.Matches(_environment.UserDataFolder)", window);
        Assert.True(window.IndexOf("_core.Profile.IsInPrivateModeEnabled", StringComparison.Ordinal) < window.IndexOf("session.InstallCookie", StringComparison.Ordinal));
        Assert.Contains("cookie.IsSecure = true", window); Assert.Contains("cookie.IsHttpOnly = true", window);
        Assert.Contains("CoreWebView2CookieSameSiteKind.Strict", window); Assert.Contains("document.ResponseHeaders(session.Policy, session.UsesManagedTransport)", window);
        Assert.Contains("else session.InstallCookie", window);
        Assert.Contains("if (session.UsesManagedTransport)", window);
        Assert.Contains("AddScriptToExecuteOnDocumentCreatedAsync(bridge.Script)", window);
        Assert.Contains("bridge.AcceptAsync(source, e.WebMessageAsJson)", window);
        Assert.Contains("session.Policy.ManagedAssetMediaType(uri) is null", window);
        Assert.Contains("await session.LoadAssetAsync(uri, _lifetime.Token)", window);
        Assert.Contains("_bridge?.Dispose()", window);
        Assert.Contains("CoreWebView2ServerCertificateErrorAction.Cancel", window);
        Assert.Contains("CoreWebView2PermissionState.Deny", window);
        Assert.Contains("AreHostObjectsAllowed = false", window); Assert.Contains("IsWebMessageEnabled = false", window);
        Assert.Contains("BrowserProcessExited", window); Assert.Contains("_session?.Dispose()", window);
        Assert.DoesNotContain("CoreWebView2ServerCertificateErrorAction.AlwaysAllow", window);
        Assert.DoesNotContain("LaunchUriAsync", window); Assert.DoesNotContain("NavigateToString", window);
        Assert.DoesNotContain("ignore-certificate-errors", window);
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

    [Fact]
    public void BatchPowerUsesNativeConfirmationSerialExecutionAndReadOnlyReview()
    {
        var xaml = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml");
        var page = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.Batch.cs");
        var model = Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineBatchViewModel.cs");
        Assert.Contains("BatchPowerButton", xaml);
        Assert.Contains("DefaultButton = ContentDialogButton.Close", page);
        Assert.Contains("VmBatchOffHint", page);
        Assert.Contains("dialog.Closing += (_, _) => model.Dispose()", page);
        Assert.Contains("model.Confirm(confirm.IsChecked == true)", page);
        Assert.Contains("fresh != item.Baseline", model);
        Assert.Contains("await _repository.ControlPowerAsync(new(request.ProfileId", model);
        Assert.DoesNotContain("Task.WhenAll", model);
        var review = model[model.IndexOf("public async Task ReviewAsync()", StringComparison.Ordinal)..model.IndexOf("public void Cancel()", StringComparison.Ordinal)];
        Assert.Contains("ReviewPowerAsync", review); Assert.DoesNotContain("ControlPowerAsync", review);
    }

    [Fact]
    public void DeletionUsesSharedConfirmationButKeepsItsOwnActionAndRecovery()
    {
        var xaml = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml");
        var page = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.Batch.cs");
        var model = Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineBatchViewModel.cs");
        Assert.Contains("DeleteMachinesButton", xaml); Assert.Contains("VmDeleteWarning", page); Assert.Contains("VmDeleteConfirm", page);
        Assert.Contains("VirtualMachineBatchAction.Delete", model); Assert.Contains("DeleteMachineAsync", model);
        Assert.Contains("ReviewDeletionAsync", model); Assert.Contains("IsDeletion && result.Status != MutationResultStatus.ConfirmedSuccess", model);
    }

    [Fact]
    public void TaskCleanupConfirmsFrozenScopeAndNeverCallsVmDeletionOrPower()
    {
        var page = Read("windows/src/LanStash.App/Views/VirtualMachineTasksControl.xaml.cs");
        var model = Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineTasksViewModel.Cleanup.cs");
        var repository = Read("windows/src/LanStash.Infrastructure/Features/VirtualMachines/PublicApi/DsmRepository.VirtualMachineTaskCleanup.cs");
        Assert.Contains("ContentDialogButton.Close", page); Assert.Contains("BeginCleanupConfirmation", page);
        Assert.Contains("!item.Task.IsProtected", model); Assert.Contains("RiskConfirmed = true", model);
        Assert.Contains("CreationPending.Values", repository); Assert.Contains("TaskCleanupState.Unknown", repository);
        Assert.DoesNotContain("DeleteMachineAsync", repository); Assert.DoesNotContain("ControlPowerAsync", repository);
        Assert.Contains("ReviewTaskCleanupCoreAsync", repository);
    }

    [Fact]
    public void ImageDeletionUsesTypedTargetsAndIndependentCapabilities()
    {
        var page = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.Batch.cs");
        var xaml = Read("windows/src/LanStash.App/Views/VirtualMachineManagerPage.xaml");
        var model = Read("windows/src/LanStash.App/Features/VirtualMachines/VirtualMachineBatchViewModel.cs");
        var repository = Read("windows/src/LanStash.Infrastructure/Features/VirtualMachines/PublicApi/DsmRepository.VirtualMachineImageDeletion.cs");
        Assert.Contains("DeleteImagesButton", xaml); Assert.Contains("VmImageDeleteWarning", page); Assert.Contains("VmImageDeleteConfirm", page);
        Assert.Contains("VirtualMachineSummary? Machine, VirtualizationResourceSummary? Image", model);
        Assert.Contains("LoadImageDeletionTargetsAsync", model); Assert.Contains("request.Baseline.Image!", model);
        Assert.Contains("CreationPending.Values", repository); Assert.Contains("[\"image_id\"] = pending.Id", repository);
        Assert.DoesNotContain("PublicGuestActionApi", repository); Assert.DoesNotContain("Task.Info", repository);
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
