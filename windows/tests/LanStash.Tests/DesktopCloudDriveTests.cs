using LanStash.Domain;
using LanStash.App.CloudDrive;
using System.Runtime.InteropServices;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveTests
{
    private const long GiB = 1024L * 1024 * 1024;

    [Fact]
    public void ParentAndChildMappingsOnTheSameNasOverlap()
    {
        var profileId = Guid.NewGuid();
        var parent = Mapping(profileId, DesktopDriveScope.Folder("/share/projects"));
        var child = Mapping(profileId, DesktopDriveScope.Folder("//share/projects/design/"));

        Assert.True(parent.Overlaps(child));
    }

    [Fact]
    public void DifferentNasOrSiblingMappingsDoNotOverlap()
    {
        var profileId = Guid.NewGuid();
        var first = Mapping(profileId, DesktopDriveScope.Folder("/share/project"));
        var differentProfile = Mapping(
            Guid.NewGuid(),
            DesktopDriveScope.Folder("/share/project"));
        var sibling = Mapping(
            profileId,
            DesktopDriveScope.Folder("/share/project-archive"));

        Assert.False(first.Overlaps(differentProfile));
        Assert.False(first.Overlaps(sibling));
    }

    [Fact]
    public void AllSharesOverlapsAnyFolderOnTheSameNas()
    {
        var profileId = Guid.NewGuid();

        Assert.True(
            Mapping(profileId, DesktopDriveScope.AllShares)
                .Overlaps(Mapping(profileId, DesktopDriveScope.Folder("/share/folder"))));
    }

    [Fact]
    public void SpaceDecisionUsesMissingBytesPeakAndReserve()
    {
        var decision = DesktopDriveCacheSpaceCalculator.Evaluate(
            [
                new(8 * GiB, 3 * GiB),
                new(2 * GiB, 2 * GiB),
            ],
            100 * GiB,
            20 * GiB);

        Assert.Equal(
            new DesktopDriveCacheSpaceDecision(
                DesktopDriveCacheSpaceDecisionKind.Allowed,
                15 * GiB,
                20 * GiB),
            decision);
    }

    [Fact]
    public void InsufficientSpaceIncludesTheShortage()
    {
        var decision = DesktopDriveCacheSpaceCalculator.Evaluate(
            [new(8 * GiB)],
            100 * GiB,
            10 * GiB);

        Assert.Equal(
            new DesktopDriveCacheSpaceDecision(
                DesktopDriveCacheSpaceDecisionKind.Insufficient,
                21 * GiB,
                10 * GiB,
                11 * GiB),
            decision);
    }

    [Fact]
    public void UnknownSizeBlocksTheCacheDecision()
    {
        var decision = DesktopDriveCacheSpaceCalculator.Evaluate(
            [new(null)],
            100 * GiB,
            50 * GiB);

        Assert.Equal(DesktopDriveCacheSpaceDecisionKind.UnknownSize, decision.Kind);
    }

    [Fact]
    public void PausedStateOnlyAllowsCheckRemoveOrFailure()
    {
        Assert.True(DesktopDriveMappingState.Paused.CanTransitionTo(
            DesktopDriveMappingState.Checking));
        Assert.True(DesktopDriveMappingState.Paused.CanTransitionTo(
            DesktopDriveMappingState.Removing));
        Assert.False(DesktopDriveMappingState.Paused.CanTransitionTo(
            DesktopDriveMappingState.Available));
        Assert.False(DesktopDriveMappingState.Paused.CanTransitionTo(
            DesktopDriveMappingState.Offline));
    }

    [Fact]
    public void TemporaryCacheEvictionUsesLeastRecentlyAccessedFirst()
    {
        var now = DateTimeOffset.UtcNow;
        var entries = new[]
        {
            new DesktopDriveCacheEntry(
                "/old.bin",
                DesktopDriveCacheEntryKind.Temporary,
                4,
                4,
                now.AddMinutes(-2),
                now),
            new DesktopDriveCacheEntry(
                "/new.bin",
                DesktopDriveCacheEntryKind.Temporary,
                6,
                6,
                now,
                now),
            new DesktopDriveCacheEntry(
                "/offline.bin",
                DesktopDriveCacheEntryKind.KeptOffline,
                100,
                100,
                now.AddMinutes(-3),
                now),
        };

        Assert.Equal(
            ["/old.bin"],
            DesktopDriveCacheEvictionPlanner.TemporaryPathsToEvict(entries, 6));
    }

    [Theory]
    [InlineData("report?.txt", "report%3F.txt")]
    [InlineData("name. ", "name%2E%20")]
    [InlineData("CON.txt", "%00CON.txt")]
    [InlineData("LPT9", "%00LPT9")]
    [InlineData("100%.txt", "100%25.txt")]
    public void WindowsNamesAreEscapedWithoutChangingTheRemoteName(
        string remoteName,
        string localName)
    {
        Assert.Equal(
            localName,
            DesktopDriveWindowsNameCodec.EscapeSegment(remoteName));
    }

    [Fact]
    public void WindowsCaseCollisionsGetStableDistinctSuffixes()
    {
        var result = DesktopDriveWindowsNameCodec.BuildSafeSegments(
            ["/share/Readme.txt", "/share/README.TXT"]);

        Assert.NotEqual(
            result["/share/Readme.txt"],
            result["/share/README.TXT"],
            StringComparer.OrdinalIgnoreCase);
        Assert.StartsWith("Readme.txt~", result["/share/Readme.txt"]);
        Assert.StartsWith("README.TXT~", result["/share/README.TXT"]);
        var reversed = DesktopDriveWindowsNameCodec.BuildSafeSegments(
            ["/share/README.TXT", "/share/Readme.txt"]);
        Assert.Equal(result["/share/Readme.txt"], reversed["/share/Readme.txt"]);
        Assert.Equal(result["/share/README.TXT"], reversed["/share/README.TXT"]);
    }

    [Fact]
    public async Task RecursivePlanPagesFoldersAndTotalsTrustedSizes()
    {
        var root = new[]
        {
            File("/share/root.txt", 3),
            Folder("/share/sub"),
        };
        var sub = new[]
        {
            File("/share/sub/a.bin", 5),
            File("/share/sub/b.bin", 7),
        };

        var plan = await DesktopDriveTreePlanner.BuildAsync(
            ["/share"],
            (path, offset, limit, _) =>
            {
                var source = path == "/share" ? root : sub;
                var items = source.Skip(offset).Take(limit).ToArray();
                return Task.FromResult(new FilePage(items, source.Length, offset));
            },
            pageSize: 1);

        Assert.True(plan.IsComplete);
        Assert.Equal(
            ["/share/root.txt", "/share/sub/a.bin", "/share/sub/b.bin"],
            plan.Files.Select(item => item.RemotePath));
        Assert.Equal(15, plan.TotalBytes);
        Assert.Equal(7, plan.LargestFileBytes);
        Assert.Equal(2, plan.FolderCount);
    }

    [Fact]
    public async Task UnknownSizeAndInaccessibleFolderBlockConfirmation()
    {
        var plan = await DesktopDriveTreePlanner.BuildAsync(
            ["/share"],
            (path, _, _, _) =>
            {
                if (path == "/share/private")
                {
                    throw new UnauthorizedAccessException();
                }
                return Task.FromResult(new FilePage(
                    [
                        File("/share/unknown.bin", -1),
                        Folder("/share/private"),
                    ],
                    2,
                    0));
            });

        Assert.False(plan.IsComplete);
        Assert.Equal(
            [
                DesktopDrivePlanIssueKind.InaccessibleFolder,
                DesktopDrivePlanIssueKind.UnknownFileSize,
            ],
            plan.Issues.Select(issue => issue.Kind).Order());
    }

    [Fact]
    public async Task RangeTransferCarriesStrongVersionAndTotalAcrossSegments()
    {
        var reads = new List<(long Offset, long Length, string? Version, long? Total)>();
        var submissions = new List<(long Offset, int Length)>();
        var failures = new List<(long Offset, long Length)>();

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/video.bin",
            0,
            10,
            10,
            4,
            null,
            null,
            (offset, length, version, total, _) =>
            {
                reads.Add((offset, length, version, total));
                return Task.FromResult(Range(offset, length, 10, "\"v1\""));
            },
            (offset, bytes) => submissions.Add((offset, bytes.Length)),
            (offset, length) => failures.Add((offset, length)),
            CancellationToken.None);

        Assert.True(outcome.Succeeded);
        Assert.Equal("\"v1\"", outcome.StrongContentVersion);
        Assert.Equal(10, outcome.TotalLength);
        Assert.Equal(
            [
                (0L, 4L, (string?)null, (long?)null),
                (4L, 4L, "\"v1\"", 10L),
                (8L, 2L, "\"v1\"", 10L),
            ],
            reads);
        Assert.Equal([(0L, 10)], submissions);
        Assert.Empty(failures);
    }

    [Fact]
    public async Task SegmentedReadWithoutStrongVersionFailsBeforeSubmittingData()
    {
        var submissions = 0;
        var failures = new List<(long Offset, long Length)>();

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/video.bin",
            0,
            10,
            10,
            4,
            null,
            null,
            (offset, length, _, _, _) => Task.FromResult(
                Range(offset, length, 10, version: null, safe: false)),
            (_, _) => submissions++,
            (offset, length) => failures.Add((offset, length)),
            CancellationToken.None);

        Assert.False(outcome.Succeeded);
        Assert.Equal(0, submissions);
        Assert.Equal([(0L, 10L)], failures);
    }

    [Fact]
    public async Task PartialSingleReadWithoutStrongVersionAlsoFailsBeforeSubmission()
    {
        var submissions = 0;
        var failures = new List<(long Offset, long Length)>();

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/video.bin",
            4,
            2,
            10,
            4,
            null,
            null,
            (offset, length, _, _, _) => Task.FromResult(
                Range(offset, length, 10, version: null, safe: false)),
            (_, _) => submissions++,
            (offset, length) => failures.Add((offset, length)),
            CancellationToken.None);

        Assert.False(outcome.Succeeded);
        Assert.Equal(0, submissions);
        Assert.Equal([(4L, 2L)], failures);
    }

    [Fact]
    public async Task WholeFileSingleReadWithoutStrongVersionFailsBeforeSubmission()
    {
        var submissions = new List<(long Offset, int Length)>();
        var failures = new List<(long Offset, long Length)>();

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/note.txt",
            0,
            3,
            3,
            4,
            null,
            null,
            (offset, length, _, _, _) => Task.FromResult(
                Range(offset, length, 3, version: null, safe: false)),
            (offset, bytes) => submissions.Add((offset, bytes.Length)),
            (offset, length) => failures.Add((offset, length)),
            CancellationToken.None);

        Assert.False(outcome.Succeeded);
        Assert.Null(outcome.StrongContentVersion);
        Assert.Empty(submissions);
        Assert.Equal([(0L, 3L)], failures);
    }

    [Fact]
    public async Task ContentVersionChangeStopsWithExactlyOneFailure()
    {
        var submissions = new List<long>();
        var failures = new List<(long Offset, long Length)>();
        var readCount = 0;

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/video.bin",
            0,
            8,
            8,
            4,
            null,
            null,
            (offset, length, _, _, _) => Task.FromResult(
                Range(offset, length, 8, readCount++ == 0 ? "\"v1\"" : "\"v2\"")),
            (offset, _) => submissions.Add(offset),
            (offset, length) => failures.Add((offset, length)),
            CancellationToken.None);

        Assert.False(outcome.Succeeded);
        Assert.Empty(submissions);
        Assert.Equal([(0L, 8L)], failures);
    }

    [Fact]
    public async Task TotalLengthChangeStopsWithExactlyOneFailure()
    {
        var submissions = new List<long>();
        var failures = new List<(long Offset, long Length)>();
        var readCount = 0;

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/video.bin",
            0,
            8,
            8,
            4,
            null,
            null,
            (offset, length, _, _, _) => Task.FromResult(
                Range(offset, length, readCount++ == 0 ? 8 : 9, "\"v1\"")),
            (offset, _) => submissions.Add(offset),
            (offset, length) => failures.Add((offset, length)),
            CancellationToken.None);

        Assert.False(outcome.Succeeded);
        Assert.Empty(submissions);
        Assert.Equal([(0L, 8L)], failures);
    }

    [Fact]
    public async Task CancellationProducesNoDataAndExactlyOneFailure()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var reads = 0;
        var submissions = 0;
        var failures = new List<(long Offset, long Length)>();

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/video.bin",
            0,
            8,
            8,
            4,
            null,
            null,
            (offset, length, _, _, _) =>
            {
                reads++;
                return Task.FromResult(Range(offset, length, 8, "\"v1\""));
            },
            (_, _) => submissions++,
            (offset, length) => failures.Add((offset, length)),
            cancellation.Token);

        Assert.False(outcome.Succeeded);
        Assert.Equal(0, reads);
        Assert.Equal(0, submissions);
        Assert.Equal([(0L, 8L)], failures);
    }

    [Fact]
    public async Task FailureSubmissionIsNeverRetried()
    {
        var failures = 0;

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/video.bin",
            0,
            8,
            8,
            4,
            null,
            null,
            (offset, length, _, _, _) => Task.FromResult(
                Range(offset, length, 8, version: null, safe: false)),
            (_, _) => throw new Xunit.Sdk.XunitException("Data must not be submitted."),
            (_, _) =>
            {
                failures++;
                throw new IOException("Synthetic native failure");
            },
            CancellationToken.None);

        Assert.False(outcome.Succeeded);
        Assert.Equal(1, failures);
    }

    [Fact]
    public async Task PartialCallbacksRemainRejectedAcrossARuntimeRestart()
    {
        var submissions = 0;
        var failures = new List<(long Offset, long Length)>();

        async Task<CloudFileRangeTransferOutcome> ExecutePartialAsync() =>
            await CloudFileRangeTransfer.ExecuteAsync(
                "/share/video.bin",
                0,
                4,
                8,
                4,
                null,
                null,
                (offset, length, _, _, _) => Task.FromResult(
                    Range(offset, length, 8, "\"v1\"")),
                (_, _) => submissions++,
                (offset, length) => failures.Add((offset, length)),
                CancellationToken.None);

        Assert.False((await ExecutePartialAsync()).Succeeded);
        // 新协调器调用模拟进程重启后没有任何内存版本缓存。
        Assert.False((await ExecutePartialAsync()).Succeeded);
        Assert.Equal(0, submissions);
        Assert.Equal([(0L, 4L), (0L, 4L)], failures);
    }

    [Fact]
    public async Task UnboundedWholeFileIsRejectedBeforeReadingOrSubmitting()
    {
        var reads = 0;
        var submissions = 0;
        var failures = new List<(long Offset, long Length)>();
        var length = CloudFileRangeTransfer.MaximumBufferedTransferBytes + 1;

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/large.bin",
            0,
            length,
            length,
            4 * 1024 * 1024,
            null,
            null,
            (_, _, _, _, _) =>
            {
                reads++;
                throw new Xunit.Sdk.XunitException("The range must not be read.");
            },
            (_, _) => submissions++,
            (offset, failureLength) => failures.Add((offset, failureLength)),
            CancellationToken.None);

        Assert.False(outcome.Succeeded);
        Assert.Equal(0, reads);
        Assert.Equal(0, submissions);
        Assert.Equal([(0L, length)], failures);
    }

    [Fact]
    public async Task EofLengthIsNormalizedButPartialEofStillFailsSafely()
    {
        var reads = 0;
        var submissions = 0;
        var failures = new List<(long Offset, long Length)>();

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/video.bin",
            4,
            -1,
            10,
            4,
            null,
            null,
            (_, _, _, _, _) =>
            {
                reads++;
                throw new Xunit.Sdk.XunitException("Partial EOF must not be read.");
            },
            (_, _) => submissions++,
            (offset, length) => failures.Add((offset, length)),
            CancellationToken.None);

        Assert.False(outcome.Succeeded);
        Assert.Equal(0, reads);
        Assert.Equal(0, submissions);
        Assert.Equal([(4L, 6L)], failures);
    }

    [Fact]
    public async Task WholeFileEofLengthIsNormalizedAndSubmittedOnce()
    {
        var submissions = new List<(long Offset, int Length)>();
        var failures = new List<(long Offset, long Length)>();

        var outcome = await CloudFileRangeTransfer.ExecuteAsync(
            "/share/video.bin",
            0,
            -1,
            6,
            4,
            null,
            null,
            (offset, length, _, _, _) => Task.FromResult(
                Range(offset, length, 6, "\"v1\"")),
            (offset, bytes) => submissions.Add((offset, bytes.Length)),
            (offset, length) => failures.Add((offset, length)),
            CancellationToken.None);

        Assert.True(outcome.Succeeded);
        Assert.Equal([(0L, 6)], submissions);
        Assert.Empty(failures);
    }

    [Theory]
    [InlineData(0, 8, 2, 2, false)]
    [InlineData(0, 8, 0, 7, false)]
    [InlineData(0, 8, 0, 8, true)]
    [InlineData(4, 4, 0, -1, true)]
    [InlineData(4, 4, 5, -1, false)]
    public void OnlyCancellationCoveringTheWholeOutstandingRangeCancels(
        long requestOffset,
        long requestLength,
        long cancelledOffset,
        long cancelledLength,
        bool expected)
    {
        Assert.Equal(
            expected,
            CloudFileCancelRange.CoversOutstandingRange(
                requestOffset,
                requestLength,
                cancelledOffset,
                cancelledLength));
    }

    [Fact]
    public void CloudFilesRegistrationIsClosedByDefaultUntilDeviceValidation()
    {
        Assert.False(DesktopCloudDriveCapabilityGate.IsRegistrationEnabled);
        var error = Assert.Throws<InvalidOperationException>(
            DesktopCloudDriveCapabilityGate.EnsureRegistrationEnabled);
        Assert.Equal("CloudDrivePendingDeviceValidation", error.Message);
    }

    [Fact]
    public void CloudFilesTransferInteropLayoutAndConstantsRemainStable()
    {
        Assert.Equal(0u, CloudFilesInterop.CallbackFetchData);
        Assert.Equal(2u, CloudFilesInterop.CallbackCancelFetchData);
        Assert.Equal(0u, CloudFilesInterop.OperationTransferData);
        Assert.Equal(48, Marshal.SizeOf<CloudFilesInterop.OperationInfo>());
        Assert.Equal(
            new IntPtr(40),
            Marshal.OffsetOf<CloudFilesInterop.OperationInfo>("RequestKey"));
        Assert.Equal(40, Marshal.SizeOf<CloudFilesInterop.TransferDataParameters>());
        Assert.Equal(
            new IntPtr(16),
            Marshal.OffsetOf<CloudFilesInterop.TransferDataParameters>("Buffer"));
        Assert.Equal(
            new IntPtr(24),
            Marshal.OffsetOf<CloudFilesInterop.TransferDataParameters>("Offset"));
        Assert.Equal(
            new IntPtr(32),
            Marshal.OffsetOf<CloudFilesInterop.TransferDataParameters>("Length"));
    }

    [Fact]
    public void DisabledRegistrationAndMutationCallbacksContainNoNasWriteCalls()
    {
        var source = ReadRepositoryFile(
            "windows/src/LanStash.App/CloudDrive/DesktopCloudDriveService.cs");
        var runtimeStart = source.IndexOf(
            "private sealed class MappingRuntime",
            StringComparison.Ordinal);
        var runtimeSource = source[runtimeStart..];

        Assert.Contains(
            "DesktopCloudDriveCapabilityGate.EnsureRegistrationEnabled();",
            source);
        Assert.DoesNotContain("UnregisterPersistedSyncRoots", source);
        var initializeStart = source.IndexOf(
            "internal async Task InitializeAsync()",
            StringComparison.Ordinal);
        var activateStart = source.IndexOf(
            "internal async Task ActivateAsync",
            StringComparison.Ordinal);
        var initializeSource = source[initializeStart..activateStart];
        Assert.DoesNotContain("CfUnregisterSyncRoot", initializeSource);
        Assert.DoesNotContain("CfRegisterSyncRoot", initializeSource);
        Assert.DoesNotContain("CfConnectSyncRoot", initializeSource);
        Assert.DoesNotContain("CreateFolderAsync(", runtimeSource);
        Assert.DoesNotContain("RenameAsync(", runtimeSource);
        Assert.DoesNotContain("DeleteFilesAsync(", runtimeSource);
        Assert.Contains("StatusAccessDenied", runtimeSource);
    }

    private static DesktopDriveMapping Mapping(
        Guid profileId,
        DesktopDriveScope scope) =>
        new(
            Guid.NewGuid(),
            profileId,
            "Mapping",
            scope,
            DesktopDriveAccessMode.ReadOnly,
            DesktopDriveCachePolicy.Default,
            true,
            DateTimeOffset.UtcNow);

    private static FileItem File(string path, long size) =>
        new(
            path,
            Path.GetFileName(path),
            false,
            size,
            null,
            null,
            false,
            false);

    private static FileItem Folder(string path) =>
        new(
            path,
            Path.GetFileName(path),
            true,
            0,
            null,
            null,
            false,
            false);

    private static FileRangeReadResult Range(
        long offset,
        long length,
        long total,
        string? version,
        bool safe = true) =>
        new(
            206,
            offset,
            length,
            offset,
            length,
            total,
            length,
            new byte[checked((int)length)],
            version,
            safe);

    private static string ReadRepositoryFile(string relativePath)
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (directory is not null)
        {
            var candidate = Path.Combine(directory.FullName, relativePath);
            if (System.IO.File.Exists(candidate))
            {
                return System.IO.File.ReadAllText(candidate);
            }
            directory = directory.Parent;
        }
        throw new DirectoryNotFoundException(
            $"Unable to locate repository file: {relativePath}");
    }
}
