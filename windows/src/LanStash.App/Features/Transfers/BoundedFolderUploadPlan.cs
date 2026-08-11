namespace LanStash.App.Features.Transfers;

internal enum FolderUploadPlanStatus
{
    Valid,
    SourceUnavailable,
    TooManyFiles,
    TooManyDirectories,
    TooDeep,
    ReparsePoint,
    InvalidName,
    DuplicateTarget,
}

internal sealed record FolderUploadDirectory(string RelativePath, string Name);

internal sealed record FolderUploadFile(
    string SourcePath,
    string RelativePath,
    string Name,
    long Length,
    DateTime LastWriteTimeUtc);

internal sealed record FolderUploadPlan(
    string RootPath,
    string RootName,
    IReadOnlyList<FolderUploadDirectory> Directories,
    IReadOnlyList<FolderUploadFile> Files);

internal sealed record FolderUploadPlanResult(
    FolderUploadPlanStatus Status,
    FolderUploadPlan? Plan = null);

internal static class BoundedFolderUploadPlan
{
    internal const int MaximumFileCount = 20;
    internal const int MaximumDirectoryCount = 20;
    internal const int MaximumDepth = 8;

    internal static FolderUploadPlanResult Create(string rootPath)
    {
        if (string.IsNullOrWhiteSpace(rootPath))
        {
            return Failed(FolderUploadPlanStatus.SourceUnavailable);
        }

        try
        {
            var root = new DirectoryInfo(rootPath);
            if (!root.Exists)
            {
                return Failed(FolderUploadPlanStatus.SourceUnavailable);
            }

            if (IsReparsePoint(root))
            {
                return Failed(FolderUploadPlanStatus.ReparsePoint);
            }

            if (!IsValidName(root.Name))
            {
                return Failed(FolderUploadPlanStatus.InvalidName);
            }

            var directories = new List<FolderUploadDirectory> { new(string.Empty, root.Name) };
            var files = new List<FolderUploadFile>();
            var targets = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { string.Empty };
            var pending = new Stack<(DirectoryInfo Directory, string RelativePath, int Depth)>();
            pending.Push((root, string.Empty, 1));
            var directoryCount = 1;

            while (pending.Count > 0)
            {
                var current = pending.Pop();
                var entries = current.Directory.EnumerateFileSystemInfos().ToArray();

                foreach (var entry in entries)
                {
                    if (IsReparsePoint(entry))
                    {
                        return Failed(FolderUploadPlanStatus.ReparsePoint);
                    }

                    if (!IsValidName(entry.Name))
                    {
                        return Failed(FolderUploadPlanStatus.InvalidName);
                    }

                    var relativePath = string.IsNullOrEmpty(current.RelativePath)
                        ? entry.Name
                        : $"{current.RelativePath}/{entry.Name}";
                    if (!targets.Add(relativePath))
                    {
                        return Failed(FolderUploadPlanStatus.DuplicateTarget);
                    }

                    if (entry is DirectoryInfo directory)
                    {
                        var depth = current.Depth + 1;
                        if (depth > MaximumDepth)
                        {
                            return Failed(FolderUploadPlanStatus.TooDeep);
                        }

                        directoryCount++;
                        if (directoryCount > MaximumDirectoryCount)
                        {
                            return Failed(FolderUploadPlanStatus.TooManyDirectories);
                        }

                        directories.Add(new FolderUploadDirectory(relativePath, entry.Name));
                        pending.Push((directory, relativePath, depth));
                    }
                    else if (entry is FileInfo file)
                    {
                        if (files.Count == MaximumFileCount)
                        {
                            return Failed(FolderUploadPlanStatus.TooManyFiles);
                        }

                        files.Add(new FolderUploadFile(
                            file.FullName,
                            relativePath,
                            file.Name,
                            file.Length,
                            file.LastWriteTimeUtc));
                    }
                    else
                    {
                        return Failed(FolderUploadPlanStatus.SourceUnavailable);
                    }
                }
            }

            directories.Sort(static (left, right) => CompareRelativePaths(left.RelativePath, right.RelativePath));
            files.Sort(static (left, right) => CompareRelativePaths(left.RelativePath, right.RelativePath));
            return new FolderUploadPlanResult(
                FolderUploadPlanStatus.Valid,
                new FolderUploadPlan(root.FullName, root.Name, directories, files));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException or ArgumentException or NotSupportedException)
        {
            return Failed(FolderUploadPlanStatus.SourceUnavailable);
        }
    }

    internal static bool IsCurrent(FolderUploadPlan plan)
    {
        try
        {
            var current = Create(plan.RootPath);
            return current.Status == FolderUploadPlanStatus.Valid &&
                current.Plan is not null &&
                StringComparer.Ordinal.Equals(plan.RootPath, current.Plan.RootPath) &&
                StringComparer.Ordinal.Equals(plan.RootName, current.Plan.RootName) &&
                plan.Directories.SequenceEqual(current.Plan.Directories) &&
                plan.Files.SequenceEqual(current.Plan.Files);
        }
        catch (Exception)
        {
            return false;
        }
    }

    internal static bool IsCurrent(FolderUploadFile file)
    {
        try
        {
            var current = new FileInfo(file.SourcePath);
            return current.Exists && !IsReparsePoint(current) &&
                StringComparer.Ordinal.Equals(current.Name, file.Name) &&
                current.Length == file.Length &&
                current.LastWriteTimeUtc == file.LastWriteTimeUtc;
        }
        catch (Exception)
        {
            return false;
        }
    }

    internal static bool HasTargetCollision(IEnumerable<string> relativePaths)
    {
        var targets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        return relativePaths.Any(path => !targets.Add(path));
    }

    private static bool IsReparsePoint(FileSystemInfo entry) =>
        (entry.Attributes & FileAttributes.ReparsePoint) != 0;

    internal static bool IsValidName(string name) =>
        !string.IsNullOrWhiteSpace(name) &&
        name == name.Trim() &&
        name is not "." and not ".." &&
        name.IndexOfAny(['/', '\\', '\r', '\n', '\0']) < 0;

    private static int CompareRelativePaths(string left, string right)
    {
        var depthComparison = SegmentCount(left).CompareTo(SegmentCount(right));
        if (depthComparison != 0)
        {
            return depthComparison;
        }

        var insensitiveComparison = StringComparer.OrdinalIgnoreCase.Compare(left, right);
        return insensitiveComparison != 0
            ? insensitiveComparison
            : StringComparer.Ordinal.Compare(left, right);
    }

    private static int SegmentCount(string path) =>
        string.IsNullOrEmpty(path) ? 0 : path.Count(character => character == '/') + 1;

    private static FolderUploadPlanResult Failed(FolderUploadPlanStatus status) => new(status);
}

internal static class BoundedFolderUploadBatch
{
    internal static async Task<FileUploadBatchSummary> RunAsync(
        FolderUploadPlan plan,
        Func<FolderUploadDirectory, CancellationToken, Task<FileUploadBatchAttempt>> createDirectory,
        Func<FolderUploadFile, CancellationToken, Task<FileUploadBatchAttempt>> uploadFile,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ArgumentNullException.ThrowIfNull(createDirectory);
        ArgumentNullException.ThrowIfNull(uploadFile);

        var confirmed = 0;
        var needsReview = 0;
        var failed = 0;
        var cancelled = 0;
        var started = 0;
        var stop = false;

        foreach (var directory in plan.Directories)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            started++;
            var attempt = await createDirectory(directory, cancellationToken);
            Count(attempt, ref confirmed, ref needsReview, ref failed, ref cancelled);
            if (attempt.Status != FileUploadBatchAttemptStatus.Confirmed || attempt.StopBatch)
            {
                stop = true;
                break;
            }
        }

        if (!stop)
        {
            foreach (var file in plan.Files)
            {
                if (cancellationToken.IsCancellationRequested)
                {
                    break;
                }
                started++;
                var attempt = await uploadFile(file, cancellationToken);
                Count(attempt, ref confirmed, ref needsReview, ref failed, ref cancelled);
                if (attempt.StopBatch || attempt.Status == FileUploadBatchAttemptStatus.Cancelled)
                {
                    break;
                }
            }
        }

        var total = plan.Directories.Count + plan.Files.Count;
        return new FileUploadBatchSummary(
            total,
            confirmed,
            needsReview,
            failed,
            cancelled,
            total - started);
    }

    private static void Count(
        FileUploadBatchAttempt attempt,
        ref int confirmed,
        ref int needsReview,
        ref int failed,
        ref int cancelled)
    {
        switch (attempt.Status)
        {
            case FileUploadBatchAttemptStatus.Confirmed:
                confirmed++;
                break;
            case FileUploadBatchAttemptStatus.NeedsReview:
                needsReview++;
                break;
            case FileUploadBatchAttemptStatus.Failed:
                failed++;
                break;
            case FileUploadBatchAttemptStatus.Cancelled:
                cancelled++;
                break;
        }
    }
}
