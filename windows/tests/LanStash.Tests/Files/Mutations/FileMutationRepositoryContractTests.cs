using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Mutations;

public sealed class FileMutationRepositoryContractTests
{
    [Fact]
    public async Task CreatePreflightsSubmitsOnceAndIndependentlyReadsBackDirectory()
    {
        var api = new FakeApi(Page(), Page(Folder("/share/parent/new", "new")));
        var repository = Repository(api);

        var outcome = await repository.CreateFolderAsync(
            new CreateFolderRequest(Profile.Id, "/share/parent", "new"));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.True(outcome.ConfirmedItem?.IsDirectory);
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(1, api.PermissionCount);
        Assert.Equal(2, api.ListCount);
    }

    [Fact]
    public async Task RenameLocksTargetAndRequiresOldDisappearAndNewAppear()
    {
        var old = File("/share/parent/old", "old", 5, 10);
        var renamed = File("/share/parent/new", "new", 5, 10);
        var api = new FakeApi(Page(old), Page(renamed));
        var repository = Repository(api);
        var target = new FileMutationTarget(Profile.Id, "/share/parent/old", "old",
            false, 5, DateTimeOffset.FromUnixTimeSeconds(10), true);

        var outcome = await repository.RenameAsync(new RenameFileItemRequest(target, "new"));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal("/share/parent/new", outcome.ConfirmedItem?.Path);
        Assert.Equal(1, api.RenameCount);
    }

    [Fact]
    public async Task ExistingCreateTargetAndProfileMismatchSendZeroWrites()
    {
        var api = new FakeApi(Page(Folder("/share/parent/new", "new")));
        var repository = Repository(api);

        var conflict = await repository.CreateFolderAsync(
            new CreateFolderRequest(Profile.Id, "/share/parent", "new"));
        var mismatch = await repository.CreateFolderAsync(
            new CreateFolderRequest(Guid.NewGuid(), "/share/parent", "other"));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, conflict.Result.Status);
        Assert.Equal(MutationResultStatus.Unsupported, mismatch.Result.Status);
        Assert.Equal(0, api.CreateCount);
        Assert.Equal(0, api.PermissionCount);
    }

    [Fact]
    public async Task CancellationAfterCreateSubmissionUsesIndependentReadbackAndNeverReplays()
    {
        using var cancellation = new CancellationTokenSource();
        var api = new FakeApi(Page(), Page(Folder("/share/parent/new", "new")))
        {
            CreateResult = new FileMutationTransportResult(
                FileMutationTransportStatus.CancellationRequestedAfterSubmission,
                MutationErrorCategory.Network,
                "file.mutation.cancelled-after-submit"),
            OnCreate = cancellation.Cancel,
        };
        var repository = Repository(api);

        var outcome = await repository.CreateFolderAsync(
            new CreateFolderRequest(Profile.Id, "/share/parent", "new"), cancellation.Token);

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(2, api.ListCount);
        Assert.True(api.ListTokens[0].CanBeCanceled);
        Assert.False(api.ListTokens[1].CanBeCanceled);
    }

    [Fact]
    public async Task InvalidIndependentReadbackLeavesSubmittedResultUnverifiedWithoutReplay()
    {
        var invalidReadback = new JsonObject
        {
            ["offset"] = 1,
            ["total"] = 0,
            ["files"] = new JsonArray(),
        };
        var api = new FakeApi(Page(), invalidReadback);
        var repository = Repository(api);

        var outcome = await repository.CreateFolderAsync(
            new CreateFolderRequest(Profile.Id, "/share/parent", "new"));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, outcome.Result.Status);
        Assert.True(outcome.Result.Submitted);
        Assert.True(outcome.Result.RequiresRefresh);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task ConcurrentCreateOnSameCanonicalTargetIsRejectedBeforeSecondWrite()
    {
        var api = new FakeApi(Page(), Page(Folder("/share/parent/new", "new")))
        {
            HoldFirstList = true,
        };
        var repository = Repository(api);
        var request = new CreateFolderRequest(Profile.Id, "/share/parent", "new");

        var firstTask = repository.CreateFolderAsync(request);
        await api.FirstListEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var duplicate = await repository.CreateFolderAsync(request);
        api.ReleaseFirstList.TrySetResult(true);
        var first = await firstTask;

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, duplicate.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, duplicate.Result.ErrorCategory);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task ConcurrentRenameSourceAndDestinationBlockOverlappingCreate()
    {
        var old = File("/share/parent/old", "old", 5, 10);
        var renamed = File("/share/parent/new", "new", 5, 10);
        var api = new FakeApi(Page(old), Page(renamed)) { HoldFirstList = true };
        var repository = Repository(api);
        var target = new FileMutationTarget(Profile.Id, old["path"]!.GetValue<string>(),
            "old", false, 5, DateTimeOffset.FromUnixTimeSeconds(10), true);

        var renameTask = repository.RenameAsync(new RenameFileItemRequest(target, "new"));
        await api.FirstListEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var overlapping = await repository.CreateFolderAsync(
            new CreateFolderRequest(Profile.Id, "/share/parent", "new"));
        api.ReleaseFirstList.TrySetResult(true);
        var renamedOutcome = await renameTask;

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, renamedOutcome.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, overlapping.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, overlapping.Result.ErrorCategory);
        Assert.Equal(1, api.RenameCount);
        Assert.Equal(0, api.CreateCount);
    }

    [Fact]
    public async Task ReopenedEquivalentRepositoryReviewsUnknownCreateWithoutSecondWrite()
    {
        var invalidReadback = new JsonObject
        {
            ["offset"] = 1, ["total"] = 0, ["files"] = new JsonArray(),
        };
        var api = new FakeApi(Page(), invalidReadback,
            Page(Folder("/share/parent/new", "new")));
        var request = new CreateFolderRequest(Profile.Id, "/share/parent", "new");

        var first = await Repository(api).CreateFolderAsync(request);
        var reviewed = await Repository(api).CreateFolderAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(3, api.ListCount);
    }

    [Fact]
    public async Task CancellationAfterSubmissionWithBadReadbackBlocksReplayUntilReviewConfirms()
    {
        var invalidReadback = new JsonObject
        {
            ["offset"] = 0, ["total"] = 1, ["files"] = new JsonArray(),
        };
        var api = new FakeApi(Page(), invalidReadback,
            Page(Folder("/share/parent/new", "new")))
        {
            CreateResult = new FileMutationTransportResult(
                FileMutationTransportStatus.CancellationRequestedAfterSubmission,
                MutationErrorCategory.Network,
                "file.mutation.cancelled-after-submit"),
        };
        var request = new CreateFolderRequest(Profile.Id, "/share/parent", "new");

        var first = await Repository(api).CreateFolderAsync(request);
        var reviewed = await Repository(api).CreateFolderAsync(request);

        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task PreflightAuthenticationFailurePropagatesAndSendsZeroWrites()
    {
        var api = new FakeApi(AuthenticationFailure());

        await Assert.ThrowsAsync<DsmException>(() => Repository(api).CreateFolderAsync(
            new CreateFolderRequest(Profile.Id, "/share/parent", "new")));

        Assert.Equal(0, api.CreateCount);
    }

    [Fact]
    public async Task PostSubmitAuthenticationFailurePreservesBlockerAcrossRepositoryReopen()
    {
        var api = new FakeApi(Page(), AuthenticationFailure(), AuthenticationFailure());
        var request = new CreateFolderRequest(Profile.Id, "/share/parent", "new");

        await Assert.ThrowsAsync<DsmException>(() => Repository(api).CreateFolderAsync(request));
        await Assert.ThrowsAsync<DsmException>(() => Repository(api).CreateFolderAsync(request));

        Assert.Equal(1, api.CreateCount);
        Assert.Equal(3, api.ListCount);
    }

    [Fact]
    public async Task WriteCancellationExceptionIsPostSubmissionAndSecondCallOnlyReviews()
    {
        var api = new FakeApi(Page(), Page(Folder("/share/parent/new", "new")))
        {
            CreateException = new OperationCanceledException(),
        };
        var request = new CreateFolderRequest(Profile.Id, "/share/parent", "new");

        var first = await Repository(api).CreateFolderAsync(request);
        api.CreateException = null;
        var reviewed = await Repository(api).CreateFolderAsync(request);

        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(2, api.ListCount);
    }

    [Theory]
    [InlineData("invalid-operation")]
    [InlineData("argument")]
    public async Task UnexpectedWriteExceptionIsUnknownAndSecondCallNeverReplays(string kind)
    {
        Exception error = kind == "invalid-operation"
            ? new InvalidOperationException("synthetic")
            : new ArgumentException("synthetic");
        var api = new FakeApi(Page(), Page(Folder("/share/parent/new", "new")))
        {
            CreateException = error,
        };
        var request = new CreateFolderRequest(Profile.Id, "/share/parent", "new");

        var first = await Repository(api).CreateFolderAsync(request);
        api.CreateException = null;
        var reviewed = await Repository(api).CreateFolderAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(2, api.ListCount);
    }

    [Fact]
    public async Task RenameWriteExceptionAlsoUsesSharedPostSubmissionBoundary()
    {
        var old = File("/share/parent/old", "old", 5, 10);
        var renamed = File("/share/parent/new", "new", 5, 10);
        var api = new FakeApi(Page(old), Page(renamed))
        {
            RenameException = new InvalidOperationException("synthetic"),
        };
        var request = new RenameFileItemRequest(new FileMutationTarget(Profile.Id,
            "/share/parent/old", "old", false, 5,
            DateTimeOffset.FromUnixTimeSeconds(10), true), "new");

        var first = await Repository(api).RenameAsync(request);
        api.RenameException = null;
        var reviewed = await Repository(api).RenameAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, api.RenameCount);
        Assert.Equal(2, api.ListCount);
    }

    [Fact]
    public async Task PaginationRejectsOverLimitOverTotalDriftAndZeroProgressBeforeWrite()
    {
        var overLimitItems = Enumerable.Range(0, 501)
            .Select(index => Folder($"/share/parent/item-{index}", $"item-{index}"))
            .ToArray();
        var firstPage = Enumerable.Range(0, 500)
            .Select(index => Folder($"/share/parent/item-{index}", $"item-{index}"))
            .ToArray();
        var cases = new[]
        {
            new FakeApi(Paged(0, 501, overLimitItems)),
            new FakeApi(Paged(0, 1,
                Folder("/share/parent/a", "a"), Folder("/share/parent/b", "b"))),
            new FakeApi(Paged(0, 501, firstPage),
                Paged(500, 502, Folder("/share/parent/item-500", "item-500"))),
            new FakeApi(Paged(0, 1)),
        };

        foreach (var api in cases)
        {
            var outcome = await Repository(api).CreateFolderAsync(
                new CreateFolderRequest(Profile.Id, "/share/parent", "new"));
            Assert.Equal(MutationResultStatus.ConfirmedFailure, outcome.Result.Status);
            Assert.False(outcome.Result.Submitted);
            Assert.Equal(0, api.CreateCount);
            Assert.Equal(0, api.PermissionCount);
        }
    }

    private static readonly NasProfile Profile = new(Guid.Parse("22222222-2222-2222-2222-222222222222"), "NAS", "nas.example.invalid", null, "user");
    private static readonly DsmSession Session = new(Profile.Id, "synthetic", null, null);

    private static DsmRepository Repository(IDsmApiClient api)
    {
        var names = new[] { "SYNO.FileStation.List", "SYNO.FileStation.CheckPermission",
            "SYNO.FileStation.CreateFolder", "SYNO.FileStation.Rename" };
        var capabilities = names.ToDictionary(name => name, name => new ApiCapability(
            name, "entry.cgi", 2, name.EndsWith("CheckPermission", StringComparison.Ordinal) ? 3 : 2, "FORM"));
        return new DsmRepository(Profile, Session, api, capabilities);
    }

    private static JsonObject Page(params JsonObject[] files) => new()
    {
        ["offset"] = 0, ["total"] = files.Length,
        ["files"] = new JsonArray(files.Select(item => item.DeepClone()).ToArray()),
    };
    private static JsonObject Paged(int offset, int total, params JsonObject[] files) => new()
    {
        ["offset"] = offset, ["total"] = total,
        ["files"] = new JsonArray(files.Select(item => item.DeepClone()).ToArray()),
    };
    private static JsonObject Folder(string path, string name) => new()
    { ["path"] = path, ["name"] = name, ["isdir"] = true };
    private static JsonObject File(string path, string name, long size, long mtime) => new()
    {
        ["path"] = path, ["name"] = name, ["isdir"] = false,
        ["additional"] = new JsonObject
        {
            ["size"] = size,
            ["time"] = new JsonObject { ["mtime"] = mtime },
            ["perm"] = new JsonObject { ["write"] = true },
        },
    };
    private static DsmException AuthenticationFailure() =>
        new("synthetic", "synthetic", 119, authenticationFailure: true);

    private sealed class FakeApi(params object[] pages) : IDsmApiClient
    {
        private readonly Queue<object> _pages = new(pages);
        public int ListCount { get; private set; }
        public int PermissionCount { get; private set; }
        public int CreateCount { get; private set; }
        public int RenameCount { get; private set; }
        public List<CancellationToken> ListTokens { get; } = [];
        public FileMutationTransportResult CreateResult { get; init; } =
            new(FileMutationTransportStatus.ResponseReceived);
        public Exception? CreateException { get; set; }
        public Exception? RenameException { get; set; }
        public Action? OnCreate { get; init; }
        public bool HoldFirstList { get; init; }
        public TaskCompletionSource<bool> FirstListEntered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> ReleaseFirstList { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Uri GetBaseUri(NasProfile profile) => new("https://nas.example.invalid");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(NasProfile profile, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(NasProfile profile, string password, string? otp, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task LogoutAsync(NasProfile profile, DsmSession session, CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<JsonObject> CallAsync(NasProfile profile, DsmSession session, ApiCapability capability, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(NasProfile profile, DsmSession session, ApiCapability capability, string remotePath, long offset, long length, CancellationToken cancellationToken = default) => throw new NotSupportedException();
        public async Task<JsonObject> CallReadJsonObjectAsync(NasProfile profile, DsmSession session, ApiCapability capability, int requiredVersion, string method, IReadOnlyDictionary<string, string>? parameters = null, CancellationToken cancellationToken = default)
        {
            ListCount++;
            ListTokens.Add(cancellationToken);
            if (HoldFirstList && ListCount == 1)
            {
                FirstListEntered.TrySetResult(true);
                await ReleaseFirstList.Task.WaitAsync(cancellationToken);
            }
            var next = _pages.Dequeue();
            if (next is Exception error) throw error;
            return ((JsonObject)next).DeepClone().AsObject();
        }
        public Task<FilePermissionTransportResult> CheckFileMutationPermissionAsync(NasProfile profile, DsmSession session, ApiCapability capability, string folderPath, string name, CancellationToken cancellationToken = default)
        { PermissionCount++; return Task.FromResult(new FilePermissionTransportResult(FilePermissionTransportStatus.Allowed)); }
        public Task<FileMutationTransportResult> CreateFolderMutationAsync(NasProfile profile, DsmSession session, ApiCapability capability, string parentPath, string name, CancellationToken cancellationToken = default)
        {
            CreateCount++;
            OnCreate?.Invoke();
            return CreateException is null
                ? Task.FromResult(CreateResult)
                : Task.FromException<FileMutationTransportResult>(CreateException);
        }
        public Task<FileMutationTransportResult> RenameFileMutationAsync(NasProfile profile, DsmSession session, ApiCapability capability, string path, string newName, CancellationToken cancellationToken = default)
        {
            RenameCount++;
            return RenameException is null
                ? Task.FromResult(new FileMutationTransportResult(
                    FileMutationTransportStatus.ResponseReceived))
                : Task.FromException<FileMutationTransportResult>(RenameException);
        }
    }
}
