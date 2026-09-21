using System.Diagnostics;
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
    public void PreservesSelectionsAtFormerLimits()
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
    public void PlansEveryFileAndDirectoryBeyondFormerLimits()
    {
        using var files = TempDirectory.Create("files");
        for (var index = 0; index < 205; index++) File.WriteAllText(Path.Combine(files.Path, $"f{index:D3}.txt"), "x");
        var fileResult = BoundedFolderUploadPlan.Create(files.Path);
        Assert.Equal(FolderUploadPlanStatus.Valid, fileResult.Status);
        Assert.Equal(Enumerable.Range(0, 205).Select(index => $"f{index:D3}.txt"), fileResult.Plan!.Files.Select(file => file.RelativePath));

        using var directories = TempDirectory.Create("directories");
        for (var index = 0; index < 35; index++) Directory.CreateDirectory(Path.Combine(directories.Path, $"d{index:D2}"));
        var directoryResult = BoundedFolderUploadPlan.Create(directories.Path);
        Assert.Equal(FolderUploadPlanStatus.Valid, directoryResult.Status);
        Assert.Equal(new[] { "" }.Concat(Enumerable.Range(0, 35).Select(index => $"d{index:D2}")), directoryResult.Plan!.Directories.Select(directory => directory.RelativePath));
    }

    [Fact]
    public void PlansDeepTreesInParentFirstOrder()
    {
        using var root = TempDirectory.Create("depth");
        var current = root.Path;
        for (var depth = 2; depth <= 16; depth++) current = Directory.CreateDirectory(Path.Combine(current, $"d{depth}")).FullName;
        File.WriteAllText(Path.Combine(current, "deep.txt"), "deep");

        var result = BoundedFolderUploadPlan.Create(root.Path);
        Assert.Equal(FolderUploadPlanStatus.Valid, result.Status);
        Assert.Equal(16, result.Plan!.Directories.Count);
        Assert.Equal(Enumerable.Range(0, 16), result.Plan.Directories.Select(directory => directory.RelativePath.Split('/', StringSplitOptions.RemoveEmptyEntries).Length));
        Assert.Equal(current, Path.GetDirectoryName(Assert.Single(result.Plan.Files).SourcePath));
        Assert.True(BoundedFolderUploadPlan.IsCurrent(result.Plan));
    }

    [Fact]
    public void PlanningAndRecheckingPropagateCancellation()
    {
        using var root = TempDirectory.Create("cancel");
        var plan = BoundedFolderUploadPlan.Create(root.Path).Plan!;
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => BoundedFolderUploadPlan.Create(root.Path, cancellation.Token));
        Assert.Throws<OperationCanceledException>(() => BoundedFolderUploadPlan.IsCurrent(plan, cancellation.Token));
    }

    [Fact]
    public void PlannedCollectionsCannotBeChangedAfterConfirmation()
    {
        using var root = TempDirectory.Create("snapshot");
        File.WriteAllText(Path.Combine(root.Path, "item.txt"), "x");
        var plan = BoundedFolderUploadPlan.Create(root.Path).Plan!;
        Assert.Throws<NotSupportedException>(() => ((IList<FolderUploadDirectory>)plan.Directories).Clear());
        Assert.Throws<NotSupportedException>(() => ((IList<FolderUploadFile>)plan.Files).Clear());
        Assert.True(BoundedFolderUploadPlan.IsCurrent(plan));
    }

    [Fact]
    public void RejectsParentReplacedByJunctionAfterPlanningEvenWithIdenticalFileMetadata()
    {
        using var root = TempDirectory.Create("replacement");
        using var outside = TempDirectory.Create("outside");
        var child = Directory.CreateDirectory(Path.Combine(root.Path, "child")).FullName;
        var path = Path.Combine(child, "item.txt");
        var outsidePath = Path.Combine(outside.Path, "item.txt");
        File.WriteAllText(path, "inside!");
        File.WriteAllText(outsidePath, "outside");
        File.SetLastWriteTimeUtc(outsidePath, File.GetLastWriteTimeUtc(path));
        var plan = BoundedFolderUploadPlan.Create(root.Path).Plan!;
        var file = Assert.Single(plan.Files);
        Assert.True(BoundedFolderUploadPlan.IsCurrent(file, plan.RootPath));
        Directory.Move(child, Path.Combine(root.Path, "saved"));
        using (CreateDirectoryJunction(child, outside.Path))
        {
            Assert.Equal(file.Length, new FileInfo(path).Length);
            Assert.Equal(file.LastWriteTimeUtc, File.GetLastWriteTimeUtc(path));
            Assert.False(BoundedFolderUploadPlan.IsCurrent(file, plan.RootPath));
            Assert.False(BoundedFolderUploadPlan.IsCurrent(plan));
        }
        Assert.Equal("outside", File.ReadAllText(outsidePath));
    }

    [Fact]
    public async Task BatchExecutesTheEntireLargePlanWithoutTruncation()
    {
        var directories = Enumerable.Range(0, 35).Select(index => new FolderUploadDirectory($"d{index}", $"d{index}")).ToArray();
        var files = Enumerable.Range(0, 205).Select(index => PlannedFile($"d0/f{index}.txt")).ToArray();
        var directoryCalls = new List<FolderUploadDirectory>();
        var fileCalls = new List<FolderUploadFile>();
        var summary = await BoundedFolderUploadBatch.RunAsync(Plan(directories, files),
            (directory, _) => { directoryCalls.Add(directory); return Task.FromResult(Confirmed()); },
            (file, _) => { Assert.Equal(35, directoryCalls.Count); fileCalls.Add(file); return Task.FromResult(Confirmed()); },
            CancellationToken.None);
        Assert.Equal(directories, directoryCalls);
        Assert.Equal(files, fileCalls);
        Assert.Equal(240, summary.ConfirmedCount);
        Assert.Equal(0, summary.NotStartedCount);
    }

    [Fact]
    public void RejectsRootAndDescendantReparsePoints()
    {
        using var target = TempDirectory.Create("target");
        var targetFile = Path.Combine(target.Path, "outside.txt");
        File.WriteAllText(targetFile, "outside upload root");
        using (var rootLinkParent = TempDirectory.Create("root link parent"))
        {
            var rootLink = Path.Combine(rootLinkParent.Path, "root link");
            using var junction = CreateDirectoryJunction(rootLink, target.Path);
            var result = BoundedFolderUploadPlan.Create(rootLink);
            Assert.Equal(FolderUploadPlanStatus.ReparsePoint, result.Status);
            Assert.Null(result.Plan);
        }

        using (var descendant = TempDirectory.Create("descendant"))
        {
            using var junction = CreateDirectoryJunction(Path.Combine(descendant.Path, "link"), target.Path);
            var result = BoundedFolderUploadPlan.Create(descendant.Path);
            Assert.Equal(FolderUploadPlanStatus.ReparsePoint, result.Status);
            Assert.Null(result.Plan);
        }

        Assert.Equal("outside upload root", File.ReadAllText(targetFile));
    }

    private static IDisposable CreateDirectoryJunction(string linkPath, string targetPath)
    {
        // 生产代码拒绝所有重解析点。目录联接提供真实重解析点，不依赖符号链接特权或开发者模式。
        // 路径通过环境变量传入，禁用自动运行与延迟展开，避免空格及命令字符改变命令含义。
        var startInfo = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"),
            Arguments = "/d /v:off /c mklink /J \"%LANSTASH_TEST_LINK%\" \"%LANSTASH_TEST_TARGET%\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        startInfo.Environment["LANSTASH_TEST_LINK"] = linkPath;
        startInfo.Environment["LANSTASH_TEST_TARGET"] = targetPath;
        using var process = Process.Start(startInfo)!;
        Assert.True(process.WaitForExit(10_000), "创建测试目录联接超时。");
        Assert.Equal(0, process.ExitCode);
        var link = new DirectoryInfo(linkPath);
        Assert.True(link.Attributes.HasFlag(FileAttributes.ReparsePoint));
        Assert.Equal(Path.GetFullPath(targetPath), link.ResolveLinkTarget(returnFinalTarget: true)!.FullName);
        return new DirectoryJunction(linkPath);
    }

    private sealed class DirectoryJunction(string path) : IDisposable
    {
        // 只移除联接本身，不递归处理联接目标，也不调用卷挂载点清理。
        public void Dispose() => Directory.Delete(path, recursive: false);
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
