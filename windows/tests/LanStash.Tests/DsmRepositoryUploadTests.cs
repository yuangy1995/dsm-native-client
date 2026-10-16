using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests;

public sealed class DsmRepositoryUploadTests
{
    [Fact]
    public async Task AcceptedUploadIsConfirmedOnlyAfterPaginatedSizeAndContentReadback()
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
    [InlineData(typeof(IOException))]
    [InlineData(typeof(InvalidDataException))]
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

    [Fact]
    public async Task SameSizeWrongContentStaysUnknownAndReopenDoesNotResubmit()
    {
        var api = new UploadApiClient(new(FileUploadTransportStatus.Accepted)) { CorruptReadback = true };
        var repository = Repository(api);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await repository.UploadFileAsync(Request())).Status);
        Assert.Equal(MutationErrorCategory.Conflict, (await Repository(api).UploadFileAsync(Request())).ErrorCategory);
        Assert.Equal(1, api.UploadCount);
        api.CorruptReadback = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await Repository(api).ReviewFileUploadAsync("/projects", "upload.bin"))!.Status);
        Assert.Equal(1, api.UploadCount);
        Assert.Null(await repository.ReviewFileUploadAsync("/projects", "upload.bin"));
    }

    [Fact]
    public async Task LostReceiptCannotBeReplacedByMatchingContent()
    {
        var api = new UploadApiClient(new(FileUploadTransportStatus.SubmittedButUnverified));
        var repository = Repository(api);
        var request = Request();
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await repository.UploadFileAsync(request)).Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await repository.ReviewFileUploadAsync("/projects", "upload.bin"))!.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await repository.UploadFileAsync(request)).Status);
        Assert.Equal(1, api.UploadCount); Assert.Empty(api.Ranges); Assert.Empty(api.ReadbackOffsets);
    }

    [Fact]
    public async Task AcceptedUploadReadFailureRecoversWithoutOpeningOriginalStreamAgain()
    {
        var api = new UploadApiClient(new(FileUploadTransportStatus.Accepted)) { FailReadback = true };
        var repository = Repository(api);
        using (var stream = new MemoryStream([1, 2, 3, 4]))
            Assert.Equal(MutationResultStatus.SubmittedButUnverified,
                (await repository.UploadFileAsync(new(stream, 4, "/projects", "upload.bin"))).Status);
        api.FailReadback = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repository.ReviewFileUploadAsync("/projects", "upload.bin"))!.Status);
        Assert.Equal(1, api.UploadCount);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task PermissionOrTargetChangeRejectsBeforeUpload(bool change)
    {
        var api = new UploadApiClient(new(FileUploadTransportStatus.Accepted)) { DenyPermission = !change, ChangeTarget = change };
        var result = await Repository(api).UploadFileAsync(Request());
        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Status);
        Assert.Equal(change ? MutationErrorCategory.Conflict : MutationErrorCategory.Permission, result.ErrorCategory);
        Assert.False(result.Submitted); Assert.Equal(0, api.UploadCount);
    }

    [Fact]
    public async Task ExistingTargetNeedsExplicitOverwriteAndCanWriteFlagIsNotOverwriteAuthority()
    {
        var target = Item("/projects/upload.bin", "upload.bin", 9);
        target["additional"] = new JsonObject { ["perm"] = new JsonObject { ["write"] = false } };
        var api = new UploadApiClient(new(FileUploadTransportStatus.Accepted)) { ExistingTarget = target };
        var repository = Repository(api);
        Assert.Equal(MutationErrorCategory.Conflict, (await repository.UploadFileAsync(Request())).ErrorCategory);
        Assert.Equal(0, api.UploadCount);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess,
            (await repository.UploadFileAsync(new(new MemoryStream([1]), 1, "/projects", "upload.bin", true))).Status);
        Assert.Equal(1, api.UploadCount);
    }

    [Fact]
    public async Task SameTargetConcurrentUploadIsBlocked()
    {
        var api = new UploadApiClient(new(FileUploadTransportStatus.Accepted)) { HoldUpload = new(TaskCreationOptions.RunContinuationsAsynchronously) };
        var first = Repository(api).UploadFileAsync(Request());
        await api.Started.Task.WaitAsync(TimeSpan.FromSeconds(3));
        var second = await Repository(api).UploadFileAsync(Request());
        Assert.Equal(MutationErrorCategory.Conflict, second.ErrorCategory); Assert.False(second.Submitted); Assert.Equal(1, api.UploadCount);
        api.HoldUpload.SetResult(); Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await first).Status);
    }

    [Fact]
    public async Task MultiChunkReadbackCarriesOriginalVersionAndCoversEveryByte()
    {
        var bytes = new byte[4 * 1024 * 1024 + 13]; bytes[^1] = 23;
        var api = new UploadApiClient(new(FileUploadTransportStatus.Accepted));
        var result = await Repository(api).UploadFileAsync(new(new MemoryStream(bytes), bytes.Length, "/projects", "upload.bin"));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Status);
        Assert.Equal([(0L, 4194304L, (string?)null), (4194304L, 13L, "synthetic-v1")], api.Ranges);
    }

    [Fact]
    public async Task EmptyFileAndPreCancelledUploadHaveDistinctResults()
    {
        var api = new UploadApiClient(new(FileUploadTransportStatus.Accepted)); var repository = Repository(api);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repository.UploadFileAsync(new(new MemoryStream([]), 0, "/projects", "empty.bin"))).Status);
        Assert.Empty(api.Ranges);
        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, (await repository.UploadFileAsync(Request(), cancellationToken: new(true))).Status);
        Assert.Equal(1, api.UploadCount);
    }

    private static FileUploadRequest Request() => new(new MemoryStream([1, 2, 3, 4]), 4, "/projects", "upload.bin");

    [Fact]
    public async Task OperationIdentityPreventsReplayAndCannotClaimLaterUploadToSamePath()
    {
        var api = new UploadApiClient(new(FileUploadTransportStatus.Accepted)); var repository = Repository(api);
        var original = Request();
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repository.UploadFileAsync(original)).Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repository.UploadFileAsync(original)).Status);
        Assert.Equal(1, api.UploadCount);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repository.ReviewFileUploadAsync("/projects", "upload.bin", operationId: original.OperationId))!.Status);
        Assert.Null(await repository.ReviewFileUploadAsync("/projects", "upload.bin", operationId: Guid.NewGuid()));
        var replacement = new FileUploadRequest(new MemoryStream([9, 8]), 2, "/projects", "upload.bin", true);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repository.UploadFileAsync(replacement)).Status);
        Assert.Equal(2, api.UploadCount);
        Assert.Null(await repository.ReviewFileUploadAsync("/projects", "upload.bin", operationId: original.OperationId));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repository.ReviewFileUploadAsync("/projects", "upload.bin", operationId: replacement.OperationId))!.Status);
    }

    [Fact]
    public async Task ExpiredSessionKeepsOriginalUploadPendingAndReportsSignInRequirement()
    {
        var api = new UploadApiClient(new(FileUploadTransportStatus.Accepted),
            readbackError: new DsmException("synthetic", "synthetic", authenticationFailure: true));
        var repository = Repository(api);
        var result = await repository.UploadFileAsync(Request());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Status);
        Assert.Equal(MutationErrorCategory.Authentication, result.ErrorCategory);
        var unrelated = new DsmRepository(new NasProfile(Guid.NewGuid(), "synthetic", "nas.invalid", 5001, "other"),
            new DsmSession(Guid.NewGuid(), "synthetic-session", null, null), api, new Dictionary<string, ApiCapability>());
        Assert.Null(await unrelated.ReviewFileUploadAsync("/projects", "upload.bin"));
        api.FailReadback = false;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repository.ReviewFileUploadAsync("/projects", "upload.bin"))!.Status);
        Assert.Equal(1, api.UploadCount);
    }

    private static DsmRepository Repository(UploadApiClient api)
    {
        var profileId = Guid.Parse("11111111-1111-1111-1111-111111111111");
        var capabilities = new[]
        {
            new ApiCapability("SYNO.FileStation.Upload", "entry.cgi", 1, 2, "MULTIPART"),
            new ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2, "FORM"),
            new ApiCapability("SYNO.FileStation.Download", "entry.cgi", 1, 2, "FORM"),
            new ApiCapability("SYNO.FileStation.CheckPermission", "entry.cgi", 1, 3, "FORM"),
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
        public FileUploadTransportResult Result { get; set; } = uploadResult;
        public bool CorruptReadback { get; set; }
        public bool FailReadback { get; set; } = readbackError is not null;
        public bool DenyPermission { get; set; }
        public bool ChangeTarget { get; set; }
        public JsonObject? ExistingTarget { get; set; }
        public TaskCompletionSource? HoldUpload { get; set; }
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<(long Offset, long Length, string? Version)> Ranges { get; } = [];
        public int MetadataReads { get; private set; }
        private byte[] _bytes = [];
        private string _fileName = "upload.bin";

        public async Task<FileUploadTransportResult> UploadFileAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            FileUploadRequest request,
            IProgress<long>? progress = null,
            CancellationToken cancellationToken = default)
        {
            UploadCount++; _fileName = request.FileName;
            _bytes = new byte[checked((int)request.Length)];
            await request.Content.ReadExactlyAsync(_bytes, cancellationToken);
            Started.TrySetResult();
            if (HoldUpload is not null) await HoldUpload.Task.WaitAsync(cancellationToken);
            return Result;
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
            if (method == "getinfo")
            {
                MetadataReads++;
                var path = System.Text.Json.JsonSerializer.Deserialize<string[]>(parameters!["path"])!.Single();
                if (UploadCount > 0)
                {
                    var uploaded = Item(path, path.Split('/').Last(), _bytes.LongLength);
                    uploaded["additional"] = new JsonObject();
                    return Task.FromResult(new JsonObject { ["files"] = new JsonArray(uploaded) });
                }
                if (ExistingTarget is not null) return Task.FromResult(new JsonObject { ["files"] = new JsonArray(ExistingTarget.DeepClone()) });
                if (ChangeTarget && MetadataReads > 1)
                {
                    var row = Item(path, path.Split('/').Last(), 1); row["additional"] = new JsonObject();
                    return Task.FromResult(new JsonObject { ["files"] = new JsonArray(row) });
                }
                return Task.FromResult(new JsonObject { ["files"] = new JsonArray(new JsonObject { ["path"] = path, ["code"] = 408L }) });
            }
            Assert.Equal("list", method);
            if (FailReadback)
            {
                return Task.FromException<JsonObject>(readbackError ?? new IOException("合成读取失败"));
            }
            var offset = int.Parse(parameters!["offset"], System.Globalization.CultureInfo.InvariantCulture);
            ReadbackOffsets.Add(offset);
            return Task.FromResult(pages is not null ? pages[offset].DeepClone().AsObject() : Page(0, 1, Item("/projects/" + _fileName, _fileName, _bytes.LongLength)));
        }

        public Task<JsonObject> CallReadJsonObjectAsync(NasProfile profile, DsmSession session,
            ApiCapability capability, int requiredVersion, string method,
            IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default)
        {
            Assert.Equal(2, requiredVersion);
            return CallAsync(profile, session, capability, method, parameters, cancellationToken);
        }

        public Task<FilePermissionTransportResult> CheckFileMutationPermissionAsync(NasProfile profile, DsmSession session,
            ApiCapability capability, string parentPath, string name, CancellationToken cancellationToken = default) =>
            Task.FromResult(new FilePermissionTransportResult(DenyPermission ? FilePermissionTransportStatus.Denied : FilePermissionTransportStatus.Allowed,
                DenyPermission ? MutationErrorCategory.Permission : null));
        public Task<FileRangeReadResult> ReadFileRangeResultAsync(NasProfile profile, DsmSession session,
            ApiCapability capability, string remotePath, long offset, long length, string? expectedContentVersion = null,
            long? expectedTotalLength = null, CancellationToken cancellationToken = default)
        {
            Ranges.Add((offset, length, expectedContentVersion));
            var bytes = _bytes.AsSpan((int)offset, (int)length).ToArray();
            if (CorruptReadback && bytes.Length > 0) bytes[0] ^= 1;
            return Task.FromResult(new FileRangeReadResult(206, offset, length, offset, length, _bytes.Length, bytes.Length, bytes, "synthetic-v1", true));
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
