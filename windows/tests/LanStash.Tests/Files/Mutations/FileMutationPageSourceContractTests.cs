using System.Xml.Linq;

namespace LanStash.Tests.Files.Mutations;

public sealed class FileMutationPageSourceContractTests
{
    [Fact]
    public void PageUsesNativeAccessibleSingleItemActionsAndReadOnlyDoubleGate()
    {
        var xaml = Read("windows/src/LanStash.App/Views/FilesPage.xaml");
        var page = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");
        var mutations = Read("windows/src/LanStash.App/Views/FilesPage.Mutations.cs");
        var source = page + "\n" + mutations;
        _ = XDocument.Parse(xaml);

        Assert.Contains("public sealed partial class FilesPage", mutations);
        Assert.DoesNotContain("private async Task ShowMutationAsync", page);
        Assert.Contains("x:Name=\"CreateFolderButton\"", xaml);
        Assert.Contains("x:Name=\"RenameButton\"", xaml);
        Assert.Contains("MinHeight=\"48\"", xaml);
        Assert.Contains("Key=\"F2\"", xaml);
        Assert.Contains("new ContentDialog", source);
        Assert.Contains("MinHeight = 48", source);
        Assert.Contains("AutomationProperties.SetName", source);
        Assert.Contains("FileLocationSource.Remote or FileLocationSource.Recycle", source);
        Assert.Contains("ContainsRecycleSegment", source);
        Assert.Contains("if (repository is null || repository.ProfileId != _profileId", source);
        Assert.Contains("if (!model.CanSubmit || repository.ProfileId != _profileId || IsReadOnlyLocation())", source);
    }

    [Fact]
    public void DialogClosesAndRefreshesOnlyAfterStrictConfirmedSuccess()
    {
        var page = Read("windows/src/LanStash.App/Views/FilesPage.Mutations.cs");
        var model = Read(
            "windows/src/LanStash.App/Features/Files/Mutations/FileMutationViewModel.cs");

        Assert.Contains("args.Cancel = model.State != FileMutationPresentationState.ConfirmedSuccess", page);
        Assert.Contains("if (confirmed && !_disposed && repository.ProfileId == _profileId", page);
        Assert.Contains("string.Equals(_viewModel.CurrentPath, model.ParentPath, StringComparison.Ordinal)", page);
        Assert.Contains("IsExactConfirmedItem", model);
        Assert.Contains("_repository.ProfileId == _profileId", model);
        Assert.Contains("string.Equals(item.Path, proposedPath, StringComparison.Ordinal)", model);
        Assert.Contains("item.IsDirectory ==", model);
    }

    [Fact]
    public void ClosingCancelsBlocksAndPreventsLateUiWrite()
    {
        var page = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs") + "\n" +
            Read("windows/src/LanStash.App/Views/FilesPage.Mutations.cs");
        var model = Read(
            "windows/src/LanStash.App/Features/Files/Mutations/FileMutationViewModel.cs");
        var shell = Read("windows/src/LanStash.App/Views/ShellPage.xaml.cs");

        Assert.Contains("model.RequestCancellation()", page);
        Assert.Contains("model?.Abandon()", page);
        Assert.Contains("CloseMutationDialog();", page);
        Assert.Contains("Interlocked.Increment(ref _generation)", model);
        Assert.Contains("private bool IsCurrent(long generation) => !_disposed", model);
        Assert.Contains("mutationRepository?.ProfileId != profile.Id", shell);
        Assert.Contains("FileMutationReviewBlocker.Current", shell);
    }

    [Fact]
    public void SubmittingAndCancellingStatusIsAnnouncedByNarrator()
    {
        var page = Read("windows/src/LanStash.App/Views/FilesPage.Mutations.cs");

        Assert.Contains("var statusMessage = localization.Get(model.CancellationRequested", page);
        Assert.Contains("AutomationProperties.SetName(progress, statusMessage)", page);
        Assert.Contains("AutomationProperties.SetName(status, statusMessage)", page);
        Assert.Contains(
            "AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite)",
            page);
    }

    private static string Read(string relativePath) =>
        File.ReadAllText(Path.Combine(RepositoryRoot(), relativePath));

    private static string RepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null && !Directory.Exists(Path.Combine(directory.FullName, "windows")))
        {
            directory = directory.Parent;
        }
        return directory?.FullName ?? throw new DirectoryNotFoundException("repository root");
    }
}
