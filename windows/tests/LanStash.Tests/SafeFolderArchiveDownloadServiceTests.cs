using LanStash.App.Features.Transfers;
using LanStash.Domain;
using System.IO.Compression;

namespace LanStash.Tests;

public sealed class SafeFolderArchiveDownloadServiceTests
{
    [Fact]
    public void ArchiveValidatorAcceptsCompleteZipAndRejectsTruncation()
    {
        using var complete = new MemoryStream();
        using (var archive = new ZipArchive(complete, ZipArchiveMode.Create, leaveOpen: true))
        {
            var entry = archive.CreateEntry("synthetic.txt");
            using var writer = new StreamWriter(entry.Open());
            writer.Write("synthetic");
        }
        var bytes = complete.ToArray();

        FolderArchiveValidator.Validate(new MemoryStream(bytes, writable: false));
        Assert.Throws<InvalidDataException>(() => FolderArchiveValidator.Validate(
            new MemoryStream(bytes[..^8], writable: false)));
    }

    [Fact]
    public async Task StreamsEveryChunkThenCommitsOnce()
    {
        var repository = new StubArchiveReader(
            [new byte[] { 0x50, 0x4B, 0x03, 0x04 }, new byte[] { 1, 2, 3 }]);
        var destination = new RecordingDestination();

        await new SafeFolderArchiveDownloadService().DownloadAsync(
            repository,
            "/synthetic/folder",
            destination);

        Assert.Equal("/synthetic/folder", repository.RemotePath);
        Assert.Equal(2, destination.Writes.Count);
        Assert.True(destination.Committed);
        Assert.False(destination.Aborted);
        Assert.True(destination.Disposed);
    }

    [Fact]
    public async Task StreamFailureAbortsAndPreservesOriginalTarget()
    {
        var failure = new InvalidDataException("synthetic archive failure");
        var destination = new RecordingDestination();

        var thrown = await Assert.ThrowsAsync<InvalidDataException>(() =>
            new SafeFolderArchiveDownloadService().DownloadAsync(
                new StubArchiveReader(failure),
                "/synthetic/folder",
                destination));

        Assert.Same(failure, thrown);
        Assert.False(destination.Committed);
        Assert.True(destination.Aborted);
        Assert.True(destination.Disposed);
    }

    [Fact]
    public async Task CancellationBeforeCommitAbortsAndStopsPublication()
    {
        using var cancellation = new CancellationTokenSource();
        var destination = new RecordingDestination
        {
            OnWrite = cancellation.Cancel,
        };

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new SafeFolderArchiveDownloadService().DownloadAsync(
                new StubArchiveReader([new byte[] { 0x50, 0x4B, 0x03, 0x04 }]),
                "/synthetic/folder",
                destination,
                cancellation.Token));

        Assert.False(destination.Committed);
        Assert.True(destination.Aborted);
        Assert.True(destination.Disposed);
    }

    [Fact]
    public async Task CommitFailureAbortsAndKeepsThePrimaryFailure()
    {
        var failure = new IOException("synthetic commit failure");
        var destination = new RecordingDestination
        {
            CommitFailure = failure,
            AbortFailure = new IOException("synthetic cleanup failure"),
        };
        var diagnostics = new List<(string Stage, Type Type)>();

        var thrown = await Assert.ThrowsAsync<IOException>(() =>
            new SafeFolderArchiveDownloadService((stage, type) =>
                diagnostics.Add((stage, type))).DownloadAsync(
                    new StubArchiveReader([new byte[] { 0x50, 0x4B, 0x03, 0x04 }]),
                    "/synthetic/folder",
                    destination));

        Assert.Same(failure, thrown);
        Assert.Equal([("abort", typeof(IOException))], diagnostics);
        Assert.True(destination.Disposed);
    }

    [Fact]
    public async Task CancellationDuringNonCancelableCommitUsesThePublishedResult()
    {
        using var cancellation = new CancellationTokenSource();
        var destination = new RecordingDestination
        {
            OnCommit = cancellation.Cancel,
        };

        await new SafeFolderArchiveDownloadService().DownloadAsync(
            new StubArchiveReader([new byte[] { 0x50, 0x4B, 0x03, 0x04 }]),
            "/synthetic/folder",
            destination,
            cancellation.Token);

        Assert.True(cancellation.IsCancellationRequested);
        Assert.True(destination.Committed);
        Assert.False(destination.Aborted);
        Assert.True(destination.Disposed);
    }

    private sealed class StubArchiveReader : IFileArchiveReader
    {
        private readonly IReadOnlyList<byte[]>? _chunks;
        private readonly Exception? _failure;

        public StubArchiveReader(IReadOnlyList<byte[]> chunks) => _chunks = chunks;
        public StubArchiveReader(Exception failure) => _failure = failure;

        public string? RemotePath { get; private set; }

        public async Task StreamFolderArchiveAsync(
            string remotePath,
            Func<ReadOnlyMemory<byte>, CancellationToken, ValueTask> writeChunkAsync,
            CancellationToken cancellationToken = default)
        {
            RemotePath = remotePath;
            if (_failure is not null)
            {
                throw _failure;
            }
            foreach (var chunk in _chunks!)
            {
                cancellationToken.ThrowIfCancellationRequested();
                await writeChunkAsync(chunk, cancellationToken);
            }
        }
    }

    private sealed class RecordingDestination : ITransactionalDownloadDestination
    {
        public List<byte[]> Writes { get; } = [];
        public bool Committed { get; private set; }
        public bool Aborted { get; private set; }
        public bool Disposed { get; private set; }
        public Action? OnWrite { get; init; }
        public Action? OnCommit { get; init; }
        public Exception? CommitFailure { get; init; }
        public Exception? AbortFailure { get; init; }

        public ValueTask WriteAsync(
            ReadOnlyMemory<byte> bytes,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Writes.Add(bytes.ToArray());
            OnWrite?.Invoke();
            return ValueTask.CompletedTask;
        }

        public ValueTask CommitAsync(CancellationToken cancellationToken = default)
        {
            OnCommit?.Invoke();
            if (CommitFailure is not null)
            {
                return ValueTask.FromException(CommitFailure);
            }
            Committed = true;
            return ValueTask.CompletedTask;
        }

        public ValueTask AbortAsync(CancellationToken cancellationToken = default)
        {
            Aborted = true;
            return AbortFailure is null
                ? ValueTask.CompletedTask
                : ValueTask.FromException(AbortFailure);
        }

        public ValueTask DisposeAsync()
        {
            Disposed = true;
            return ValueTask.CompletedTask;
        }
    }
}
