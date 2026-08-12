using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveCompressionRepositoryContractTests
{
    [Fact]
    public async Task PreflightSubmitPollAndIndependentReadbackConfirmArchive()
    {
        var api = new FakeApi(
            Page(Item("/share/docs/a.txt", "a.txt", 7)),
            Page(
                Item("/share/docs/a.txt", "a.txt", 7),
                Item("/share/docs/archive.zip", "archive.zip", 12)));

        var result = await Repository(api).CompressAsync(Request());

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal("/share/docs/archive.zip", result.ConfirmedItem?.Path);
        Assert.Equal(1, api.PermissionCount);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(1, api.StatusCount);
        Assert.Equal(2, api.ListCount);
    }

    [Fact]
    public async Task ExistingTargetRejectsWholeRequestBeforePermissionAndSubmit()
    {
        var api = new FakeApi(Page(
            Item("/share/docs/a.txt", "a.txt", 7),
            Item("/share/docs/archive.zip", "archive.zip", 12)));

        var result = await Repository(api).CompressAsync(Request());

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory);
        Assert.Equal(0, api.PermissionCount);
        Assert.Equal(0, api.StartCount);
    }

    [Fact]
    public async Task UnknownSubmissionIsNeverReplayedAndLaterCallOnlyReadsBack()
    {
        var api = new FakeApi(
            Page(Item("/share/docs/a.txt", "a.txt", 7)),
            Page(Item("/share/docs/a.txt", "a.txt", 7)),
            Page(
                Item("/share/docs/a.txt", "a.txt", 7),
                Item("/share/docs/archive.zip", "archive.zip", 12)))
        {
            StartException = new IOException("synthetic"),
        };

        var first = await Repository(api).CompressAsync(Request());
        api.StartException = null;
        var reviewed = await Repository(api).CompressAsync(Request());

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(0, api.StatusCount);
    }

    [Fact]
    public async Task AuthenticationFailureAfterSubmitStillBlocksReplay()
    {
        var api = new FakeApi(
            Page(Item("/share/docs/a.txt", "a.txt", 7)),
            Page(
                Item("/share/docs/a.txt", "a.txt", 7),
                Item("/share/docs/archive.zip", "archive.zip", 12)))
        {
            StatusException = new DsmException(
                "synthetic", "synthetic", authenticationFailure: true),
        };

        await Assert.ThrowsAsync<DsmException>(() => Repository(api).CompressAsync(Request()));
        api.StatusException = null;
        var reviewed = await Repository(api).CompressAsync(Request());

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(1, api.StatusCount);
    }

    private static DsmRepository Repository(IDsmApiClient api) => new(
        Profile,
        Session,
        api,
        new Dictionary<string, ApiCapability>
        {
            ["SYNO.FileStation.Compress"] = new(
                "SYNO.FileStation.Compress", "entry.cgi", 3, 3, "FORM"),
            ["SYNO.FileStation.List"] = new(
                "SYNO.FileStation.List", "entry.cgi", 2, 2, "FORM"),
            ["SYNO.FileStation.CheckPermission"] = new(
                "SYNO.FileStation.CheckPermission", "entry.cgi", 3, 3, "FORM"),
        });

    private static FileArchiveCompressionRequest Request() => new(
        Profile.Id,
        [new FileArchiveCompressionSource(new FileItem(
            "/share/docs/a.txt", "a.txt", false, 7,
            DateTimeOffset.FromUnixTimeSeconds(10), null, false, false))],
        "archive");

    private static JsonObject Page(params JsonObject[] items) => new()
    {
        ["offset"] = 0,
        ["total"] = items.Length,
        ["files"] = new JsonArray(items.Select(item => (JsonNode)item).ToArray()),
    };

    private static JsonObject Item(string path, string name, long size) => new()
    {
        ["path"] = path,
        ["name"] = name,
        ["isdir"] = false,
        ["additional"] = new JsonObject
        {
            ["size"] = size,
            ["time"] = new JsonObject { ["mtime"] = 10L },
            ["perm"] = new JsonObject
            {
                ["read"] = true,
                ["write"] = false,
                ["delete"] = false,
            },
        },
    };

    private static readonly NasProfile Profile = new(
        Guid.Parse("11111111-1111-1111-1111-111111111111"),
        "NAS", "nas.example.invalid", null, "user");
    private static readonly DsmSession Session = new(Profile.Id, "synthetic", null, null);

    private sealed class FakeApi(params JsonObject[] pages) : IDsmApiClient
    {
        private readonly Queue<JsonObject> _pages = new(pages);
        public int ListCount { get; private set; }
        public int PermissionCount { get; private set; }
        public int StartCount { get; private set; }
        public int StatusCount { get; private set; }
        public Exception? StartException { get; set; }
        public Exception? StatusException { get; set; }

        public Uri GetBaseUri(NasProfile profile) => new("https://nas.example.invalid/");
        public Task<IReadOnlyDictionary<string, ApiCapability>> DiscoverAsync(
            NasProfile profile, CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
        public Task<DsmSession> LoginAsync(
            NasProfile profile, string password, string? otp,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
        public Task LogoutAsync(
            NasProfile profile, DsmSession session,
            CancellationToken cancellationToken = default) => Task.CompletedTask;
        public Task<JsonObject> CallAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string method, IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();
        public Task<byte[]> ReadFileRangeAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string remotePath, long offset, long length,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<JsonObject> CallReadJsonObjectAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            int requiredVersion, string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            ListCount++;
            return Task.FromResult(_pages.Dequeue());
        }

        public Task<FilePermissionTransportResult> CheckFileMutationPermissionAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            string folderPath, string name,
            CancellationToken cancellationToken = default)
        {
            PermissionCount++;
            return Task.FromResult(new FilePermissionTransportResult(
                FilePermissionTransportStatus.Allowed));
        }

        public Task<FileArchiveCompressionStartTransportResult>
            StartFileArchiveCompressionAsync(
                NasProfile profile, DsmSession session, ApiCapability capability,
                IReadOnlyList<string> sourcePaths, string destinationPath,
                CancellationToken cancellationToken = default)
        {
            StartCount++;
            if (StartException is not null)
            {
                return Task.FromException<FileArchiveCompressionStartTransportResult>(
                    StartException);
            }
            return Task.FromResult(new FileArchiveCompressionStartTransportResult(
                FileMutationTransportStatus.ResponseReceived, "synthetic-task"));
        }

        public Task<FileArchiveCompressionTaskTransportResult>
            ReadFileArchiveCompressionStatusAsync(
                NasProfile profile, DsmSession session, ApiCapability capability,
                string taskId, CancellationToken cancellationToken = default)
        {
            StatusCount++;
            if (StatusException is not null)
            {
                return Task.FromException<FileArchiveCompressionTaskTransportResult>(
                    StatusException);
            }
            return Task.FromResult(new FileArchiveCompressionTaskTransportResult(
                FileArchiveCompressionTaskTransportStatus.Finished));
        }
    }
}
