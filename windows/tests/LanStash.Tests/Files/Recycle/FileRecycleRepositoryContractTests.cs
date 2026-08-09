using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Recycle;

public sealed class FileRecycleRepositoryContractTests
{
    [Fact]
    public async Task MoveToRecycleRequiresDiscoveredRecycleRootAndConfirmsExactRecycleFile()
    {
        var api = new FakeApi(
            Page(Item("/share/docs/a.txt", "a.txt", isDirectory: false, size: 12, canDelete: true)),
            Page(Item("/share/#recycle/docs/a.txt", "a.txt", isDirectory: false, size: 12)));
        var repository = MakeRepository(api);

        var outcome = await repository.MoveToRecycleAsync(new MoveToRecycleRequest(
            Target("/share/docs/a.txt", recycle: false),
            new FileRecycleLocationTarget("/share", "/share/#recycle")));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal("moveToRecycle", outcome.Result.Operation);
        Assert.Equal("/share/docs/a.txt", outcome.SourcePath);
        Assert.Equal("/share/#recycle/docs/a.txt", outcome.DestinationPath);
        Assert.Equal("/share/#recycle/docs/a.txt", outcome.ConfirmedItem?.Path);
        Assert.Equal(1, api.StartRecycleCount);
        Assert.Equal(1, api.RecycleStatusCount);
    }

    [Fact]
    public async Task RestoreFromRecycleUsesCopyMoveAndConfirmsOriginalFile()
    {
        var api = new FakeApi(
            Page(
                Item("/share/#recycle/docs/a.txt", "a.txt", isDirectory: false, size: 12),
                Item("/share/docs", "docs", isDirectory: true, size: 0)),
            Page(Item("/share/docs/a.txt", "a.txt", isDirectory: false, size: 12)));
        var repository = MakeRepository(api);

        var outcome = await repository.RestoreFromRecycleAsync(new RestoreFromRecycleRequest(
            Target("/share/#recycle/docs/a.txt", recycle: true)));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal("restoreFromRecycle", outcome.Result.Operation);
        Assert.Equal("/share/#recycle/docs/a.txt", outcome.SourcePath);
        Assert.Equal("/share/docs/a.txt", outcome.DestinationPath);
        Assert.Equal("/share/docs/a.txt", outcome.ConfirmedItem?.Path);
        Assert.Equal(1, api.PermissionCount);
        Assert.Equal(1, api.StartCopyMoveCount);
        Assert.Equal("/share/#recycle/docs/a.txt", api.LastCopyMoveSource);
        Assert.Equal("/share/docs", api.LastCopyMoveDestination);
        Assert.True(api.LastCopyMoveRemoveSource);
    }

    [Fact]
    public async Task RestoreUnknownResultBlocksReplayAndSecondAttemptOnlyReadsBack()
    {
        var api = new FakeApi(
            Page(
                Item("/share/#recycle/docs/a.txt", "a.txt", isDirectory: false, size: 12),
                Item("/share/docs", "docs", isDirectory: true, size: 0)),
            Page(),
            Page(),
            Page());
        var repository = MakeRepository(api);
        var request = new RestoreFromRecycleRequest(
            Target("/share/#recycle/docs/a.txt", recycle: true));

        var first = await repository.RestoreFromRecycleAsync(request);
        var second = await repository.RestoreFromRecycleAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Equal(1, api.StartCopyMoveCount);
        Assert.Equal(0, api.StartRecycleCount);
        Assert.Equal(3, api.ListCount);
    }

    [Fact]
    public async Task InvalidDirectoryAndMismatchedRecycleRootSendZeroWrites()
    {
        var api = new FakeApi();
        var repository = MakeRepository(api);

        var invalidMove = await repository.MoveToRecycleAsync(new MoveToRecycleRequest(
            Target("/share/docs/a.txt", recycle: false),
            new FileRecycleLocationTarget("/other", "/other/#recycle")));
        var invalidRestore = await repository.RestoreFromRecycleAsync(new RestoreFromRecycleRequest(
            Target("/share/#recycle/folder", recycle: true, isDirectory: true)));

        Assert.Equal(MutationResultStatus.Unsupported, invalidMove.Result.Status);
        Assert.False(invalidMove.Result.Submitted);
        Assert.Equal(MutationResultStatus.Unsupported, invalidRestore.Result.Status);
        Assert.False(invalidRestore.Result.Submitted);
        Assert.Equal(0, api.ListCount);
        Assert.Equal(0, api.StartRecycleCount);
        Assert.Equal(0, api.StartCopyMoveCount);
    }

    private static DsmRepository MakeRepository(FakeApi api)
    {
        var profile = new NasProfile(ProfileId, "NAS", "nas.example.invalid", null, "user");
        return new DsmRepository(profile, new DsmSession(ProfileId, "sid", null, null), api,
            new Dictionary<string, ApiCapability>(StringComparer.Ordinal)
            {
                ["SYNO.FileStation.Delete"] = new("SYNO.FileStation.Delete", "entry.cgi", 2, 2, "FORM"),
                ["SYNO.FileStation.CopyMove"] = new("SYNO.FileStation.CopyMove", "entry.cgi", 3, 3, "FORM"),
                ["SYNO.FileStation.CheckPermission"] = new("SYNO.FileStation.CheckPermission", "entry.cgi", 3, 3, "FORM"),
                ["SYNO.FileStation.List"] = new("SYNO.FileStation.List", "entry.cgi", 2, 2, "FORM"),
            });
    }

    private static FileRecycleTarget Target(string path, bool recycle, bool isDirectory = false) =>
        new(
            ProfileId,
            path,
            path.Split('/').Last(),
            isDirectory,
            isDirectory ? 0 : 12,
            null,
            CanRead: true,
            CanDelete: true,
            IsRemote: false,
            IsVirtual: false,
            IsRecycle: recycle);

    private static JsonObject Page(params JsonObject[] items) => new()
    {
        ["files"] = new JsonArray(items.Select(item => (JsonNode)item.DeepClone()).ToArray()),
    };

    private static JsonObject Item(
        string path,
        string name,
        bool isDirectory,
        long size,
        bool canDelete = true) => new()
    {
        ["path"] = path,
        ["name"] = name,
        ["isdir"] = isDirectory,
        ["additional"] = new JsonObject
        {
            ["size"] = size,
            ["perm"] = new JsonObject
            {
                ["write"] = true,
                ["delete"] = canDelete,
            },
        },
    };

    private static readonly Guid ProfileId =
        Guid.Parse("11111111-1111-1111-1111-111111111111");

    private sealed class FakeApi(params JsonObject[] pages) : IDsmApiClient
    {
        private readonly Queue<JsonObject> _pages = new(pages);
        public int ListCount { get; private set; }
        public int PermissionCount { get; private set; }
        public int StartRecycleCount { get; private set; }
        public int RecycleStatusCount { get; private set; }
        public int StartCopyMoveCount { get; private set; }
        public int CopyMoveStatusCount { get; private set; }
        public string? LastCopyMoveSource { get; private set; }
        public string? LastCopyMoveDestination { get; private set; }
        public bool LastCopyMoveRemoveSource { get; private set; }

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

        public Task<JsonObject> CallReadJsonObjectAsync(NasProfile profile,
            DsmSession session, ApiCapability capability, int requiredVersion, string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            ListCount++;
            return Task.FromResult((JsonObject)_pages.Dequeue().DeepClone());
        }

        public Task<FilePermissionTransportResult> CheckFileMutationPermissionAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string folderPath, string name, CancellationToken cancellationToken = default)
        {
            PermissionCount++;
            return Task.FromResult(new FilePermissionTransportResult(
                FilePermissionTransportStatus.Allowed));
        }

        public Task<FileRecycleStartTransportResult> StartMoveToRecycleAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string sourcePath, CancellationToken cancellationToken = default)
        {
            StartRecycleCount++;
            return Task.FromResult(new FileRecycleStartTransportResult(
                FileMutationTransportStatus.ResponseReceived, "recycle-task"));
        }

        public Task<FileRecycleTaskTransportResult> ReadFileRecycleStatusAsync(
            NasProfile profile, DsmSession session, ApiCapability capability, string taskId,
            CancellationToken cancellationToken = default)
        {
            RecycleStatusCount++;
            return Task.FromResult(new FileRecycleTaskTransportResult(
                FileRecycleTaskTransportStatus.Finished));
        }

        public Task<FileCopyMoveStartTransportResult> StartFileCopyMoveAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string sourcePath, string destinationDirectoryPath, bool removeSource,
            CancellationToken cancellationToken = default)
        {
            StartCopyMoveCount++;
            LastCopyMoveSource = sourcePath;
            LastCopyMoveDestination = destinationDirectoryPath;
            LastCopyMoveRemoveSource = removeSource;
            return Task.FromResult(new FileCopyMoveStartTransportResult(
                FileMutationTransportStatus.ResponseReceived, "restore-task"));
        }

        public Task<FileCopyMoveTaskTransportResult> ReadFileCopyMoveStatusAsync(
            NasProfile profile, DsmSession session, ApiCapability capability, string taskId,
            CancellationToken cancellationToken = default)
        {
            CopyMoveStatusCount++;
            return Task.FromResult(new FileCopyMoveTaskTransportResult(
                FileCopyMoveTaskTransportStatus.Finished));
        }
    }
}
