using System.Buffers.Binary;
using System.IO;
using System.Text;
using LanStash.App.Features.Files.Preview;
using LanStash.App.Features.Transfers;
using LanStash.Domain;
using Windows.Storage;

namespace LanStash.Tests.Files.Preview;

public sealed class FilePreviewViewModelTests
{
    [Fact]
    public async Task MD5PublishesOnlyForCurrentPreviewAndSwitchCancelsPreviousTask()
    {
        var profile = Guid.NewGuid();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new PreviewRepository(profile)
        {
            MD5Availability = new(true, 2),
            MD5Handler = async (_, token) =>
            {
                started.TrySetResult();
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
                return "never";
            },
        };
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());
        await model.OpenAsync(repository, profile, Item("first.txt", 0));

        var calculation = model.CalculateMD5Async();
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await model.OpenAsync(repository, profile, Item("second.txt", 0));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => calculation);
        Assert.Null(model.MD5Digest);
        Assert.False(model.IsCalculatingMD5);
        Assert.True(model.CanCalculateMD5);
    }

    [Fact]
    public async Task MD5ResultIsPublishedForMatchingRepositoryProfileAndPath()
    {
        var profile = Guid.NewGuid();
        var repository = new PreviewRepository(profile)
        {
            MD5Availability = new(true, 2),
            MD5Handler = (_, _) => Task.FromResult("0123456789abcdef0123456789abcdef"),
        };
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());
        await model.OpenAsync(repository, profile, Item("notes.txt", 0));

        var digest = await model.CalculateMD5Async();

        Assert.Equal("0123456789abcdef0123456789abcdef", digest);
        Assert.Equal(digest, model.MD5Digest);
        Assert.False(model.IsCalculatingMD5);
    }

    [Fact]
    public async Task UnknownUnsupportedAndEmptyNonTextUseZeroRequests()
    {
        var profile = Guid.NewGuid();
        var repository = new PreviewRepository(profile);
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());

        await model.OpenAsync(repository, profile, Item("unknown.jpg", -1));
        Assert.Equal(FilePreviewUnavailableReason.UnknownSize, model.Snapshot.UnavailableReason);
        await model.OpenAsync(repository, profile, Item("empty.mp4", 0));
        Assert.Equal(FilePreviewUnavailableReason.Empty, model.Snapshot.UnavailableReason);
        await model.OpenAsync(repository, profile, Item("archive.zip", 100));
        Assert.Equal(FilePreviewUnavailableReason.Unsupported, model.Snapshot.UnavailableReason);
        Assert.Empty(repository.Requests);
    }

    [Fact]
    public async Task RepositoryProfileMismatchUsesZeroRequests()
    {
        var repository = new PreviewRepository(Guid.NewGuid());
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());

        await model.OpenAsync(repository, Guid.NewGuid(), Item("notes.txt", 5));

        Assert.Equal(FilePreviewPhase.DetailsOnly, model.Snapshot.Phase);
        Assert.Empty(repository.Requests);
    }

    [Fact]
    public async Task TextReadsAtMostLimitPlusOneAndMarksTruncation()
    {
        var profile = Guid.NewGuid();
        var total = FilePreviewClassifier.TextPreviewByteLimit + 20L;
        var bytes = Enumerable.Repeat(
            (byte)'a',
            FilePreviewClassifier.TextPreviewByteLimit + 1).ToArray();
        var repository = new PreviewRepository(
            profile,
            request => Result(request, total, bytes));
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());

        await model.OpenAsync(repository, profile, Item("notes.txt", total));

        var request = Assert.Single(repository.Requests);
        Assert.Equal(FilePreviewClassifier.TextPreviewByteLimit + 1, request.Length);
        Assert.Equal(total, request.ExpectedTotalLength);
        Assert.Equal(FilePreviewPhase.Ready, model.Snapshot.Phase);
        Assert.True(model.Snapshot.IsTextTruncated);
        Assert.Equal(FilePreviewClassifier.TextPreviewByteLimit, model.Snapshot.Text!.Length);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Utf16WithBomIsDecoded(bool bigEndian)
    {
        var profile = Guid.NewGuid();
        var encoding = new UnicodeEncoding(bigEndian, true, true);
        var bytes = encoding.GetPreamble().Concat(encoding.GetBytes("测试 text")).ToArray();
        var repository = new PreviewRepository(
            profile,
            request => Result(request, bytes.Length, bytes));
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());

        await model.OpenAsync(repository, profile, Item("notes.txt", bytes.Length));

        Assert.Equal("测试 text", model.Snapshot.Text);
        Assert.False(model.Snapshot.IsTextTruncated);
    }

    [Fact]
    public async Task InvalidTextEncodingFailsWithoutExposingBytes()
    {
        var profile = Guid.NewGuid();
        var bytes = new byte[] { 0xC3, 0x28 };
        var repository = new PreviewRepository(
            profile,
            request => Result(request, bytes.Length, bytes));
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());

        await model.OpenAsync(repository, profile, Item("notes.txt", bytes.Length));

        Assert.Equal(FilePreviewPhase.Failed, model.Snapshot.Phase);
        Assert.Null(model.Snapshot.Text);
    }

    [Fact]
    public async Task TruncatedUtf8DropsOnlyAnIncompleteTail()
    {
        var profile = Guid.NewGuid();
        var prefix = Enumerable.Repeat(
            (byte)'a',
            FilePreviewClassifier.TextPreviewByteLimit - 1).ToArray();
        var bytes = prefix.Concat(new byte[] { 0xE4, 0xB8 }).Concat([(byte)'x']).ToArray();
        var total = FilePreviewClassifier.TextPreviewByteLimit + 8L;
        var requested = bytes[..(FilePreviewClassifier.TextPreviewByteLimit + 1)];
        var repository = new PreviewRepository(
            profile,
            request => Result(request, total, requested));
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());

        await model.OpenAsync(repository, profile, Item("notes.txt", total));

        Assert.Equal(FilePreviewPhase.Ready, model.Snapshot.Phase);
        Assert.True(model.Snapshot.IsTextTruncated);
        Assert.Equal(FilePreviewClassifier.TextPreviewByteLimit - 1, model.Snapshot.Text!.Length);
    }

    [Fact]
    public async Task LateTextFromOldGenerationCannotReplaceNewSelection()
    {
        var profile = Guid.NewGuid();
        var first = new TaskCompletionSource<FileRangeReadResult>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new PreviewRepository(profile, request =>
            request.Path.EndsWith("a.txt", StringComparison.Ordinal)
                ? first.Task
                : Task.FromResult(Result(request, 1, [(byte)'b'])));
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());

        var openingA = model.OpenAsync(repository, profile, Item("a.txt", 1));
        await repository.WaitForRequestsAsync(1);
        await model.OpenAsync(repository, profile, Item("b.txt", 1));
        first.SetResult(Result(repository.Requests[0], 1, [(byte)'a']));
        await openingA;

        Assert.Equal("b", model.Snapshot.Text);
        Assert.EndsWith("b.txt", model.Snapshot.Item!.Path, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RepositoryReplacementWithSameProfileRejectsOldResult()
    {
        var profile = Guid.NewGuid();
        var first = new TaskCompletionSource<FileRangeReadResult>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repositoryA = new PreviewRepository(profile, _ => first.Task);
        var repositoryB = new PreviewRepository(
            profile,
            request => Result(request, 1, [(byte)'b']));
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());

        var openingA = model.OpenAsync(repositoryA, profile, Item("a.txt", 1));
        await repositoryA.WaitForRequestsAsync(1);
        await model.OpenAsync(repositoryB, profile, Item("b.txt", 1));
        first.SetResult(Result(repositoryA.Requests[0], 1, [(byte)'a']));
        await openingA;

        Assert.Equal("b", model.Snapshot.Text);
        Assert.EndsWith("b.txt", model.Snapshot.Item!.Path, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ReplacingArtifactDisposesPreviousOwnedArtifact()
    {
        var profile = Guid.NewGuid();
        var repository = new PreviewRepository(profile);
        var store = new ArtifactStoreStub();
        using var model = new FilePreviewViewModel(store);

        await model.OpenAsync(repository, profile, Item("a.jpg", 10));
        var first = Assert.Single(store.Artifacts);
        await model.OpenAsync(repository, profile, Item("unsupported.bin", 10));

        Assert.True(first.IsDisposed);
    }

    [Fact]
    public async Task ImageArtifactCarriesMetadataFromReader()
    {
        var profile = Guid.NewGuid();
        var repository = new PreviewRepository(profile);
        var store = new ArtifactStoreStub();
        var capturedAt = new DateTimeOffset(2026, 8, 10, 9, 30, 0, TimeSpan.Zero);
        var metadataReader = new MetadataReaderStub(
            new FilePreviewMediaMetadata(
                4032,
                3024,
                capturedAt,
                "Contoso",
                "Photon One"));
        using var model = new FilePreviewViewModel(store, metadataReader);

        await model.OpenAsync(repository, profile, Item("photo.jpg", 10));

        Assert.Equal(FilePreviewPhase.Ready, model.Snapshot.Phase);
        Assert.Equal(4032, model.Snapshot.MediaMetadata?.PixelWidth);
        Assert.Equal(3024, model.Snapshot.MediaMetadata?.PixelHeight);
        Assert.Equal(capturedAt, model.Snapshot.MediaMetadata?.CapturedAt);
        Assert.Equal("Contoso", model.Snapshot.MediaMetadata?.CameraManufacturer);
        Assert.Equal("Photon One", model.Snapshot.MediaMetadata?.CameraModel);
        Assert.Equal(FilePreviewKind.Image, Assert.Single(metadataReader.RequestedKinds));
    }

    [Fact]
    public async Task ImageMetadataFailureKeepsPreviewReadyWithoutMetadata()
    {
        var profile = Guid.NewGuid();
        var repository = new PreviewRepository(profile);
        var store = new ArtifactStoreStub();
        var metadataReader = new MetadataReaderStub(
            metadata: null,
            error: new IOException("metadata unavailable"));
        using var model = new FilePreviewViewModel(store, metadataReader);

        await model.OpenAsync(repository, profile, Item("photo.jpg", 10));

        Assert.Equal(FilePreviewPhase.Ready, model.Snapshot.Phase);
        Assert.NotNull(model.Snapshot.Artifact);
        Assert.Null(model.Snapshot.MediaMetadata);
    }

    [Fact]
    public async Task LargeMediaRequiresStrongVersionAndEveryLaterRangeUsesIt()
    {
        var profile = Guid.NewGuid();
        var total = StrictRangeReadSession.MaximumRangeLength + 32L;
        var repository = new PreviewRepository(profile, request =>
        {
            var bytes = new byte[checked((int)request.Length)];
            return Result(request, total, bytes, "\"stable\"", segmented: true);
        });
        using var session = new StrictRangeReadSession(repository, "/share/movie.mp4", total);

        await session.InitializeAsync(CancellationToken.None);
        var bytes = await session.ReadAsync(
            StrictRangeReadSession.MaximumRangeLength,
            32,
            CancellationToken.None);

        Assert.Equal(32, bytes.Length);
        Assert.Equal(2, repository.Requests.Count);
        Assert.Null(repository.Requests[0].ExpectedContentVersion);
        Assert.Equal("\"stable\"", repository.Requests[1].ExpectedContentVersion);
        Assert.All(repository.Requests, request =>
            Assert.InRange(request.Length, 1, StrictRangeReadSession.MaximumRangeLength));
    }

    [Fact]
    public async Task LargeMediaWithoutStrongVersionFailsBeforePlayerIsReady()
    {
        var profile = Guid.NewGuid();
        var total = StrictRangeReadSession.MaximumRangeLength + 1L;
        var repository = new PreviewRepository(profile, request =>
            Result(
                request,
                total,
                new byte[checked((int)request.Length)],
                version: null,
                segmented: false));
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());

        await model.OpenAsync(repository, profile, Item("movie.mp4", total));

        Assert.Equal(FilePreviewPhase.Failed, model.Snapshot.Phase);
        Assert.Null(model.Snapshot.Media);
        Assert.Single(repository.Requests);
    }

    [Fact]
    public async Task VideoRangePreviewCarriesWhitelistedIsoBmffMetadataWithoutExtraReads()
    {
        var profile = Guid.NewGuid();
        var bytes = BuildIsoBmffVideo(
            width: 1920,
            height: 1080,
            timescale: 1000,
            duration: 123_456);
        var repository = new PreviewRepository(
            profile,
            request => Result(request, bytes.Length, bytes));
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());

        await model.OpenAsync(repository, profile, Item("clip.mp4", bytes.Length));

        Assert.Equal(FilePreviewPhase.Ready, model.Snapshot.Phase);
        Assert.NotNull(model.Snapshot.Media);
        Assert.Equal(1920, model.Snapshot.MediaMetadata?.PixelWidth);
        Assert.Equal(1080, model.Snapshot.MediaMetadata?.PixelHeight);
        Assert.Equal(TimeSpan.FromMilliseconds(123_456), model.Snapshot.MediaMetadata?.Duration);
        Assert.Null(model.Snapshot.MediaMetadata?.CameraManufacturer);
        Assert.Single(repository.Requests);
    }

    [Fact]
    public async Task SmallMediaUsesOneWholeFileReadWithoutRequiringEtag()
    {
        var profile = Guid.NewGuid();
        var total = 128L;
        var repository = new PreviewRepository(profile, request =>
            Result(request, total, new byte[checked((int)request.Length)]));
        using var session = new StrictRangeReadSession(repository, "/share/sound.mp3", total);

        await session.InitializeAsync(CancellationToken.None);
        var tail = await session.ReadAsync(120, 8, CancellationToken.None);

        Assert.Equal(8, tail.Length);
        Assert.Single(repository.Requests);
        Assert.Equal(total, repository.Requests[0].Length);
    }

    [Fact]
    public async Task DisposingMediaSessionCancelsAnInFlightSeekRange()
    {
        var profile = Guid.NewGuid();
        var total = StrictRangeReadSession.MaximumRangeLength + 64L;
        var laterRequestStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new PreviewRepository(profile, request =>
        {
            if (request.Offset == 0)
            {
                return Task.FromResult(Result(
                    request,
                    total,
                    new byte[checked((int)request.Length)],
                    "\"stable\"",
                    segmented: true));
            }
            laterRequestStarted.SetResult();
            return WaitForCancellationAsync(request.CancellationToken);
        });
        var session = new StrictRangeReadSession(repository, "/share/movie.mp4", total);
        await session.InitializeAsync(CancellationToken.None);
        var reading = session.ReadAsync(
            StrictRangeReadSession.MaximumRangeLength,
            32,
            CancellationToken.None);
        await laterRequestStarted.Task;

        session.Dispose();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => reading);
    }

    [Fact]
    public async Task NonCooperativeRangeCompletingAfterSeekCannotAdvanceNewPosition()
    {
        var profile = Guid.NewGuid();
        var total = StrictRangeReadSession.MaximumRangeLength + 128L;
        var delayed = new TaskCompletionSource<FileRangeReadResult>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new PreviewRepository(profile, request =>
            request.Offset == 0
                ? Task.FromResult(Result(
                    request,
                    total,
                    new byte[checked((int)request.Length)],
                    "\"stable\"",
                    segmented: true))
                : delayed.Task);
        using var session = new StrictRangeReadSession(repository, "/share/movie.mp4", total);
        await session.InitializeAsync(CancellationToken.None);
        using var cursor = new StrictRangeReadCursor(
            session,
            StrictRangeReadSession.MaximumRangeLength);

        var staleRead = cursor.ReadAsync(16, CancellationToken.None);
        await repository.WaitForRequestsAsync(2);
        cursor.Seek(checked((ulong)StrictRangeReadSession.MaximumRangeLength + 32));
        delayed.SetResult(Result(repository.Requests[1], total, new byte[16], "\"stable\"", true));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => staleRead);
        Assert.Equal(
            checked((ulong)StrictRangeReadSession.MaximumRangeLength + 32),
            cursor.Position);
    }

    [Fact]
    public async Task CloneHasIndependentCursorWhileSharingVersionedSession()
    {
        var profile = Guid.NewGuid();
        var total = StrictRangeReadSession.MaximumRangeLength + 64L;
        var repository = new PreviewRepository(profile, request => Result(
            request,
            total,
            new byte[checked((int)request.Length)],
            "\"stable\"",
            segmented: true));
        using var session = new StrictRangeReadSession(repository, "/share/movie.mp4", total);
        await session.InitializeAsync(CancellationToken.None);
        using var original = new StrictRangeReadCursor(
            session,
            StrictRangeReadSession.MaximumRangeLength);
        using var clone = original.Clone();

        await original.ReadAsync(8, CancellationToken.None);

        Assert.Equal(
            checked((ulong)StrictRangeReadSession.MaximumRangeLength + 8),
            original.Position);
        Assert.Equal(checked((ulong)StrictRangeReadSession.MaximumRangeLength), clone.Position);
    }

    [Fact]
    public async Task NewReadInvalidatesNonCooperativeOldReadBeforeAdvancingCursor()
    {
        var profile = Guid.NewGuid();
        var total = StrictRangeReadSession.MaximumRangeLength + 64L;
        var first = new TaskCompletionSource<FileRangeReadResult>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var second = new TaskCompletionSource<FileRangeReadResult>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var laterRequest = 0;
        var repository = new PreviewRepository(profile, request =>
        {
            if (request.Offset == 0)
            {
                return Task.FromResult(Result(
                    request,
                    total,
                    new byte[checked((int)request.Length)],
                    "\"stable\"",
                    true));
            }
            return Interlocked.Increment(ref laterRequest) == 1 ? first.Task : second.Task;
        });
        using var session = new StrictRangeReadSession(repository, "/share/movie.mp4", total);
        await session.InitializeAsync(CancellationToken.None);
        using var cursor = new StrictRangeReadCursor(
            session,
            StrictRangeReadSession.MaximumRangeLength);

        var stale = cursor.ReadAsync(8, CancellationToken.None);
        await repository.WaitForRequestsAsync(2);
        var current = cursor.ReadAsync(8, CancellationToken.None);
        first.SetResult(Result(repository.Requests[1], total, new byte[8], "\"stable\"", true));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => stale);
        await repository.WaitForRequestsAsync(3);
        second.SetResult(Result(repository.Requests[2], total, new byte[8], "\"stable\"", true));

        Assert.Equal(8, (await current).Length);
        Assert.Equal(
            checked((ulong)StrictRangeReadSession.MaximumRangeLength + 8),
            cursor.Position);
    }

    [Fact]
    public async Task DisposedCursorRejectsLateNonCooperativeCompletionWithoutMoving()
    {
        var profile = Guid.NewGuid();
        var total = StrictRangeReadSession.MaximumRangeLength + 32L;
        var delayed = new TaskCompletionSource<FileRangeReadResult>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repository = new PreviewRepository(profile, request =>
            request.Offset == 0
                ? Task.FromResult(Result(
                    request,
                    total,
                    new byte[checked((int)request.Length)],
                    "\"stable\"",
                    true))
                : delayed.Task);
        using var session = new StrictRangeReadSession(repository, "/share/movie.mp4", total);
        await session.InitializeAsync(CancellationToken.None);
        var cursor = new StrictRangeReadCursor(
            session,
            StrictRangeReadSession.MaximumRangeLength);

        var stale = cursor.ReadAsync(8, CancellationToken.None);
        await repository.WaitForRequestsAsync(2);
        cursor.Dispose();
        delayed.SetResult(Result(repository.Requests[1], total, new byte[8], "\"stable\"", true));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => stale);
        Assert.Equal(checked((ulong)StrictRangeReadSession.MaximumRangeLength), cursor.Position);
    }

    [Fact]
    public async Task SaveCopyTargetIsFrozenToPreviewAndRejectedAfterSelectionChanges()
    {
        var profile = Guid.NewGuid();
        var repository = new PreviewRepository(
            profile,
            request => Result(request, 1, [(byte)'a']));
        using var model = new FilePreviewViewModel(new ArtifactStoreStub());
        var itemA = Item("a.txt", 1);
        var itemB = Item("b.txt", 1);
        await model.OpenAsync(repository, profile, itemA);

        Assert.True(model.TryGetSaveCopyTarget(itemA, out var target));
        Assert.Equal(itemA.Path, target!.Item.Path);
        Assert.False(model.TryGetSaveCopyTarget(itemB, out _));
    }

    private static FileItem Item(string name, long size) => new(
        $"/share/{name}", name, false, size, null, null, false, false);

    private static FileRangeReadResult Result(
        RangeRequest request,
        long total,
        byte[] bytes,
        string? version = null,
        bool segmented = false) => new(
            206,
            request.Offset,
            request.Length,
            request.Offset,
            request.Length,
            total,
            bytes.LongLength,
            bytes,
            version,
            segmented);

    private static async Task<FileRangeReadResult> WaitForCancellationAsync(
        CancellationToken cancellationToken)
    {
        await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
        throw new InvalidOperationException();
    }

    private static byte[] BuildIsoBmffVideo(
        int width,
        int height,
        uint timescale,
        uint duration)
    {
        var mvhdPayload = new byte[20];
        BinaryPrimitives.WriteUInt32BigEndian(mvhdPayload.AsSpan(12), timescale);
        BinaryPrimitives.WriteUInt32BigEndian(mvhdPayload.AsSpan(16), duration);

        var tkhdPayload = new byte[84];
        BinaryPrimitives.WriteUInt32BigEndian(
            tkhdPayload.AsSpan(76),
            checked((uint)width * 65_536u));
        BinaryPrimitives.WriteUInt32BigEndian(
            tkhdPayload.AsSpan(80),
            checked((uint)height * 65_536u));

        var hdlrPayload = new byte[12];
        Encoding.ASCII.GetBytes("vide", hdlrPayload.AsSpan(8));

        return Box(
            "ftyp",
            Encoding.ASCII.GetBytes("isom0000"))
            .Concat(Box(
                "moov",
                Box("mvhd", mvhdPayload)
                    .Concat(Box(
                        "trak",
                        Box("tkhd", tkhdPayload)
                            .Concat(Box("mdia", Box("hdlr", hdlrPayload)))
                            .ToArray()))
                    .ToArray()))
            .ToArray();
    }

    private static byte[] Box(string type, byte[] payload)
    {
        var bytes = new byte[payload.Length + 8];
        BinaryPrimitives.WriteUInt32BigEndian(
            bytes,
            checked((uint)bytes.Length));
        Encoding.ASCII.GetBytes(type, bytes.AsSpan(4));
        payload.CopyTo(bytes.AsSpan(8));
        return bytes;
    }

    private sealed record RangeRequest(
        string Path,
        long Offset,
        long Length,
        string? ExpectedContentVersion,
        long? ExpectedTotalLength,
        CancellationToken CancellationToken);

    private sealed class PreviewRepository : IFilePreviewRepository
    {
        private readonly Func<RangeRequest, Task<FileRangeReadResult>> _handler;

        public PreviewRepository(
            Guid profileId,
            Func<RangeRequest, FileRangeReadResult>? handler = null)
            : this(
                profileId,
                handler is null
                    ? request => Task.FromException<FileRangeReadResult>(new InvalidOperationException())
                    : request => Task.FromResult(handler(request)))
        {
        }

        public PreviewRepository(
            Guid profileId,
            Func<RangeRequest, Task<FileRangeReadResult>> handler)
        {
            ProfileId = profileId;
            _handler = handler;
        }

        public Guid ProfileId { get; }
        public List<RangeRequest> Requests { get; } = [];

        public Task<FileRangeReadResult> ReadFileRangeResultAsync(
            string remotePath,
            long offset,
            long length,
            string? expectedContentVersion = null,
            long? expectedTotalLength = null,
            CancellationToken cancellationToken = default)
        {
            var request = new RangeRequest(
                remotePath,
                offset,
                length,
                expectedContentVersion,
                expectedTotalLength,
                cancellationToken);
            Requests.Add(request);
            return _handler(request);
        }

        public async Task WaitForRequestsAsync(int count)
        {
            for (var attempt = 0; attempt < 100 && Requests.Count < count; attempt++)
            {
                await Task.Yield();
            }
            Assert.True(Requests.Count >= count);
        }

        public FileTextEditAvailability GetTextEditAvailability() => new(
            CanEdit: false,
            CanFormat: false,
            SupportedExtensions: Array.Empty<string>());

        public Task<string> DownloadTextContentAsync(
            string path,
            long maxBytes,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<MutationResult> SaveTextContentAsync(
            string path,
            string content,
            string originalContent,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<string> FormatTextContentAsync(
            string text,
            TextFormatKind kind,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public FileMD5Availability MD5Availability { get; set; } = new(false);
        public Func<string, CancellationToken, Task<string>> MD5Handler { get; set; } =
            (_, _) => throw new NotSupportedException();

        public Task<string> CalculateMD5Async(
            string path,
            CancellationToken cancellationToken = default) =>
            MD5Handler(path, cancellationToken);
    }

    private sealed class ArtifactStoreStub : IFilePreviewArtifactStore
    {
        public List<ArtifactStub> Artifacts { get; } = [];

        public Task<IFilePreviewArtifact> PrepareAsync(
            IFileRangeReader repository,
            FileItem item,
            IProgress<ForegroundTransferProgress>? progress,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var artifact = new ArtifactStub();
            Artifacts.Add(artifact);
            progress?.Report(new ForegroundTransferProgress(item.Size, item.Size));
            return Task.FromResult<IFilePreviewArtifact>(artifact);
        }
    }

    private sealed class ArtifactStub : IFilePreviewArtifact
    {
        public StorageFile? File => null;
        public string Path => string.Empty;
        public bool IsDisposed { get; private set; }
        public ValueTask DisposeAsync()
        {
            IsDisposed = true;
            return ValueTask.CompletedTask;
        }
    }

    private sealed class MetadataReaderStub : IFilePreviewMetadataReader
    {
        private readonly FilePreviewMediaMetadata? _metadata;
        private readonly Exception? _error;

        public MetadataReaderStub(
            FilePreviewMediaMetadata? metadata,
            Exception? error = null)
        {
            _metadata = metadata;
            _error = error;
        }

        public List<FilePreviewKind> RequestedKinds { get; } = [];

        public Task<FilePreviewMediaMetadata?> ReadAsync(
            IFilePreviewArtifact artifact,
            FilePreviewKind kind,
            CancellationToken cancellationToken)
        {
            RequestedKinds.Add(kind);
            if (_error is not null)
            {
                return Task.FromException<FilePreviewMediaMetadata?>(_error);
            }
            return Task.FromResult(_metadata);
        }
    }
}
