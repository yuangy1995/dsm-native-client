using LanStash.App.Features.Transfers;

namespace LanStash.Tests;

public sealed class BoundedFolderUploadPlanTests
{
    [Fact]
    public void PlansEmptyAndPopulatedFoldersWithStableParentFirstOrder()
    {
        using var root = TempDirectory.Create("upload-root");
        Directory.CreateDirectory(Path.Combine(root.Path, "z", "child"));
        Directory.CreateDirectory(Path.Combine(root.Path, "a"));
        File.WriteAllText(Path.Combine(root.Path, "z", "child", "deep.txt"), "deep");
        File.WriteAllText(Path.Combine(root.Path, "a", "first.txt"), "first");

        var result = BoundedFolderUploadPlan.Create(root.Path);

        Assert.Equal(FolderUploadPlanStatus.Valid, result.Status);
        Assert.Equal("upload-root", result.Plan!.RootName);
        Assert.Equal(["", "a", "z", "z/child"], result.Plan.Directories.Select(item => item.RelativePath));
        Assert.Equal(["a/first.txt", "z/child/deep.txt"], result.Plan.Files.Select(item => item.RelativePath));
        Assert.All(result.Plan.Directories, item => Assert.DoesNotContain('\\', item.RelativePath));
        Assert.All(result.Plan.Files, item => Assert.DoesNotContain('\\', item.RelativePath));
        Assert.Equal(["upload-root", "a", "z", "child"], result.Plan.Directories.Select(item => item.Name));

        using var empty = TempDirectory.Create("empty-root");
        var emptyResult = BoundedFolderUploadPlan.Create(empty.Path);
        Assert.Equal(FolderUploadPlanStatus.Valid, emptyResult.Status);
        Assert.Equal("", Assert.Single(emptyResult.Plan!.Directories).RelativePath);
        Assert.Empty(emptyResult.Plan.Files);
    }

    [Fact]
    public void AcceptsAllLimits()
    {
        using var root = TempDirectory.Create("limits");
        for (var index = 0; index < 19; index++)
        {
            Directory.CreateDirectory(Path.Combine(root.Path, $"d{index:D2}"));
        }
        for (var index = 0; index < 20; index++)
        {
            File.WriteAllText(Path.Combine(root.Path, $"f{index:D2}.txt"), "x");
        }

        var result = BoundedFolderUploadPlan.Create(root.Path);

        Assert.Equal(FolderUploadPlanStatus.Valid, result.Status);
        Assert.Equal(20, result.Plan!.Directories.Count);
        Assert.Equal(20, result.Plan.Files.Count);
    }

    [Fact]
    public void RejectsMissingAndNonDirectorySources()
    {
        using var root = TempDirectory.Create("source");
        var file = Path.Combine(root.Path, "file.txt");
        File.WriteAllText(file, "x");

        Assert.Equal(FolderUploadPlanStatus.SourceUnavailable, BoundedFolderUploadPlan.Create(" ").Status);
        Assert.Equal(FolderUploadPlanStatus.SourceUnavailable, BoundedFolderUploadPlan.Create(Path.Combine(root.Path, "missing")).Status);
        Assert.Equal(FolderUploadPlanStatus.SourceUnavailable, BoundedFolderUploadPlan.Create(file).Status);
    }

    [Fact]
    public void RejectsTooManyFilesAndDirectories()
    {
        using var files = TempDirectory.Create("files");
        for (var index = 0; index < 21; index++) File.WriteAllText(Path.Combine(files.Path, $"f{index}.txt"), "x");
        Assert.Equal(FolderUploadPlanStatus.TooManyFiles, BoundedFolderUploadPlan.Create(files.Path).Status);

        using var directories = TempDirectory.Create("directories");
        for (var index = 0; index < 20; index++) Directory.CreateDirectory(Path.Combine(directories.Path, $"d{index}"));
        Assert.Equal(FolderUploadPlanStatus.TooManyDirectories, BoundedFolderUploadPlan.Create(directories.Path).Status);
    }

    [Fact]
    public void RejectsDepthBeyondEight()
    {
        using var root = TempDirectory.Create("depth");
        var current = root.Path;
        for (var depth = 2; depth <= 9; depth++) current = Directory.CreateDirectory(Path.Combine(current, $"d{depth}")).FullName;

        Assert.Equal(FolderUploadPlanStatus.TooDeep, BoundedFolderUploadPlan.Create(root.Path).Status);
    }

    [Fact]
    public void RejectsRootAndDescendantReparsePoints()
    {
        using var target = TempDirectory.Create("target");
        using var rootLinkParent = TempDirectory.Create("root-link-parent");
        var rootLink = Path.Combine(rootLinkParent.Path, "root-link");
        Directory.CreateSymbolicLink(rootLink, target.Path);
        Assert.Equal(FolderUploadPlanStatus.ReparsePoint, BoundedFolderUploadPlan.Create(rootLink).Status);

        using var descendant = TempDirectory.Create("descendant");
        Directory.CreateSymbolicLink(Path.Combine(descendant.Path, "link"), target.Path);
        Assert.Equal(FolderUploadPlanStatus.ReparsePoint, BoundedFolderUploadPlan.Create(descendant.Path).Status);
    }

    [Theory]
    [InlineData(" bad")]
    [InlineData("bad ")]
    [InlineData("bad\\name")]
    [InlineData("bad\rname")]
    [InlineData("bad\nname")]
    public void RejectsInvalidNames(string name)
    {
        Assert.False(BoundedFolderUploadPlan.IsValidName(name));
    }

    [Fact]
    public void RejectsCaseInsensitiveTargetCollisions()
    {
        Assert.True(BoundedFolderUploadPlan.HasTargetCollision(["Same.txt", "same.txt"]));
    }

    [Fact]
    public void CapturesSourceMetadata()
    {
        using var root = TempDirectory.Create("metadata");
        var path = Path.Combine(root.Path, "item.bin");
        File.WriteAllBytes(path, [1, 2, 3, 4]);
        var timestamp = new DateTime(2025, 4, 3, 2, 1, 0, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(path, timestamp);

        var file = Assert.Single(BoundedFolderUploadPlan.Create(root.Path).Plan!.Files);

        Assert.Equal(path, file.SourcePath);
        Assert.Equal("item.bin", file.RelativePath);
        Assert.Equal(4, file.Length);
        Assert.Equal(timestamp, file.LastWriteTimeUtc);
    }

    [Fact]
    public void IsCurrentDetectsFileAndDirectoryChanges()
    {
        using var root = TempDirectory.Create("current");
        var path = Path.Combine(root.Path, "item.txt");
        File.WriteAllText(path, "one");
        var plan = BoundedFolderUploadPlan.Create(root.Path).Plan!;

        Assert.True(BoundedFolderUploadPlan.IsCurrent(plan));
        File.AppendAllText(path, "two");
        Assert.False(BoundedFolderUploadPlan.IsCurrent(plan));

        plan = BoundedFolderUploadPlan.Create(root.Path).Plan!;
        Directory.CreateDirectory(Path.Combine(root.Path, "added"));
        Assert.False(BoundedFolderUploadPlan.IsCurrent(plan));
    }

    [Fact]
    public async Task BatchCreatesEveryDirectoryBeforeUploadingFiles()
    {
        var calls = new List<string>();
        var plan = Plan(
            [new("", "root"), new("child", "child")],
            [PlannedFile("a.txt"), PlannedFile("child/b.txt")]);

        var summary = await BoundedFolderUploadBatch.RunAsync(
            plan,
            (directory, _) =>
            {
                calls.Add($"directory:{directory.RelativePath}");
                return Task.FromResult(Confirmed());
            },
            (file, _) =>
            {
                calls.Add($"file:{file.RelativePath}");
                return Task.FromResult(Confirmed());
            },
            CancellationToken.None);

        Assert.Equal(
            ["directory:", "directory:child", "file:a.txt", "file:child/b.txt"],
            calls);
        Assert.Equal(4, summary.ConfirmedCount);
        Assert.Equal(0, summary.NotStartedCount);
    }

    [Fact]
    public async Task BatchStopsBeforeFilesWhenDirectoryIsNotConfirmed()
    {
        var fileCalls = 0;
        var plan = Plan(
            [new("", "root"), new("child", "child")],
            [PlannedFile("a.txt")]);

        var summary = await BoundedFolderUploadBatch.RunAsync(
            plan,
            (_, _) => Task.FromResult(new FileUploadBatchAttempt(
                FileUploadBatchAttemptStatus.NeedsReview,
                StopBatch: true)),
            (_, _) =>
            {
                fileCalls++;
                return Task.FromResult(Confirmed());
            },
            CancellationToken.None);

        Assert.Equal(0, fileCalls);
        Assert.Equal(1, summary.NeedsReviewCount);
        Assert.Equal(2, summary.NotStartedCount);
    }

    [Fact]
    public async Task BatchContinuesAfterOrdinaryFileFailureButStopsAfterCancellation()
    {
        var calls = 0;
        var plan = Plan(
            [new("", "root")],
            [PlannedFile("a.txt"), PlannedFile("b.txt"), PlannedFile("c.txt")]);

        var summary = await BoundedFolderUploadBatch.RunAsync(
            plan,
            (_, _) => Task.FromResult(Confirmed()),
            (_, _) => Task.FromResult(++calls switch
            {
                1 => new FileUploadBatchAttempt(FileUploadBatchAttemptStatus.Failed),
                _ => new FileUploadBatchAttempt(
                    FileUploadBatchAttemptStatus.Cancelled,
                    StopBatch: true),
            }),
            CancellationToken.None);

        Assert.Equal(2, calls);
        Assert.Equal(1, summary.ConfirmedCount);
        Assert.Equal(1, summary.FailedCount);
        Assert.Equal(1, summary.CancelledCount);
        Assert.Equal(1, summary.NotStartedCount);
    }

    [Fact]
    public async Task BatchStartsNothingWhenAlreadyCancelled()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var plan = Plan([new("", "root")], [PlannedFile("a.txt")]);

        var summary = await BoundedFolderUploadBatch.RunAsync(
            plan,
            (_, _) => throw new InvalidOperationException(),
            (_, _) => throw new InvalidOperationException(),
            cancellation.Token);

        Assert.Equal(0, summary.ConfirmedCount);
        Assert.Equal(2, summary.NotStartedCount);
    }

    private static FolderUploadPlan Plan(
        IReadOnlyList<FolderUploadDirectory> directories,
        IReadOnlyList<FolderUploadFile> files) =>
        new("root", "root", directories, files);

    private static FolderUploadFile PlannedFile(string relativePath) =>
        new(relativePath, relativePath, Path.GetFileName(relativePath), 1, DateTime.UnixEpoch);

    private static FileUploadBatchAttempt Confirmed() =>
        new(FileUploadBatchAttemptStatus.Confirmed);

    private sealed class TempDirectory : IDisposable
    {
        private TempDirectory(string path) => Path = path;
        internal string Path { get; }

        internal static TempDirectory Create(string name)
        {
            var parent = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "lanstash-folder-plan-tests", Guid.NewGuid().ToString("N"));
            var path = Directory.CreateDirectory(System.IO.Path.Combine(parent, name)).FullName;
            return new TempDirectory(path);
        }

        public void Dispose() => Directory.Delete(System.IO.Path.GetDirectoryName(Path)!, recursive: true);
    }
}
