namespace LanStash.Tests;

public sealed class PhotosShellIntegrationTests
{
    [Fact]
    public void PhotoLoadFailureDoesNotTellTheUserToAddPhotos()
    {
        var source = ReadRepositoryFile("windows/src/LanStash.App/Views/Photos/SynologyPhotosPage.xaml.cs");
        var message = Slice(source, "EmptyMessage.Text =", "CountText.Text =");
        Assert.Contains("_model.ErrorKey ??", message);
        Assert.True(message.IndexOf("_model.ErrorKey", StringComparison.Ordinal) <
            message.IndexOf("PhotosEmptyDescription", StringComparison.Ordinal));
    }

    [Fact]
    public void ShellRoutesPhotosToOneCachedDedicatedPageAndDisposesIt()
    {
        var shell = ReadRepositoryFile("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var photosBranch = Slice(
            shell,
            "if (module == AppModule.Photos",
            "ContentFrame.Content = _workspace;");

        Assert.Contains("(_app.Repository as ISynologyPhotosProvider)?.SynologyPhotos", photosBranch);
        Assert.Contains("_photosProfileId != photoProfile.Id", photosBranch);
        Assert.Contains("!ReferenceEquals(_photosRepository, photoRepository)", photosBranch);
        Assert.DoesNotContain("IFilePreviewRepository", photosBranch);
        Assert.Contains("_photos = new SynologyPhotosPage(photoRepository,", photosBranch);
        Assert.Contains("_photosProfileId = photoProfile.Id;", photosBranch);
        Assert.Contains("_photosRepository = photoRepository;", photosBranch);
        Assert.Contains("ContentFrame.Content = _photos;", photosBranch);
        Assert.Contains("return;", photosBranch);
        Assert.DoesNotContain("ShowModuleAsync", photosBranch);
        Assert.Contains("_photos?.Dispose();", shell);
        Assert.Contains("_photos = null;", shell);
    }

    [Fact]
    public void PhotosRouteNeverFallsThroughWhenItsProfileDependenciesAreUnavailable()
    {
        var shell = ReadRepositoryFile("windows/src/LanStash.App/Views/ShellPage.xaml.cs");
        var photosBranch = Slice(
            shell,
            "if (module == AppModule.Photos)",
            "ContentFrame.Content = _workspace;");

        Assert.Contains("photoRepository is null", photosBranch);
        Assert.Contains("photoRepository.ProfileId != photoProfile.Id", photosBranch);
        Assert.Contains("SynologyPhotosPage.CreateUnavailableState()", photosBranch);
        Assert.Contains("_photosRepository = null;", photosBranch);
        Assert.True(photosBranch.Split("return;", StringSplitOptions.None).Length - 1 >= 2);
        Assert.DoesNotContain("ShowModuleAsync", photosBranch);
    }

    [Fact]
    public void SaveCopyReusesExistingForegroundTransferInsteadOfAddingAPhotoTransfer()
    {
        var source = ReadRepositoryFile("windows/src/LanStash.App/Views/PhotosPage.xaml.cs");
        var method = Slice(source, "private async Task SaveSelectedAsync()", "private bool CanSaveSelectedMedia()");

        Assert.Contains("new FileBrowserEntry(new FileItem(", method);
        Assert.Contains("_transfers.PickAndStartDownloadAsync(_profileId, fileEntry)", method);
        Assert.DoesNotContain("ReadFileRange", method);
        Assert.DoesNotContain("FileSavePicker", method);
        Assert.DoesNotContain("Upload", method);
    }

    private static string Slice(string source, string start, string end)
    {
        var startIndex = source.IndexOf(start, StringComparison.Ordinal);
        var endIndex = source.IndexOf(end, startIndex, StringComparison.Ordinal);
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
        throw new DirectoryNotFoundException(relativePath);
    }
}
