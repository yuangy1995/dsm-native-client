using System.Runtime.InteropServices;
using LanStash.App.CloudDrive;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DesktopCloudDriveHydrationTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "lanstash-hydration-tests-" + Guid.NewGuid().ToString("N"));
    private readonly DesktopDriveMapping _mapping = new(Guid.NewGuid(), Guid.NewGuid(), "Synthetic",
        DesktopDriveScope.Folder("/share"), DesktopDriveAccessMode.ReadOnly, DesktopDriveCachePolicy.Default, false, DateTimeOffset.UtcNow);
    private const string Remote = "/share/file.bin";
    private DesktopCloudDriveSyncStore Store => new(_root);

    [Fact]
    public async Task PartialReadsPersistBeforeSubmissionAndReuseVersionAfterRestart()
    {
        var observed = new List<(long Offset, string? Version, long? Total)>();
        var first = await TransferAsync(0, 4, 12, "\"v1\"", observed);
        Assert.True(first.Succeeded);
        // 新的存储与调用实例模拟重启；后续非零偏移不能重新选择另一版本。
        var second = await TransferAsync(4, 8, 12, "\"v1\"", observed);
        Assert.True(second.Succeeded);
        Assert.Equal([(0L, (string?)null, (long?)null), (4L, "\"v1\"", 12L), (8L, "\"v1\"", 12L)], observed);
        Assert.Equal(new(Remote, "\"v1\"", 12), await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Fact]
    public async Task ChangedVersionAfterRestartCannotSubmitOrReplaceBaseline()
    {
        Assert.True((await TransferAsync(0, 4, 12, "\"v1\"", [])).Succeeded);
        var submissions = 0;
        var known = await Store.ReadVersionAsync(_mapping, Remote);
        var result = await CloudFileRangeTransfer.ExecuteAsync(Remote, 4, 8, 12, 4, known!.Version, known.Length,
            (offset, length, _, _, _) => Task.FromResult(Range(offset, length, 12, "\"v2\"")),
            (_, _) => submissions++, (_, _) => { }, CancellationToken.None, PersistAsync);
        Assert.False(result.Succeeded);
        Assert.Equal(0, submissions);
        Assert.Equal(known, await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Fact]
    public async Task LargeWholeFileUsesBoundedChunksInsteadOfWholeFileBuffer()
    {
        const long size = 129L * 1024 * 1024 + 17;
        const long chunk = 4L * 1024 * 1024;
        var delivered = 0L; var count = 0; var maximum = 0;
        var result = await CloudFileRangeTransfer.ExecuteAsync(Remote, 0, -1, size, chunk, null, null,
            (offset, length, version, total, _) =>
            {
                Assert.InRange(length, 1, chunk);
                if (offset != 0) { Assert.Equal("\"large\"", version); Assert.Equal(size, total); }
                return Task.FromResult(Range(offset, length, size, "\"large\""));
            },
            (offset, bytes) => { Assert.Equal(delivered, offset); delivered += bytes.Length; maximum = Math.Max(maximum, bytes.Length); count++; },
            (_, _) => throw new InvalidOperationException("合成完整读取不得失败"), CancellationToken.None, PersistAsync);
        Assert.True(result.Succeeded);
        Assert.Equal(size, delivered);
        Assert.Equal(33, count);
        Assert.Equal(chunk, maximum);
    }

    [Fact]
    public async Task PersistenceFailureNeverDeliversAnyBytes()
    {
        var submitted = 0; var failures = 0;
        var result = await CloudFileRangeTransfer.ExecuteAsync(Remote, 0, 8, 8, 4, null, null,
            (offset, length, _, _, _) => Task.FromResult(Range(offset, length, 8, "\"v1\"")),
            (_, _) => submitted++, (_, _) => failures++, CancellationToken.None,
            (_, _, _) => Task.FromException(new IOException("合成日志落盘失败")));
        Assert.False(result.Succeeded); Assert.Equal(0, submitted); Assert.Equal(1, failures);
    }

    [Fact]
    public async Task CancellationDuringVersionCommitDeliversNothing()
    {
        using var cancellation = new CancellationTokenSource(); var submitted = 0;
        var result = await CloudFileRangeTransfer.ExecuteAsync(Remote, 0, 8, 8, 4, null, null,
            (offset, length, _, _, _) => Task.FromResult(Range(offset, length, 8, "\"v1\"")),
            (_, _) => submitted++, (_, _) => { }, cancellation.Token,
            async (version, length, token) => { await PersistAsync(version, length, token); cancellation.Cancel(); });
        Assert.False(result.Succeeded); Assert.Equal(0, submitted);
        Assert.NotNull(await Store.ReadVersionAsync(_mapping, Remote));
    }

    [Fact]
    public async Task NativeFailureIsNotReportedForPreviouslyDeliveredChunks()
    {
        var failures = new List<(long, long)>();
        var result = await CloudFileRangeTransfer.ExecuteAsync(Remote, 0, 12, 12, 4, null, null,
            (offset, length, _, _, _) => Task.FromResult(Range(offset, length, 12, "\"v1\"")),
            (offset, _) => { if (offset == 4) throw new IOException("合成原生提交失败"); },
            (offset, length) => failures.Add((offset, length)), CancellationToken.None, PersistAsync);
        Assert.False(result.Succeeded); Assert.Equal([(4L, 8L)], failures);
    }

    [Fact]
    public void NativeSnapshotRequiresCorrectIdentityAndNoLocalChanges()
    {
        var clean = new CloudFilesInterop.PlaceholderStandardInfo { FileId = 7, SyncRootFileId = 9 };
        CloudFileHydrationGuard.Validate(clean, 7, 9, null, 8);
        Assert.Throws<InvalidDataException>(() => CloudFileHydrationGuard.Validate(clean, 8, 9, null, 8));
        Assert.Throws<InvalidDataException>(() => CloudFileHydrationGuard.Validate(clean, 7, 10, null, 8));
        clean.ModifiedDataSize = 1;
        Assert.Throws<InvalidDataException>(() => CloudFileHydrationGuard.Validate(clean, 7, 9, new(Remote, "\"v1\"", 8), 8));
    }

    [Fact]
    public void LegacyBytesWithoutVersionAreNotMixedWithNewContent()
    {
        var legacy = new CloudFilesInterop.PlaceholderStandardInfo { FileId = 7, SyncRootFileId = 9, OnDiskDataSize = 4, ValidatedDataSize = 4 };
        Assert.Throws<InvalidDataException>(() => CloudFileHydrationGuard.Validate(legacy, 7, 9, null, 8));
        CloudFileHydrationGuard.Validate(legacy, 7, 9, new(Remote, "\"v1\"", 8), 8);
        Assert.Throws<InvalidDataException>(() => CloudFileHydrationGuard.Validate(legacy, 7, 9, new(Remote, "\"v1\"", 7), 8));
    }

    [Theory]
    [InlineData(1, 10, 9000, 0, 4096)]
    [InlineData(4096, 1, 5000, 4096, 904)]
    [InlineData(0, 8192, 8192, 0, 8192)]
    public void NativeRangesAreAlignedExceptAtEof(long offset, long length, long size, long expectedOffset, long expectedLength)
        => Assert.Equal((expectedOffset, expectedLength), CloudFileHydrationGuard.AlignRange(offset, length, size));

    [Fact]
    public void NativeRangeAlignmentDoesNotOverflowNearMaximumFileSize()
    {
        var (offset, length) = CloudFileHydrationGuard.AlignRange(long.MaxValue - 5, 5, long.MaxValue);
        Assert.Equal(0, offset % 4096);
        Assert.Equal(long.MaxValue, offset + length);
        Assert.Throws<ArgumentOutOfRangeException>(() => CloudFileHydrationGuard.AlignRange(8, 2, 9));
    }

    [Fact]
    public void NativeInformationLayoutMatchesDocumentedPrefix()
    {
        Assert.Equal(64, Marshal.SizeOf<CloudFilesInterop.PlaceholderStandardInfo>());
        Assert.Equal(new IntPtr(40), Marshal.OffsetOf<CloudFilesInterop.PlaceholderStandardInfo>("FileId"));
        Assert.Equal(new IntPtr(56), Marshal.OffsetOf<CloudFilesInterop.PlaceholderStandardInfo>("FileIdentityLength"));
    }

    private async Task<CloudFileRangeTransferOutcome> TransferAsync(long start, long length, long size, string version,
        List<(long Offset, string? Version, long? Total)> reads)
    {
        var known = await Store.ReadVersionAsync(_mapping, Remote);
        var persisted = false;
        return await CloudFileRangeTransfer.ExecuteAsync(Remote, start, length, size, 4, known?.Version, known?.Length,
            (offset, count, expected, total, _) => { reads.Add((offset, expected, total)); return Task.FromResult(Range(offset, count, size, version)); },
            (_, _) => Assert.True(persisted), (_, _) => { }, CancellationToken.None,
            async (value, total, token) => { await PersistAsync(value, total, token); persisted = true; });
    }
    private Task PersistAsync(string version, long size, CancellationToken token) => Store.BindVersionAsync(_mapping, new(Remote, version, size), token);
    private static FileRangeReadResult Range(long start, long length, long size, string version) =>
        new(206, start, length, start, length, size, length, new byte[checked((int)length)], version, true);
    public void Dispose() { if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true); }
}
