using LanStash.Domain;

namespace LanStash.Tests.Files.CopyMove;

public sealed class CrossNasCopyMoveContractTests
{
    [Fact]
    public void CrossNasCopyMoveRequest_AllPropertiesAssigned()
    {
        var sourceProfileId = Guid.NewGuid();
        var targetProfileId = Guid.NewGuid();
        var request = new CrossNasCopyMoveRequest(
            sourceProfileId,
            targetProfileId,
            "/home/docs/report.pdf",
            "report.pdf",
            IsDirectory: false,
            FileSize: 1024 * 1024,
            "/backup/archive",
            Overwrite: false);

        Assert.Equal(sourceProfileId, request.SourceProfileId);
        Assert.Equal(targetProfileId, request.TargetProfileId);
        Assert.Equal("/home/docs/report.pdf", request.SourcePath);
        Assert.Equal("report.pdf", request.SourceName);
        Assert.False(request.IsDirectory);
        Assert.Equal(1024 * 1024, request.FileSize);
        Assert.Equal("/backup/archive", request.DestinationFolderPath);
        Assert.False(request.Overwrite);
        Assert.Equal(CrossNasCopyMoveOperation.Copy, request.Operation);
    }

    [Fact]
    public void CrossNasCopyMoveRequest_DifferentProfilesRequired()
    {
        var profileId = Guid.NewGuid();
        var sameProfile = new CrossNasCopyMoveRequest(
            profileId, profileId, "/a", "a.txt", false, 100, "/b", false);

        Assert.Equal(sameProfile.SourceProfileId, sameProfile.TargetProfileId);
    }

    [Fact]
    public void CrossNasCopyMoveRequest_FolderTransfer()
    {
        var sourceId = Guid.NewGuid();
        var targetId = Guid.NewGuid();
        var request = new CrossNasCopyMoveRequest(
            sourceId, targetId, "/data/photos", "photos", IsDirectory: true,
            FileSize: 0, "/backup", Overwrite: true);

        Assert.True(request.IsDirectory);
        Assert.Equal(0, request.FileSize);
        Assert.True(request.Overwrite);
    }

    [Fact]
    public void CrossNasCopyMoveOutcome_WithConfirmedItem()
    {
        var result = new MutationResult(
            1, MutationResultStatus.ConfirmedSuccess, "crossNasCopy",
            submitted: true, requiresRefresh: false,
            new MutationResultCounts(1, 0, 0));

        var confirmedItem = new FileItem(
            "/backup/archive/report.pdf",
            "report.pdf",
            IsDirectory: false,
            Size: 1024 * 1024,
            ModifiedAt: new DateTimeOffset(2026, 1, 15, 0, 0, 0, TimeSpan.Zero),
            Owner: "admin",
            CanWrite: true,
            CanDelete: true);

        var outcome = new CrossNasCopyMoveOutcome(
            result, "/home/docs/report.pdf", "/backup/archive/report.pdf", confirmedItem);

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Same(confirmedItem, outcome.ConfirmedItem);
        Assert.Equal("/home/docs/report.pdf", outcome.SourcePath);
        Assert.Equal("/backup/archive/report.pdf", outcome.DestinationPath);
    }

    [Fact]
    public void CrossNasCopyMoveOutcome_FailureScenario()
    {
        var result = new MutationResult(
            1, MutationResultStatus.ConfirmedFailure, "crossNasCopy",
            submitted: true, requiresRefresh: false,
            new MutationResultCounts(0, 1, 0),
            MutationErrorCategory.Network,
            diagnosticTag: "file.cross-nas.download-failed");

        var outcome = new CrossNasCopyMoveOutcome(
            result, "/source/file.txt", "/dest");

        Assert.Equal(MutationResultStatus.ConfirmedFailure, outcome.Result.Status);
        Assert.Equal(MutationErrorCategory.Network, outcome.Result.ErrorCategory);
        Assert.Null(outcome.ConfirmedItem);
    }

    [Fact]
    public void CrossNasCopyMoveOutcome_Unverified()
    {
        var result = new MutationResult(
            1, MutationResultStatus.SubmittedButUnverified, "crossNasCopy",
            submitted: true, requiresRefresh: true,
            new MutationResultCounts(0, 0, 1),
            MutationErrorCategory.Network,
            diagnosticTag: "file.cross-nas.upload-unverified");

        var outcome = new CrossNasCopyMoveOutcome(
            result, "/source", "/dest");

        Assert.True(outcome.Result.RequiresRefresh);
        Assert.Equal(1, outcome.Result.Counts.Unknown);
    }

    [Fact]
    public void CrossNasCopyMoveAvailability_DefaultValues()
    {
        var available = new CrossNasCopyMoveAvailability(CanCrossCopy: true, CanCrossMove: true);
        Assert.True(available.CanCrossCopy);
        Assert.True(available.CanCrossMove);

        var unavailable = new CrossNasCopyMoveAvailability(CanCrossCopy: false, CanCrossMove: false);
        Assert.False(unavailable.CanCrossCopy);
        Assert.False(unavailable.CanCrossMove);

        var copyOnly = new CrossNasCopyMoveAvailability(CanCrossCopy: true, CanCrossMove: false);
        Assert.True(copyOnly.CanCrossCopy);
        Assert.False(copyOnly.CanCrossMove);
    }

    [Fact]
    public void ProductionCrossNasEntryRequiresIndependentSecondSession()
    {
        var source = Read("windows/src/LanStash.Infrastructure/Features/Files/CopyMove/DsmRepository.FileCrossNasCopyMove.cs");
        var view = Read("windows/src/LanStash.App/Views/FilesPage.xaml.cs");

        Assert.Contains("CanCrossCopy: false", source);
        Assert.Contains("CanCrossMove: false", source);
        Assert.Contains("file.cross-nas.no-second-session", source);
        Assert.Contains("CrossNasCopyButton.Visibility", view);
        Assert.Contains("CrossNasMoveButton.Visibility = Visibility.Collapsed", view);
    }

    [Fact]
    public void CrossNasCopyStopsAtUnknownAndVerifiesBoundedTreeWithoutReplay()
    {
        var source = Read("windows/src/LanStash.Infrastructure/Features/Files/CopyMove/DsmRepository.FileCrossNasCopyMove.cs");

        Assert.Contains("EnsureCrossNasRange", source);
        Assert.Contains("file.cross-nas.tree-readback-mismatch", source);
        Assert.Contains("file.cross-nas.no-second-session", source);
        Assert.Contains("MutationResultStatus.SubmittedButUnverified", source);
        Assert.Contains("succeeded: succeeded", source);
        Assert.DoesNotContain("childRequest with { DestinationFolderPath", source);
    }

    private static string Read(string relativePath)
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null &&
               !File.Exists(Path.Combine(directory.FullName, "AGENTS.md")))
        {
            directory = directory.Parent;
        }
        return File.ReadAllText(Path.Combine(
            directory?.FullName ?? throw new DirectoryNotFoundException(), relativePath));
    }

    [Fact]
    public void CrossNasCopyMoveRequest_ValueEquality()
    {
        var sourceId = Guid.NewGuid();
        var targetId = Guid.NewGuid();
        var r1 = new CrossNasCopyMoveRequest(
            sourceId, targetId, "/a/file.txt", "file.txt", false, 500, "/dest", false);
        var r2 = new CrossNasCopyMoveRequest(
            sourceId, targetId, "/a/file.txt", "file.txt", false, 500, "/dest", false);

        Assert.Equal(r1, r2);
        Assert.Equal(r1.GetHashCode(), r2.GetHashCode());
    }
}
