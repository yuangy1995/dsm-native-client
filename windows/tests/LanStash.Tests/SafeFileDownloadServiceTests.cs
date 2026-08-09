using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SafeFileDownloadServiceTests
{
    [Fact]
    public async Task ZeroByteFileCommitsWithoutRangeRequest()
    {
        var repository = new StubRepository();
        var destination = new RecordingDestination();

        await new SafeFileDownloadService().DownloadAsync(
            repository,
            "/empty.txt",
            0,
            destination);

        Assert.Empty(repository.Requests);
        Assert.True(destination.Committed);
        Assert.False(destination.Aborted);
        Assert.True(destination.Disposed);
        Assert.Empty(destination.Writes);
    }

    [Fact]
    public async Task SingleChunkAllowsMissingStrongVersion()
    {
        var repository = new StubRepository();
        repository.EnqueueResult(Result(0, 3, 3, [1, 2, 3], version: null, safe: false));
        var destination = new RecordingDestination();

        await new SafeFileDownloadService().DownloadAsync(
            repository,
            "/small.bin",
            3,
            destination);

        var request = Assert.Single(repository.Requests);
        Assert.Null(request.ExpectedVersion);
        Assert.Equal(3L, request.ExpectedTotalLength);
        Assert.Equal(new byte[] { 1, 2, 3 }, Assert.Single(destination.Writes));
        Assert.True(destination.Committed);
    }

    [Fact]
    public async Task MultiChunkPinsStrongVersionAndKnownTotalAfterFirstRange()
    {
        var total = (long)SafeFileDownloadService.ChunkSize + 2;
        var repository = new StubRepository();
        repository.EnqueueResult(Result(
            0,
            SafeFileDownloadService.ChunkSize,
            total,
            new byte[SafeFileDownloadService.ChunkSize],
            "\"version-1\"",
            safe: true));
        repository.EnqueueResult(Result(
            SafeFileDownloadService.ChunkSize,
            2,
            total,
            [7, 8],
            "\"version-1\"",
            safe: true));
        var destination = new RecordingDestination();

        await new SafeFileDownloadService().DownloadAsync(
            repository,
            "/large.bin",
            total,
            destination);

        Assert.Collection(
            repository.Requests,
            first =>
            {
                Assert.Equal(0L, first.Offset);
                Assert.Equal((long)SafeFileDownloadService.ChunkSize, first.Length);
                Assert.Null(first.ExpectedVersion);
                Assert.Equal(total, first.ExpectedTotalLength);
            },
            second =>
            {
                Assert.Equal((long)SafeFileDownloadService.ChunkSize, second.Offset);
                Assert.Equal(2L, second.Length);
                Assert.Equal("\"version-1\"", second.ExpectedVersion);
                Assert.Equal(total, second.ExpectedTotalLength);
            });
        Assert.True(destination.Committed);
        Assert.False(destination.Aborted);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("W/\"weak\"")]
    public async Task MultiChunkWithoutStrongFirstVersionAborts(string? version)
    {
        var total = (long)SafeFileDownloadService.ChunkSize + 1;
        var repository = new StubRepository();
        repository.EnqueueResult(Result(
            0,
            SafeFileDownloadService.ChunkSize,
            total,
            new byte[SafeFileDownloadService.ChunkSize],
            version,
            safe: true));
        var destination = new RecordingDestination();

        await Assert.ThrowsAsync<FileRangeContractException>(() =>
            new SafeFileDownloadService().DownloadAsync(
                repository,
                "/large.bin",
                total,
                destination));

        Assert.Single(repository.Requests);
        Assert.False(destination.Committed);
        Assert.True(destination.Aborted);
        Assert.True(destination.Disposed);
        Assert.Empty(destination.Writes);
    }

    [Fact]
    public async Task MultiChunkUnsafeFirstRangeAbortsBeforeWriting()
    {
        var total = (long)SafeFileDownloadService.ChunkSize + 1;
        var repository = new StubRepository();
        repository.EnqueueResult(Result(
            0,
            SafeFileDownloadService.ChunkSize,
            total,
            new byte[SafeFileDownloadService.ChunkSize],
            "\"version-1\"",
            safe: false));
        var destination = new RecordingDestination();

        await Assert.ThrowsAsync<FileRangeContractException>(() =>
            new SafeFileDownloadService().DownloadAsync(
                repository,
                "/large.bin",
                total,
                destination));

        Assert.True(destination.Aborted);
        Assert.False(destination.Committed);
        Assert.Empty(destination.Writes);
    }

    [Fact]
    public async Task LaterRangeFailureNeverCommitsAndKeepsOldTarget()
    {
        var total = (long)SafeFileDownloadService.ChunkSize + 1;
        var repository = new StubRepository();
        repository.EnqueueResult(Result(
            0,
            SafeFileDownloadService.ChunkSize,
            total,
            new byte[SafeFileDownloadService.ChunkSize],
            "\"version-1\"",
            safe: true));
        repository.EnqueueFailure(new FileRangeContractException(
            FileRangeContractFailure.ContentVersionMismatch,
            "changed"));
        var destination = new RecordingDestination();

        await Assert.ThrowsAsync<FileRangeContractException>(() =>
            new SafeFileDownloadService().DownloadAsync(
                repository,
                "/large.bin",
                total,
                destination));

        Assert.False(destination.Committed);
        Assert.True(destination.Aborted);
        Assert.True(destination.OldTargetPreserved);
        Assert.Single(destination.Writes);
    }

    [Fact]
    public async Task CancellationNeverCommitsAndKeepsOldTarget()
    {
        var repository = new StubRepository();
        repository.EnqueueResult(Result(0, 3, 3, [1, 2, 3], version: null, safe: false));
        using var cancellation = new CancellationTokenSource();
        var destination = new RecordingDestination
        {
            OnWrite = cancellation.Cancel,
        };

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new SafeFileDownloadService().DownloadAsync(
                repository,
                "/small.bin",
                3,
                destination,
                cancellationToken: cancellation.Token));

        Assert.False(destination.Committed);
        Assert.True(destination.Aborted);
        Assert.True(destination.OldTargetPreserved);
    }

    [Fact]
    public async Task CancellationAtCommitStartDoesNotInterruptAtomicReplacement()
    {
        var repository = new StubRepository();
        repository.EnqueueResult(Result(0, 3, 3, [1, 2, 3], version: null, safe: false));
        using var cancellation = new CancellationTokenSource();
        var destination = new RecordingDestination
        {
            OnCommit = commitToken =>
            {
                Assert.False(commitToken.CanBeCanceled);
                cancellation.Cancel();
            },
        };

        await new SafeFileDownloadService().DownloadAsync(
            repository,
            "/small.bin",
            3,
            destination,
            cancellationToken: cancellation.Token);

        Assert.True(destination.Committed);
        Assert.False(destination.Aborted);
        Assert.True(destination.Disposed);
    }

    [Fact]
    public async Task DisposeFailureAfterSuccessfulCommitDoesNotReverseSuccess()
    {
        var repository = new StubRepository();
        repository.EnqueueResult(Result(0, 1, 1, [1], version: null, safe: false));
        var destination = new RecordingDestination
        {
            DisposeFailure = new IOException("temporary cleanup failed"),
        };

        await new SafeFileDownloadService().DownloadAsync(
            repository,
            "/small.bin",
            1,
            destination);

        Assert.True(destination.Committed);
        Assert.False(destination.Aborted);
        Assert.True(destination.Disposed);
    }

    [Fact]
    public async Task CleanupFailuresDoNotReplaceOriginalDownloadFailure()
    {
        var originalFailure = new FileRangeContractException(
            FileRangeContractFailure.ContentVersionMismatch,
            "original version failure");
        var repository = new StubRepository();
        repository.EnqueueFailure(originalFailure);
        var destination = new RecordingDestination
        {
            AbortFailure = new IOException("abort failed"),
            DisposeFailure = new IOException("dispose failed"),
        };

        var thrown = await Assert.ThrowsAsync<FileRangeContractException>(() =>
            new SafeFileDownloadService().DownloadAsync(
                repository,
                "/small.bin",
                1,
                destination));

        Assert.Same(originalFailure, thrown);
        Assert.False(destination.Committed);
        Assert.True(destination.Aborted);
        Assert.True(destination.Disposed);
    }

    [Fact]
    public async Task CommitFailureAbortsAndPreservesOldTarget()
    {
        var commitFailure = new IOException("atomic replacement failed");
        var repository = new StubRepository();
        repository.EnqueueResult(Result(0, 1, 1, [1], version: null, safe: false));
        var destination = new RecordingDestination
        {
            CommitFailure = commitFailure,
            AbortFailure = new IOException("abort failed"),
            DisposeFailure = new IOException("dispose failed"),
        };

        var thrown = await Assert.ThrowsAsync<IOException>(() =>
            new SafeFileDownloadService().DownloadAsync(
                repository,
                "/small.bin",
                1,
                destination));

        Assert.Same(commitFailure, thrown);
        Assert.False(destination.Committed);
        Assert.True(destination.Aborted);
        Assert.True(destination.OldTargetPreserved);
        Assert.True(destination.Disposed);
    }

    [Fact]
    public async Task CleanupFailuresDoNotReplaceOriginalWriteFailure()
    {
        var writeFailure = new IOException("temporary write failed");
        var repository = new StubRepository();
        repository.EnqueueResult(Result(0, 1, 1, [1], version: null, safe: false));
        var destination = new RecordingDestination
        {
            WriteFailure = writeFailure,
            AbortFailure = new IOException("abort failed"),
            DisposeFailure = new IOException("dispose failed"),
        };

        var thrown = await Assert.ThrowsAsync<IOException>(() =>
            new SafeFileDownloadService().DownloadAsync(
                repository,
                "/small.bin",
                1,
                destination));

        Assert.Same(writeFailure, thrown);
        Assert.False(destination.Committed);
        Assert.True(destination.Aborted);
        Assert.True(destination.Disposed);
    }

    [Fact]
    public async Task CleanupDiagnosticContainsOnlyStageAndExceptionType()
    {
        const string sensitiveMessage = "do-not-log /private/path secret-token";
        var repository = new StubRepository();
        repository.EnqueueResult(Result(0, 1, 1, [1], version: null, safe: false));
        var destination = new RecordingDestination
        {
            DisposeFailure = new IOException(sensitiveMessage),
        };
        var diagnostics = new List<(string Stage, Type ExceptionType)>();
        var service = new SafeFileDownloadService(
            (stage, exceptionType) => diagnostics.Add((stage, exceptionType)));

        await service.DownloadAsync(
            repository,
            "/small.bin",
            1,
            destination);

        var diagnostic = Assert.Single(diagnostics);
        Assert.Equal("dispose", diagnostic.Stage);
        Assert.Equal(typeof(IOException), diagnostic.ExceptionType);
        Assert.DoesNotContain(sensitiveMessage, diagnostic.Stage, StringComparison.Ordinal);
        Assert.DoesNotContain("/small.bin", diagnostic.Stage, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ProgressIsMonotonicAndCompletesAtKnownTotal()
    {
        var total = (long)SafeFileDownloadService.ChunkSize + 2;
        var repository = new StubRepository();
        repository.EnqueueResult(Result(
            0,
            SafeFileDownloadService.ChunkSize,
            total,
            new byte[SafeFileDownloadService.ChunkSize],
            "\"version-1\"",
            safe: true));
        repository.EnqueueResult(Result(
            SafeFileDownloadService.ChunkSize,
            2,
            total,
            [1, 2],
            "\"version-1\"",
            safe: true));
        var values = new List<ForegroundTransferProgress>();

        await new SafeFileDownloadService().DownloadAsync(
            repository,
            "/large.bin",
            total,
            new RecordingDestination(),
            new InlineProgress<ForegroundTransferProgress>(values.Add));

        Assert.Equal(
            new long[] { 0, SafeFileDownloadService.ChunkSize, total },
            values.Select(value => value.BytesTransferred));
        Assert.All(values, value => Assert.Equal(total, value.TotalBytes));
    }

    [Fact]
    public async Task InvalidReturnedRangeAbortsBeforeWriting()
    {
        var repository = new StubRepository();
        repository.EnqueueResult(Result(1, 2, 2, [1, 2], version: null, safe: false));
        var destination = new RecordingDestination();

        await Assert.ThrowsAsync<FileRangeContractException>(() =>
            new SafeFileDownloadService().DownloadAsync(
                repository,
                "/bad.bin",
                2,
                destination));

        Assert.Empty(destination.Writes);
        Assert.True(destination.Aborted);
        Assert.False(destination.Committed);
    }

    private static FileRangeReadResult Result(
        long offset,
        long length,
        long total,
        byte[] bytes,
        string? version,
        bool safe) =>
        new(
            206,
            offset,
            length,
            offset,
            length,
            total,
            bytes.LongLength,
            bytes,
            version,
            safe);

    private sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }

    private sealed record RangeRequest(
        string RemotePath,
        long Offset,
        long Length,
        string? ExpectedVersion,
        long? ExpectedTotalLength);

    private sealed class StubRepository : IDsmRepository
    {
        private readonly Queue<object> _responses = new();

        public IReadOnlyList<RangeRequest> Requests => _requests;
        private readonly List<RangeRequest> _requests = [];

        public IReadOnlyList<AppModule> AvailableModules => [];

        public void EnqueueResult(FileRangeReadResult result) => _responses.Enqueue(result);
        public void EnqueueFailure(Exception exception) => _responses.Enqueue(exception);

        public Task<FileRangeReadResult> ReadFileRangeResultAsync(
            string remotePath,
            long offset,
            long length,
            string? expectedContentVersion = null,
            long? expectedTotalLength = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            _requests.Add(new RangeRequest(
                remotePath,
                offset,
                length,
                expectedContentVersion,
                expectedTotalLength));
            var response = _responses.Dequeue();
            return response is Exception exception
                ? Task.FromException<FileRangeReadResult>(exception)
                : Task.FromResult((FileRangeReadResult)response);
        }

        public Task<FilePage> ListFilesAsync(string path, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<FilePage> ListFilesAsync(string path, int offset, int limit, FileListOptions options, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<IReadOnlyList<FileItem>> SearchFilesAsync(string path, string query, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task CreateFolderAsync(string parentPath, string name, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task RenameAsync(string path, string newName, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task DeleteFilesAsync(IReadOnlyList<string> paths, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<NasSettingsSnapshot> LoadNasSettingsAsync(CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }

    private sealed class RecordingDestination : ITransactionalDownloadDestination
    {
        public List<byte[]> Writes { get; } = [];
        public bool Committed { get; private set; }
        public bool Aborted { get; private set; }
        public bool Disposed { get; private set; }
        public bool OldTargetPreserved => !Committed;
        public Action? OnWrite { get; init; }
        public Action<CancellationToken>? OnCommit { get; init; }
        public Exception? WriteFailure { get; init; }
        public Exception? CommitFailure { get; init; }
        public Exception? AbortFailure { get; init; }
        public Exception? DisposeFailure { get; init; }

        public ValueTask WriteAsync(ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (WriteFailure is not null)
            {
                return ValueTask.FromException(WriteFailure);
            }

            Writes.Add(bytes.ToArray());
            OnWrite?.Invoke();
            return ValueTask.CompletedTask;
        }

        public ValueTask CommitAsync(CancellationToken cancellationToken = default)
        {
            OnCommit?.Invoke(cancellationToken);
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
            return DisposeFailure is null
                ? ValueTask.CompletedTask
                : ValueTask.FromException(DisposeFailure);
        }
    }
}
