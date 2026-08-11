using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.CopyMove;

public sealed class FileCopyMoveRepositoryContractTests
{
    [Fact]
    public void AvailabilityRequiresExactCapabilityNamesAndFixedVersions()
    {
        IFileCopyMoveRepository available = Repository(new FakeApi());
        var wrongCapabilities = new Dictionary<string, ApiCapability>
        {
            ["SYNO.FileStation.CopyMove"] = Capability("Wrong.Name", 3),
            ["SYNO.FileStation.CheckPermission"] = Capability("SYNO.FileStation.CheckPermission", 3),
            ["SYNO.FileStation.List"] = Capability("SYNO.FileStation.List", 2),
        };
        IFileCopyMoveRepository unavailable = new DsmRepository(
            Profile, Session, new FakeApi(), wrongCapabilities);

        Assert.True(available.Availability.CanCopy);
        Assert.True(available.Availability.CanMove);
        Assert.Equal(3, available.Availability.ResolvedVersion);
        Assert.False(unavailable.Availability.CanCopy);
        Assert.False(unavailable.Availability.CanMove);
        Assert.Null(unavailable.Availability.ResolvedVersion);
    }

    [Theory]
    [InlineData(FileCopyMoveOperation.Copy)]
    [InlineData(FileCopyMoveOperation.Move)]
    public async Task SingleFilePreflightSubmitAndIndependentReadbackCloseTypedResult(
        FileCopyMoveOperation operation)
    {
        var source = File("/share/source/item.txt", "item.txt", 7, 10);
        var target = File("/share/destination/item.txt", "item.txt", 7, 10);
        var api = new FakeApi(
            Page(source), Page(),
            operation == FileCopyMoveOperation.Copy ? Page(source) : Page(), Page(target));
        using var cancellation = new CancellationTokenSource();

        var outcome = await Repository(api).CopyMoveAsync(Request(operation), cancellation.Token);

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal("/share/destination/item.txt", outcome.ConfirmedItem?.Path);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(1, api.StatusCount);
        Assert.Equal(1, api.PermissionCount);
        Assert.True(api.ListTokens[0].CanBeCanceled);
        Assert.True(api.ListTokens[1].CanBeCanceled);
        Assert.False(api.ListTokens[2].CanBeCanceled);
        Assert.False(api.ListTokens[3].CanBeCanceled);
    }

    [Theory]
    [InlineData(FileCopyMoveOperation.Copy)]
    [InlineData(FileCopyMoveOperation.Move)]
    public async Task SingleFolderUsesTypeBasedFrozenSourceAndIndependentReadback(
        FileCopyMoveOperation operation)
    {
        var source = Folder("/share/source/album", "album", 10);
        var target = Folder("/share/destination/album", "album", 11);
        var api = new FakeApi(
            Page(source), Page(),
            operation == FileCopyMoveOperation.Copy ? Page(source) : Page(), Page(target));

        var outcome = await Repository(api).CopyMoveAsync(Request(operation, isDirectory: true));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.True(outcome.ConfirmedItem?.IsDirectory);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(1, api.PermissionCount);
    }

    [Fact]
    public async Task StrictPaginationFindsSourceAcrossPagesBeforeWriting()
    {
        var source = File("/share/source/item.txt", "item.txt", 7, 10);
        var api = new FakeApi(
            Page(0, 2, File("/share/source/other.txt", "other.txt", 1, 1)),
            Page(1, 2, source), Page(), Page(0, 2,
                File("/share/source/other.txt", "other.txt", 1, 1)),
            Page(1, 2, source),
            Page(File("/share/destination/item.txt", "item.txt", 7, 10)));

        var outcome = await Repository(api).CopyMoveAsync(Request(FileCopyMoveOperation.Copy));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(6, api.ListCount);
    }

    [Fact]
    public async Task MoveRechecksObservedSourceDeletePermissionBeforeWriting()
    {
        var source = File("/share/source/item.txt", "item.txt", 7, 10);
        ((JsonObject)((JsonObject)source["additional"]!)["perm"]!)["delete"] = false;
        var api = new FakeApi(Page(source));

        var outcome = await Repository(api).CopyMoveAsync(Request(FileCopyMoveOperation.Move));

        Assert.Equal(MutationResultStatus.PermissionDenied, outcome.Result.Status);
        Assert.Equal(MutationErrorCategory.Permission, outcome.Result.ErrorCategory);
        Assert.Equal(0, api.PermissionCount);
        Assert.Equal(0, api.StartCount);
    }

    [Fact]
    public async Task ProfileRemoteVirtualRecycleAndSameTargetRequestsSendZeroWrites()
    {
        var api = new FakeApi();
        var repository = Repository(api);
        var valid = Request(FileCopyMoveOperation.Copy);
        var requests = new[]
        {
            valid with { Target = valid.Target with { ProfileId = Guid.NewGuid() } },
            valid with { Target = valid.Target with { IsRemote = true } },
            valid with { DestinationIsVirtual = true },
            valid with { DestinationDirectoryPath = "/share/#Recycle" },
            valid with { DestinationDirectoryPath = "/share/source" },
            valid with { DestinationDirectoryPath = "/share/source/item.txt/child" },
        };

        foreach (var request in requests)
            Assert.NotEqual(MutationResultStatus.ConfirmedSuccess,
                (await repository.CopyMoveAsync(request)).Result.Status);

        Assert.Equal(0, api.ListCount);
        Assert.Equal(0, api.StartCount);
    }

    [Fact]
    public async Task InvalidNativePaginationFailsPreflightAndSendsZeroWrites()
    {
        var invalid = new JsonObject
        {
            ["offset"] = "0", ["total"] = 1,
            ["files"] = new JsonArray(File("/share/source/item.txt", "item.txt", 7, 10)),
        };
        var api = new FakeApi(invalid);

        var outcome = await Repository(api).CopyMoveAsync(Request(FileCopyMoveOperation.Copy));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, outcome.Result.Status);
        Assert.Equal(0, api.StartCount);
    }

    [Theory]
    [InlineData("source", "cifs")]
    [InlineData("source", "future_mount")]
    [InlineData("destination", "nfs")]
    [InlineData("destination", "future_mount")]
    public async Task RemoteOrUnknownMountIsRejectedBeforePermissionAndStart(
        string side, string mountType)
    {
        var api = new FakeApi();
        var request = Request(FileCopyMoveOperation.Copy);
        if (side == "source")
        {
            request = request with
            {
                Target = request.Target with { Path = "/remote/source/item.txt" },
            };
            api.RootMountResponse = MountPage(
                Mount("remote", "/remote", mountType),
                Mount("share", "/share", "normal"));
        }
        else
        {
            request = request with { DestinationDirectoryPath = "/remote/destination" };
            api.RootMountResponse = MountPage(
                Mount("share", "/share", "normal"),
                Mount("remote", "/remote", mountType));
        }

        var outcome = await Repository(api).CopyMoveAsync(request);

        Assert.Equal(MutationResultStatus.Unsupported, outcome.Result.Status);
        Assert.Equal(1, api.MountProbeCount);
        Assert.Equal(0, api.ListCount);
        Assert.Equal(0, api.PermissionCount);
        Assert.Equal(0, api.StartCount);
    }

    [Fact]
    public async Task NonStringMountTypeStrictlyFailsBeforePermissionAndStart()
    {
        var api = new FakeApi
        {
            RootMountResponse = MountPage(Mount("share", "/share", 7)),
        };

        var outcome = await Repository(api).CopyMoveAsync(Request(FileCopyMoveOperation.Copy));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, outcome.Result.Status);
        Assert.Equal(1, api.MountProbeCount);
        Assert.Equal(0, api.ListCount);
        Assert.Equal(0, api.PermissionCount);
        Assert.Equal(0, api.StartCount);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("normal")]
    [InlineData("shared_folder")]
    public async Task RecordedLocalMountTypesRemainAllowed(string? mountType)
    {
        var source = File("/share/source/item.txt", "item.txt", 7, 10);
        var target = File("/share/destination/item.txt", "item.txt", 7, 10);
        var api = new FakeApi(Page(source), Page(), Page(source), Page(target))
        {
            RootMountResponse = MountPage(Mount("share", "/share", mountType)),
        };

        var outcome = await Repository(api).CopyMoveAsync(Request(FileCopyMoveOperation.Copy));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal(1, api.PermissionCount);
        Assert.Equal(1, api.StartCount);
    }

    [Fact]
    public async Task PreCancelledRequestIsSafelyCancelledWithoutReadsOrWrites()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var api = new FakeApi();

        var outcome = await Repository(api).CopyMoveAsync(
            Request(FileCopyMoveOperation.Copy), cancellation.Token);

        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, outcome.Result.Status);
        Assert.False(outcome.Result.Submitted);
        Assert.Equal(0, api.ListCount);
        Assert.Equal(0, api.StartCount);
    }

    [Theory]
    [InlineData("cancel")]
    [InlineData("invalid-operation")]
    [InlineData("argument")]
    public async Task ExceptionAfterWriteBoundaryBlocksReplayAndEquivalentRepositoryOnlyReadsBack(
        string failure)
    {
        var source = File("/share/source/item.txt", "item.txt", 7, 10);
        var target = File("/share/destination/item.txt", "item.txt", 7, 10);
        var api = new FakeApi(Page(source), Page(), Page(source), Page(target))
        {
            StartException = failure switch
            {
                "cancel" => new OperationCanceledException(),
                "argument" => new ArgumentException("synthetic"),
                _ => new InvalidOperationException("synthetic"),
            },
        };
        var request = Request(FileCopyMoveOperation.Copy);

        var first = await Repository(api).CopyMoveAsync(request);
        api.StartException = null;
        var reviewed = await Repository(api).CopyMoveAsync(request);

        Assert.Equal(failure == "cancel"
            ? MutationResultStatus.CancellationRequestedAfterSubmission
            : MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(0, api.StatusCount);
    }

    [Fact]
    public async Task BadReadbackLeavesReviewAndLaterCallNeverStartsAgain()
    {
        var source = File("/share/source/item.txt", "item.txt", 7, 10);
        var wrongSize = File("/share/destination/item.txt", "item.txt", 8, 10);
        var api = new FakeApi(Page(source), Page(), Page(source), Page(wrongSize),
            Page(source), Page(wrongSize));
        var request = Request(FileCopyMoveOperation.Copy);

        var first = await Repository(api).CopyMoveAsync(request);
        var reviewed = await Repository(api).CopyMoveAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, reviewed.Result.Status);
        Assert.Equal(1, api.StartCount);
    }

    [Fact]
    public async Task OverlappingConcurrentTargetIsRejectedBeforeSecondWrite()
    {
        var source = File("/share/source/item.txt", "item.txt", 7, 10);
        var target = File("/share/destination/item.txt", "item.txt", 7, 10);
        var api = new FakeApi(Page(source), Page(), Page(source), Page(target))
        { HoldFirstList = true };
        var repository = Repository(api);
        var request = Request(FileCopyMoveOperation.Copy);

        var firstTask = repository.CopyMoveAsync(request);
        await api.FirstListEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var duplicate = await repository.CopyMoveAsync(request);
        api.ReleaseFirstList.TrySetResult(true);
        var first = await firstTask;

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, duplicate.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, duplicate.Result.ErrorCategory);
        Assert.Equal(1, api.StartCount);
    }

    [Fact]
    public async Task PostSubmitAuthenticationKeepsReviewAndPropagatesAcrossReopen()
    {
        var source = File("/share/source/item.txt", "item.txt", 7, 10);
        var api = new FakeApi(Page(source), Page(), AuthenticationFailure(), AuthenticationFailure())
        {
            StartResult = new(FileMutationTransportStatus.ResponseReceived, "task-1"),
            StatusException = AuthenticationFailureException(),
        };
        var request = Request(FileCopyMoveOperation.Copy);

        await Assert.ThrowsAsync<DsmException>(() => Repository(api).CopyMoveAsync(request));
        api.StatusException = null;
        await Assert.ThrowsAsync<DsmException>(() => Repository(api).CopyMoveAsync(request));

        Assert.Equal(1, api.StartCount);
    }

    private static readonly NasProfile Profile = new(
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        "NAS", "nas.example.invalid", null, "user");
    private static readonly DsmSession Session = new(Profile.Id, "synthetic", null, null);

    private static FileCopyMoveRequest Request(FileCopyMoveOperation operation,
        bool isDirectory = false) => new(
        new FileCopyMoveTarget(Profile.Id,
            isDirectory ? "/share/source/album" : "/share/source/item.txt",
            isDirectory ? "album" : "item.txt", isDirectory, isDirectory ? 0 : 7,
            DateTimeOffset.FromUnixTimeSeconds(10), true, true,
            false, false, false),
        "/share/destination", operation, true, false, false, false);

    private static DsmRepository Repository(IDsmApiClient api) => new(
        Profile, Session, api, new Dictionary<string, ApiCapability>
        {
            ["SYNO.FileStation.CopyMove"] = Capability("SYNO.FileStation.CopyMove", 3),
            ["SYNO.FileStation.CheckPermission"] = Capability("SYNO.FileStation.CheckPermission", 3),
            ["SYNO.FileStation.List"] = Capability("SYNO.FileStation.List", 2),
        });

    private static ApiCapability Capability(string name, int version) =>
        new(name, "entry.cgi", version, version, "FORM");

    private static JsonObject Page(params JsonObject[] items) => Page(0, items.Length, items);
    private static JsonObject Page(int offset, int total, params JsonObject[] items) => new()
    {
        ["offset"] = offset,
        ["total"] = total,
        ["files"] = new JsonArray(items.Select(item => item.DeepClone()).ToArray()),
    };

    private static JsonObject File(string path, string name, long size, long modified) => new()
    {
        ["path"] = path, ["name"] = name, ["isdir"] = false, ["size"] = size,
        ["additional"] = new JsonObject
        {
            ["time"] = new JsonObject { ["mtime"] = modified },
            ["perm"] = new JsonObject { ["write"] = true, ["delete"] = true },
        },
    };

    private static JsonObject Folder(string path, string name, long modified) => new()
    {
        ["path"] = path, ["name"] = name, ["isdir"] = true, ["size"] = 0,
        ["additional"] = new JsonObject
        {
            ["time"] = new JsonObject { ["mtime"] = modified },
            ["perm"] = new JsonObject { ["write"] = true, ["delete"] = true },
        },
    };

    private static JsonObject MountPage(params JsonObject[] items) => new()
    {
        ["offset"] = 0,
        ["total"] = items.Length,
        ["files"] = new JsonArray(items.Select(item => item.DeepClone()).ToArray()),
    };

    private static JsonObject Mount(string name, string path, object? mountType)
    {
        var additional = new JsonObject();
        additional["mount_point_type"] = mountType switch
        {
            null => null,
            string value => JsonValue.Create(value),
            int value => JsonValue.Create(value),
            _ => throw new ArgumentException("unsupported synthetic mount type"),
        };
        return new JsonObject
        {
            ["name"] = name,
            ["path"] = path,
            ["isdir"] = true,
            ["additional"] = additional,
        };
    }

    private static Exception AuthenticationFailure() => AuthenticationFailureException();
    private static DsmException AuthenticationFailureException() => new(
        UserText.Key("auth"), UserText.Key("login"), 119, true);

    private sealed class FakeApi(params object[] pages) : IDsmApiClient
    {
        private readonly Queue<object> _pages = new(pages);
        private int _listCount;
        public int ListCount => _listCount;
        public int StartCount { get; private set; }
        public int StatusCount { get; private set; }
        public int PermissionCount { get; private set; }
        public int MountProbeCount { get; private set; }
        public JsonObject RootMountResponse { get; set; } =
            MountPage(Mount("share", "/share", "normal"));
        public Exception? StartException { get; set; }
        public Exception? StatusException { get; set; }
        public FileCopyMoveStartTransportResult StartResult { get; set; } =
            new(FileMutationTransportStatus.ResponseReceived, "task-1");
        public FileCopyMoveTaskTransportResult StatusResult { get; set; } =
            new(FileCopyMoveTaskTransportStatus.Finished);
        public bool HoldFirstList { get; init; }
        public TaskCompletionSource<bool> FirstListEntered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> ReleaseFirstList { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<CancellationToken> ListTokens { get; } = [];

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.example.invalid/");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session,
            ApiCapability capability, string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session,
            ApiCapability capability, string remotePath, long offset, long length,
            CancellationToken cancellationToken = default) => throw new NotSupportedException();

        public async Task<JsonObject> CallReadJsonObjectAsync(NasProfile profile,
            DsmSession session, ApiCapability capability, int requiredVersion, string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            if (parameters?.TryGetValue("folder_path", out var folderPath) == true &&
                folderPath.Length == 0)
            {
                MountProbeCount++;
                return (JsonObject)RootMountResponse.DeepClone();
            }
            var count = Interlocked.Increment(ref _listCount);
            if (HoldFirstList && count == 1)
            {
                FirstListEntered.TrySetResult(true);
                await ReleaseFirstList.Task.WaitAsync(cancellationToken);
            }
            ListTokens.Add(cancellationToken);
            var value = _pages.Dequeue();
            if (value is Exception error) throw error;
            return (JsonObject)value;
        }

        public Task<FilePermissionTransportResult> CheckFileMutationPermissionAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string folderPath, string name, CancellationToken cancellationToken = default)
        {
            PermissionCount++;
            return Task.FromResult(new FilePermissionTransportResult(
                FilePermissionTransportStatus.Allowed));
        }

        public Task<FileCopyMoveStartTransportResult> StartFileCopyMoveAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string sourcePath, string destinationDirectoryPath, bool removeSource,
            CancellationToken cancellationToken = default)
        {
            StartCount++;
            var error = StartException;
            return error is null ? Task.FromResult(StartResult) :
                Task.FromException<FileCopyMoveStartTransportResult>(error);
        }

        public Task<FileCopyMoveTaskTransportResult> ReadFileCopyMoveStatusAsync(
            NasProfile profile, DsmSession session, ApiCapability capability, string taskId,
            CancellationToken cancellationToken = default)
        {
            StatusCount++;
            var error = StatusException;
            return error is null ? Task.FromResult(StatusResult) :
                Task.FromException<FileCopyMoveTaskTransportResult>(error);
        }
    }
}
