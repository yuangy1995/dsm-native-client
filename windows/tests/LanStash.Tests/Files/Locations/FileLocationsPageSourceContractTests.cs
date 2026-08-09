using System.Xml.Linq;

namespace LanStash.Tests.Files.Locations;

public sealed class FileLocationsPageSourceContractTests
{
    [Fact]
    public void FilesPageUsesAnAdaptiveInternalLocationsPaneInsteadOfATopLevelModule()
    {
        var page = Read("windows/src/LanStash.App/Views/FilesPage.xaml");
        var code = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml");

        Assert.Contains("x:Name=\"LocationsSplitView\"", page);
        Assert.Contains("<views:FileLocationsView x:Name=\"LocationsPane\"", page);
        Assert.Contains("DisplayMode=\"Inline\"", page);
        Assert.Contains("SplitViewDisplayMode.Overlay", code);
        Assert.Contains("ActualWidth >= 900", code);
        Assert.Contains("AccessKey=\"L\"", page);
        Assert.DoesNotContain("FileLocations", shell);
    }

    [Fact]
    public void LocationSectionsExposeNativeStatesPartialTruncatedAndFortyEightPixelTargets()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FileLocationsView.xaml");
        var code = Read("windows/src/LanStash.App/Views/FileLocationsView.xaml.cs");

        foreach (var section in new[] { "Favorites", "Recycle", "Remote" })
        {
            Assert.Contains($"x:Name=\"{section}Section\"", xaml);
            Assert.Contains($"x:Name=\"{section}Loading\"", xaml);
            Assert.Contains($"x:Name=\"{section}Empty\"", xaml);
            Assert.Contains($"x:Name=\"{section}Error\"", xaml);
            Assert.Contains($"x:Name=\"{section}Items\"", xaml);
            Assert.Contains($"x:Name=\"{section}Truncated\"", xaml);
        }
        Assert.Contains("x:Name=\"RecyclePartial\"", xaml);
        Assert.Contains("x:Name=\"RemotePartial\"", xaml);
        Assert.True(Count(xaml, "MinHeight=\"48\"") >= 6);
        Assert.Contains("state.Items.Count > 0", code);
        Assert.Contains("state.IsRefreshing", code);
        Assert.Contains("state.State == FileLocationViewState.Error", code);
    }

    [Fact]
    public void NarratorGetsNameAndVisiblePathWhileHeadingsRemainSemantic()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FileLocationsView.xaml");

        Assert.True(Count(xaml, "AutomationProperties.HeadingLevel=\"Level2\"") >= 4);
        Assert.True(Count(xaml, "AutomationProperties.Name=\"{x:Bind") >= 4);
        Assert.True(Count(xaml, "AutomationProperties.HelpText=\"{x:Bind") >= 4);
        Assert.Contains("AutomationProperties.HelpText=\"{x:Bind RecyclePath}\"", xaml);
        Assert.DoesNotContain("AutomationProperties.Name=\"{x:Bind Path}\"", xaml);
    }

    [Fact]
    public void FailedOpenKeepsPaneVisibleAndClosingOverlayCancelsTheTransaction()
    {
        var page = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var control = Read("windows/src/LanStash.App/Views/FileLocationsView.xaml.cs");

        Assert.Contains("if (!opened)", control);
        Assert.Contains("OpenErrorBar.IsOpen = true;", control);
        Assert.Contains("LocationOpened?.Invoke", control);
        Assert.Contains("LocationsPane.CancelOpening();", page);
        Assert.Contains("_openCancellation?.Cancel();", control);
        Assert.Contains("_locationsViewModel.OpenLocationAsync(path, source, cancellationToken)", page);
        Assert.Contains("PaneClosed=\"LocationsSplitView_PaneClosed\"", Read("windows/src/LanStash.App/Views/FilesPage.xaml"));
    }

    [Fact]
    public void LocationFailureOrLifecycleCancellationPreservesTheVisibleBrowserBaseline()
    {
        var page = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var control = Read("windows/src/LanStash.App/Views/FileLocationsView.xaml.cs");
        var transaction = Slice(page, "private async Task<bool> OpenLocationAsync(", "private void LocationsPane_LocationOpened");
        var successGate = transaction.IndexOf("if (!opened || _disposed || !_locationsViewModel.IsActive)", StringComparison.Ordinal);

        Assert.True(successGate >= 0);
        Assert.True(transaction.IndexOf("CloseShareLinkDialog();", StringComparison.Ordinal) > successGate);
        Assert.True(transaction.IndexOf("await ClosePreviewAsync();", StringComparison.Ordinal) > successGate);
        Assert.True(transaction.IndexOf("FilterBox.Text = string.Empty;", StringComparison.Ordinal) > successGate);
        Assert.Contains("catch (ObjectDisposedException) when (_disposed || !_locationsViewModel.IsActive)", transaction);
        Assert.Contains("catch (InvalidOperationException) when (_disposed || !_locationsViewModel.IsActive)", transaction);
        Assert.Contains("cancellation.IsCancellationRequested || _viewModel?.IsActive != true", control);
        Assert.DoesNotContain("catch (Exception", control);
    }

    [Fact]
    public void TruncatedCopyDoesNotPromiseAnImplementationSpecificItemCount()
    {
        foreach (var path in new[]
        {
            "windows/src/LanStash.App/Strings/en-US/Resources.resw",
            "windows/src/LanStash.App/Strings/zh-CN/Resources.resw"
        })
        {
            var resources = XDocument.Parse(Read(path));
            foreach (var key in new[]
            {
                "FileLocationsFavoritesTruncated.Message",
                "FileLocationsRemoteTruncated.Message"
            })
            {
                var value = resources.Root!.Elements("data")
                    .Single(item => (string?)item.Attribute("name") == key)
                    .Element("value")!.Value;
                Assert.DoesNotContain("200", value, StringComparison.Ordinal);
            }
        }
    }

    [Fact]
    public void SharedFoldersUseTheTransactionalEmptyRootSeamAndDoNotInventAPath()
    {
        var control = Read("windows/src/LanStash.App/Views/FileLocationsView.xaml.cs");

        Assert.Contains("OpenAsync(string.Empty, FileLocationSource.Shares)", control);
        Assert.DoesNotContain("OpenAsync(\"/\", FileLocationSource.Shares)", control);
        Assert.DoesNotContain("while", Slice(control, "private async void Shares_Click", "private async void Favorite_Click"));
    }

    [Fact]
    public void RemoteAndRecycleHideWritesAndHandlersRepeatTheReadOnlyGuard()
    {
        var code = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");

        Assert.Contains("FileLocationSource.Remote or FileLocationSource.Recycle", code);
        Assert.Contains("ShareLinkButton.Visibility = IsReadOnlyLocation()", code);
        Assert.Contains("UploadButton.Visibility = IsReadOnlyLocation()", code);
        Assert.Contains("if (IsReadOnlyLocation() || !CanOpenShareLink()", code);
        Assert.Contains("_isChoosingUpload || IsReadOnlyLocation()", code);
        Assert.Contains("OpenPreviewAsync", code);
        Assert.Contains("DownloadItemAsync", code);
    }

    [Fact]
    public void ShellRequiresMatchingProfileAndReleasesLocationsWithFilesPage()
    {
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var page = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");

        Assert.Contains("repository as IFileLocationsRepository", shell);
        Assert.Contains("locationsRepository?.ProfileId != profile.Id", shell);
        Assert.Contains("_filesProfileId != profile.Id", shell);
        Assert.Contains("await CloseFilesPageAsync();", shell);
        Assert.Contains("_locationsViewModel.Deactivate();", page);
        Assert.Contains("_locationsViewModel.Dispose();", page);
        Assert.Contains("LocationsPane.Dispose();", page);
    }

    [Fact]
    public void ShellUnloadAlwaysReleasesEveryModuleAfterExpectedFilesLifecycleRaces()
    {
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var unload = Slice(shell, "private async void ShellPage_Unloaded", "private void ProfileMenu_Opening");

        Assert.Contains("try", unload);
        Assert.Contains("finally", unload);
        Assert.Contains("catch (OperationCanceledException)", unload);
        Assert.Contains("catch (ObjectDisposedException)", unload);
        Assert.DoesNotContain("catch (Exception", unload);
        foreach (var cleanup in new[]
        {
            "_photos?.Dispose();", "_chat?.Dispose();", "_downloads?.Dispose();",
            "_containers?.Dispose();", "_virtualMachines?.Dispose();", "_activity?.Dispose();",
            "_transferPicker?.Dispose();", "_transfers.Dispose();",
            "_settings.Changed -= Settings_Changed;"
        })
        {
            Assert.True(unload.IndexOf(cleanup, StringComparison.Ordinal) >
                unload.IndexOf("finally", StringComparison.Ordinal));
        }
    }

    [Fact]
    public void ClosingFilesAlwaysDisposesThePageAfterAttemptingItsAsyncClose()
    {
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var close = Slice(shell, "private async Task CloseFilesPageAsync()", "private void Settings_Changed");
        var frameSwitch = close.IndexOf("ContentFrame.Content = _workspace;", StringComparison.Ordinal);
        var closeCall = close.IndexOf("await files.CloseAsync();", StringComparison.Ordinal);
        var finallyBlock = close.IndexOf("finally", StringComparison.Ordinal);
        var disposeCall = close.IndexOf("files.Dispose();", StringComparison.Ordinal);

        Assert.True(frameSwitch >= 0);
        Assert.True(closeCall > frameSwitch);
        Assert.True(finallyBlock > closeCall);
        Assert.True(disposeCall > finallyBlock);
    }

    [Fact]
    public void LocationUiHasMatchingEnglishAndChineseResourceKeys()
    {
        var english = ResourceKeys("windows/src/LanStash.App/Strings/en-US/Resources.resw");
        var chinese = ResourceKeys("windows/src/LanStash.App/Strings/zh-CN/Resources.resw");
        var locationKeys = english.Where(key => key.StartsWith("FileLocations", StringComparison.Ordinal)).ToHashSet();

        Assert.NotEmpty(locationKeys);
        Assert.True(locationKeys.SetEquals(chinese.Where(key => key.StartsWith("FileLocations", StringComparison.Ordinal))));
        Assert.Contains("FileLocationsOpenError.Message", locationKeys);
        Assert.Contains("FileLocationsRecyclePartial.Message", locationKeys);
        Assert.Contains("FileLocationsRemoteTruncated.Message", locationKeys);
    }

    [Fact]
    public void LocationUiDoesNotExposeWriteManagementOrRecycleMutationActions()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FileLocationsView.xaml");
        var code = Read("windows/src/LanStash.App/Views/FileLocationsView.xaml.cs");
        var combined = xaml + code;

        foreach (var forbidden in new[]
        {
            "AddFavorite", "RemoveFavorite", "CreateRemoteMount", "UpdateRemoteMount",
            "RemoveRemoteMount", "RestoreRecycle", "EmptyRecycle", "DeleteRecycle", "#recycle"
        })
        {
            Assert.DoesNotContain(forbidden, combined, StringComparison.OrdinalIgnoreCase);
        }
    }

    private static HashSet<string> ResourceKeys(string relativePath) =>
        XDocument.Parse(Read(relativePath)).Root!.Elements("data")
            .Select(item => (string)item.Attribute("name")!)
            .ToHashSet(StringComparer.Ordinal);

    private static int Count(string source, string value) =>
        source.Split(value, StringSplitOptions.None).Length - 1;

    private static string Slice(string source, string start, string end)
    {
        var from = source.IndexOf(start, StringComparison.Ordinal);
        var to = source.IndexOf(end, from, StringComparison.Ordinal);
        return source[from..to];
    }

    private static string Read(string relativePath)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (File.Exists(candidate)) return File.ReadAllText(candidate);
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException(relativePath);
    }
}
