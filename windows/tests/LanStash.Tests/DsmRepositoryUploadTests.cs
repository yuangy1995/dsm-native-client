using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class DsmRepositoryUploadTests
{
    [Fact]
    public async Task AcceptedUploadIsConfirmedOnlyAfterPaginatedSizeReadback()
    {
        var api = new UploadApiClient(
            new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            new Dictionary<int, JsonObject>
            {
                [0] = Page(0, 2, Item("/projects/other.bin", "other.bin", 7)),
                [1] = Page(1, 2, Item("/projects/upload.bin", "upload.bin", 4)),
            });
        var repository = Repository(api);

        var result = await repository.UploadFileAsync(
            new FileUploadRequest(new MemoryStream([1, 2, 3, 4]), 4, "/projects", "upload.bin"));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.True(result.Submitted);
        Assert.Equal([0, 1], api.ReadbackOffsets);
        Assert.Equal(1, api.UploadCount);
    }

    [Fact]
    public async Task SuccessEnvelopeWithReadbackMismatchRemainsUnverified()
    {
        var api = new UploadApiClient(
            new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            new Dictionary<int, JsonObject>
            {
                [0] = Page(0, 1, Item("/projects/upload.bin", "upload.bin", 3)),
            });

        var result = await Repository(api).UploadFileAsync(
            new FileUploadRequest(new MemoryStream([1, 2, 3, 4]), 4, "/projects", "upload.bin"));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.True(result.RequiresRefresh);
        Assert.Equal(1, result.Counts.Unknown);
        Assert.Equal(1, api.UploadCount);
    }

    [Fact]
    public async Task ConfirmedFailureDoesNotReadBackOrReplay()
    {
        var api = new UploadApiClient(new FileUploadTransportResult(
            FileUploadTransportStatus.ConfirmedFailure,
            MutationErrorCategory.Conflict,
            "file.upload.dsm-1805"));

        var result = await Repository(api).UploadFileAsync(
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "upload.bin"));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, result.ErrorCategory);
        Assert.Empty(api.ReadbackOffsets);
        Assert.Equal(1, api.UploadCount);
    }

    [Fact]
    public async Task CancellationDuringSuccessReadbackKeepsSubmittedResultUnknown()
    {
        var api = new UploadApiClient(
            new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            readbackError: new OperationCanceledException());

        var result = await Repository(api).UploadFileAsync(
            new FileUploadRequest(new MemoryStream([]), 0, "/projects", "empty.bin"));

        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, result.Status);
        Assert.True(result.Submitted);
        Assert.True(result.RequiresRefresh);
        Assert.Equal(1, result.Counts.Unknown);
        Assert.Equal(1, api.UploadCount);
    }

    [Fact]
    public async Task DirectoryWithSameNameAndSizeDoesNotConfirmUpload()
    {
        var directory = Item("/projects/empty.bin", "empty.bin", 0);
        directory["isdir"] = true;
        var api = new UploadApiClient(
            new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            new Dictionary<int, JsonObject> { [0] = Page(0, 1, directory) });

        var result = await Repository(api).UploadFileAsync(
            new FileUploadRequest(new MemoryStream([]), 0, "/projects", "empty.bin"));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(1, api.UploadCount);
    }

    [Fact]
    public async Task EmptyReadbackPageWithRemainingTotalIsUnverifiedWithoutLooping()
    {
        var api = new UploadApiClient(
            new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            new Dictionary<int, JsonObject> { [0] = Page(0, 10) });

        var result = await Repository(api).UploadFileAsync(
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "upload.bin"));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.Equal([0], api.ReadbackOffsets);
        Assert.Equal(1, api.UploadCount);
    }

    [Fact]
    public async Task MalformedReadbackPageCannotEscapeSubmittedState()
    {
        var malformed = Item("/projects/other.bin", "other.bin", 1);
        malformed["additional"] = new JsonObject
        {
            ["time"] = new JsonObject { ["mtime"] = long.MaxValue },
        };
        var api = new UploadApiClient(
            new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            new Dictionary<int, JsonObject> { [0] = Page(0, 1, malformed) });

        var result = await Repository(api).UploadFileAsync(
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "upload.bin"));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.True(result.Submitted);
        Assert.True(result.RequiresRefresh);
        Assert.Equal(1, result.Counts.Unknown);
        Assert.Equal(1, api.UploadCount);
    }

    [Theory]
    [InlineData(typeof(OverflowException))]
    [InlineData(typeof(InvalidOperationException))]
    [InlineData(typeof(FormatException))]
    public async Task ReadbackParserOrOffsetFailuresRemainUnverified(Type exceptionType)
    {
        var error = (Exception)Activator.CreateInstance(exceptionType)!;
        var api = new UploadApiClient(
            new FileUploadTransportResult(FileUploadTransportStatus.Accepted),
            readbackError: error);

        var result = await Repository(api).UploadFileAsync(
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "upload.bin"));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.True(result.Submitted);
        Assert.Equal(1, result.Counts.Unknown);
        Assert.Equal(1, api.UploadCount);
    }

    [Theory]
    [InlineData(
        FileUploadTransportStatus.CancelledBeforeSubmission,
        MutationResultStatus.CancelledBeforeSubmission,
        false)]
    [InlineData(
        FileUploadTransportStatus.CancellationRequestedAfterSubmission,
        MutationResultStatus.CancellationRequestedAfterSubmission,
        true)]
    [InlineData(
        FileUploadTransportStatus.SubmittedButUnverified,
        MutationResultStatus.SubmittedButUnverified,
        true)]
    public async Task SubmissionBoundaryMapsWithoutReplay(
        FileUploadTransportStatus transportStatus,
        MutationResultStatus expectedStatus,
        bool submitted)
    {
        var api = new UploadApiClient(new FileUploadTransportResult(transportStatus));

        var result = await Repository(api).UploadFileAsync(
            new FileUploadRequest(new MemoryStream([1]), 1, "/projects", "upload.bin"));

        Assert.Equal(expectedStatus, result.Status);
        Assert.Equal(submitted, result.Submitted);
        Assert.Equal(1, api.UploadCount);
        Assert.Empty(api.ReadbackOffsets);
    }

    private static DsmRepository Repository(UploadApiClient api)
    {
        var profileId = Guid.Parse("11111111-1111-1111-1111-111111111111");
        var capabilities = new[]
        {
            new ApiCapability("SYNO.FileStation.Upload", "entry.cgi", 1, 2, "MULTIPART"),
            new ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2, "FORM"),
        }.ToDictionary(item => item.Name, StringComparer.Ordinal);
        return new DsmRepository(
            new NasProfile(profileId, "synthetic", "nas.invalid", 5001, "tester"),
            new DsmSession(profileId, "synthetic-sid", null, null),
            api,
            capabilities);
    }

    private static JsonObject Page(int offset, int total, params JsonObject[] items) => new()
    {
        ["offset"] = offset,
        ["total"] = total,
        ["files"] = new JsonArray(items.Select(item => (JsonNode)item).ToArray()),
    };

    private static JsonObject Item(string path, string name, long size) => new()
    {
        ["path"] = path,
        ["name"] = name,
        ["isdir"] = false,
        ["size"] = size,
    };

    private sealed class UploadApiClient(
        FileUploadTransportResult uploadResult,
        IReadOnlyDictionary<int, JsonObject>? pages = null,
        Exception? readbackError = null) : IDsmApiClient
    {
        public int UploadCount { get; private set; }
        public List<int> ReadbackOffsets { get; } = [];

        public Task<FileUploadTransportResult> UploadFileAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            FileUploadRequest request,
            IProgress<long>? progress = null,
            CancellationToken cancellationToken = default)
        {
            UploadCount++;
            return Task.FromResult(uploadResult);
        }

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            Assert.Equal("SYNO.FileStation.List", capability.Name);
            Assert.Equal("list", method);
            if (readbackError is not null)
            {
                return Task.FromException<JsonObject>(readbackError);
            }
            var offset = int.Parse(parameters!["offset"], System.Globalization.CultureInfo.InvariantCulture);
            ReadbackOffsets.Add(offset);
            return Task.FromResult(pages![offset].DeepClone().AsObject());
        }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.invalid");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(
            NasProfile profile,
            string password,
            string? otp,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(
            NasProfile profile,
            DsmSession session,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string remotePath,
            long offset,
            long length,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
