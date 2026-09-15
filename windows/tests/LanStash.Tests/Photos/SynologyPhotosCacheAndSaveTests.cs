using LanStash.App.Features.Photos.Synology;
using LanStash.App.Features.Transfers;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class SynologyPhotosCacheAndSaveTests
{
    [Fact]
    public async Task ConcurrentSubscribersShareOneThumbnailAndOneCancellationDoesNotCancelTheOther()
    {
        var repository = new SynologyPhotosTestRepository();
        var pending = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        repository.Thumbnail = (_, _) => { calls++; return pending.Task; };
        using var cache = Cache(repository);
        using var cancellation = new CancellationTokenSource();
        var first = cache.GetAsync(repository.Photo(), cancellation.Token);
        var second = cache.GetAsync(repository.Photo());
        cancellation.Cancel(); await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
        pending.SetResult([1, 2]); Assert.Equal(2, (await second).Length);
        Assert.Equal(1, calls);
        Assert.Equal(2, (await cache.GetAsync(repository.Photo())).Length); Assert.Equal(1, calls);
    }

    [Fact]
    public async Task ClearRejectsLateDecodeAndStartsANewSessionScopedRequest()
    {
        var repository = new SynologyPhotosTestRepository();
        var pending = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        repository.Thumbnail = (_, _) => pending.Task;
        using var cache = Cache(repository);
        var first = cache.GetAsync(repository.Photo()); cache.Clear(); pending.SetResult([1]);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
        repository.Thumbnail = (_, _) => Task.FromResult(new byte[] { 2 });
        Assert.Equal(new byte[] { 2 }, await cache.GetAsync(repository.Photo()));
    }

    [Fact]
    public async Task ThumbnailQueueNeverExceedsFourConcurrentNetworkRequests()
    {
        var repository = new SynologyPhotosTestRepository();
        var release = new TaskCompletionSource<byte[]>(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = 0;
        repository.Thumbnail = (_, _) => { Interlocked.Increment(ref started); return release.Task; };
        using var cache = Cache(repository);
        var requests = Enumerable.Range(1, 12).Select(id => cache.GetAsync(repository.Photo(id))).ToArray();
        Assert.Equal(SynologyPhotoThumbnailCache<byte[]>.MaximumConcurrency, started);
        release.SetResult([1]); await Task.WhenAll(requests);
    }

    [Fact]
    public async Task DecodedMemoryBudgetEvictsBeforeRetainingAnotherLargeThumbnail()
    {
        var repository = new SynologyPhotosTestRepository(); var calls = 0;
        repository.Thumbnail = (_, _) => { calls++; return Task.FromResult(new byte[] { 1 }); };
        using var cache = new SynologyPhotoThumbnailCache<byte[]>(repository,
            (bytes, _) => Task.FromResult(new SynologyPhotoDecodedThumbnail<byte[]>(bytes, 20L * 1024 * 1024)));
        await cache.GetAsync(repository.Photo(1)); await cache.GetAsync(repository.Photo(2)); await cache.GetAsync(repository.Photo(1));
        Assert.Equal(3, calls);
    }

    [Fact]
    public async Task CacheIdentityIncludesRevisionAndRejectsAnotherAccount()
    {
        var repository = new SynologyPhotosTestRepository(); var calls = 0;
        repository.Thumbnail = (_, _) => { calls++; return Task.FromResult(new byte[] { 1 }); };
        using var cache = Cache(repository); var original = repository.Photo();
        await cache.GetAsync(original);
        await cache.GetAsync(original with { Thumbnail = original.Thumbnail! with { Revision = "updated" } });
        await Assert.ThrowsAsync<SynologyPhotoException>(() => cache.GetAsync(original with { Id = original.Id with { ProfileId = Guid.NewGuid() } }));
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task SaveCommitsOnlyAfterExactLengthAndRemovesThePrivateTemporaryFile()
    {
        var repository = new SynologyPhotosTestRepository(); var directory = NewDirectory();
        var destination = new Destination();
        try
        {
            await new SynologyPhotoSaveService().SaveAsync(repository, repository.Photo(), directory, () => Task.FromResult<ITransactionalDownloadDestination>(destination));
            Assert.True(destination.Committed); Assert.Equal(8, destination.Written); Assert.True(destination.Disposed);
            Assert.Empty(Directory.EnumerateFileSystemEntries(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task IncompleteOriginalNeverOpensTheUserDestination()
    {
        var repository = new SynologyPhotosTestRepository { Download = (_, path, token) => File.WriteAllBytesAsync(path, new byte[3], token) };
        var directory = NewDirectory(); var opened = false;
        try
        {
            await Assert.ThrowsAsync<SynologyPhotoException>(() => new SynologyPhotoSaveService().SaveAsync(repository, repository.Photo(), directory, () =>
            { opened = true; return Task.FromResult<ITransactionalDownloadDestination>(new Destination()); }));
            Assert.False(opened); Assert.Empty(Directory.EnumerateFileSystemEntries(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public async Task DestinationFailureAbortsWithoutReplacingExistingContent()
    {
        var repository = new SynologyPhotosTestRepository(); var directory = NewDirectory();
        var destination = new Destination { FailWrite = true };
        try
        {
            await Assert.ThrowsAsync<IOException>(() => new SynologyPhotoSaveService().SaveAsync(repository, repository.Photo(), directory,
                () => Task.FromResult<ITransactionalDownloadDestination>(destination)));
            Assert.True(destination.Aborted); Assert.False(destination.Committed); Assert.True(destination.Disposed);
            Assert.Empty(Directory.EnumerateFileSystemEntries(directory));
        }
        finally { Directory.Delete(directory, true); }
    }

    private static SynologyPhotoThumbnailCache<byte[]> Cache(SynologyPhotosTestRepository repository) =>
        new(repository, (bytes, _) => Task.FromResult(new SynologyPhotoDecodedThumbnail<byte[]>(bytes, bytes.Length)));
    private static string NewDirectory()
    { var path = Path.Combine(Path.GetTempPath(), $"synthetic-photos-{Guid.NewGuid():N}"); Directory.CreateDirectory(path); return path; }
    private sealed class Destination : ITransactionalDownloadDestination
    {
        public bool FailWrite { get; init; }
        public bool Committed { get; private set; }
        public bool Aborted { get; private set; }
        public bool Disposed { get; private set; }
        public long Written { get; private set; }
        public ValueTask WriteAsync(ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken = default)
        { if (FailWrite) throw new IOException(); Written += bytes.Length; return ValueTask.CompletedTask; }
        public ValueTask CommitAsync(CancellationToken cancellationToken = default) { Committed = true; return ValueTask.CompletedTask; }
        public ValueTask AbortAsync(CancellationToken cancellationToken = default) { Aborted = true; return ValueTask.CompletedTask; }
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
}
