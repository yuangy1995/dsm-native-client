using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveCompressionRepositoryContractTests
{
    [Theory]
    [InlineData(21)]
    [InlineData(205)]
    [InlineData(1001)]
    public async Task LargeSelectionReadsAllPagesAndCreatesOneCompleteArchive(int count)
    {
        var request = LargeRequest(count);
        var rows = request.Sources.Select(source => Item(source.Item.Path, source.Item.Name, source.Item.Size)).ToArray();
        var after = rows.Append(Item("/share/docs/archive.zip", "archive.zip", 12)).ToArray();
        var api = new FakeApi(Pages(rows).Concat(Pages(after)).ToArray());
        var result = await Repository(api).CompressAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(request.Sources.Select(source => source.Item.Path), api.Paths);
        Assert.Equal(1, api.StartCount); Assert.Equal(1, api.PermissionCount);
        Assert.Equal((count + 99) / 100 + (count + 100) / 100, api.ListCount);
        Assert.Equal("/share/docs/archive.zip", result.ConfirmedItem!.Path);
    }

    [Theory]
    [InlineData("metadata")]
    [InlineData("permission")]
    public async Task ChangedSourceBeyondFirstPagePreventsWholeSubmission(string kind)
    {
        var request = LargeRequest(205);
        var rows = request.Sources.Select(source => Item(source.Item.Path, source.Item.Name, source.Item.Size)).ToArray();
        if (kind == "metadata") rows[^1]["additional"]!["time"]!["mtime"] = 11L;
        else rows[^1]["additional"]!["perm"]!["read"] = false;
        var api = new FakeApi(Pages(rows));
        var result = await Repository(api).CompressAsync(request);
        Assert.False(result.Result.Submitted); Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(3, api.ListCount); Assert.Equal(0, api.PermissionCount); Assert.Equal(0, api.StartCount);
    }

    [Theory]
    [InlineData("duplicate")]
    [InlineData("parent-child")]
    [InlineData("remote")]
    public async Task InvalidTailOfLargeSelectionStillRejectsBeforeReading(string kind)
    {
        var request = LargeRequest(21); var sources = request.Sources.ToArray();
        if (kind == "duplicate") sources[^1] = sources[0];
        if (kind == "remote") sources[^1] = sources[^1] with { SourceKind = FileArchiveCompressionSourceKind.Remote };
        if (kind == "parent-child")
        {
            sources[0] = new(new("/share/docs/folder", "folder", true, 0, DateTimeOffset.FromUnixTimeSeconds(10), null, false, false));
            sources[^1] = new(new("/share/docs/folder/child", "child", false, 7, DateTimeOffset.FromUnixTimeSeconds(10), null, false, false));
        }
        var api = new FakeApi(); var result = await Repository(api).CompressAsync(request with { Sources = sources });
        Assert.False(result.Result.Submitted); Assert.Equal(0, api.ListCount); Assert.Equal(0, api.StartCount);
    }

    [Fact]
    public async Task ChangingTailOfUnknownLargeOperationCannotReplay()
    {
        var request = LargeRequest(205);
        var rows = request.Sources.Select(source => Item(source.Item.Path, source.Item.Name, source.Item.Size)).ToArray();
        var api = new FakeApi(Pages(rows).Concat(Pages(rows)).ToArray()) { StatusException = new IOException("synthetic") };
        var first = await Repository(api).CompressAsync(request);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        var sources = request.Sources.ToArray(); sources[^1] = new(new("/share/docs/changed.txt", "changed.txt", false, 7, DateTimeOffset.FromUnixTimeSeconds(10), null, false, false));
        var second = await Repository(api).CompressAsync(request with { Sources = sources });
        Assert.False(second.Result.Submitted); Assert.Equal(MutationErrorCategory.Conflict, second.Result.ErrorCategory);
        Assert.Equal(1, api.StartCount);
    }

    private FileArchiveCompressionRequest LargeRequest(int count) => new(Profile.Id,
        Enumerable.Range(0, count).Select(index => new FileArchiveCompressionSource(new FileItem($"/share/docs/f{index:D4}.txt", $"f{index:D4}.txt", false,
            7, DateTimeOffset.FromUnixTimeSeconds(10), null, false, false))).ToArray(), "archive");

    private static JsonObject[] Pages(JsonObject[] rows) => rows.Chunk(100).Select((chunk, page) => new JsonObject
    { ["offset"] = page * 100, ["total"] = rows.Length, ["files"] = new JsonArray(chunk.Select(item => item.DeepClone()).ToArray()) }).ToArray();

    [Fact]
    public async Task AdvancedSelectionReachesTransportAndReadbackUsesSelectedExtension()
    {
        var api = new FakeApi(Page(Item("/share/docs/a.txt", "a.txt", 7)),
            Page(Item("/share/docs/a.txt", "a.txt", 7), Item("/share/docs/advanced.7z", "advanced.7z", 12)));
        var request = Request() with { DestinationName = "advanced.zip",
            Options = new(FileArchiveFormat.SevenZip, FileArchiveCompressionLevel.Best, " synthetic ") };
        var result = await Repository(api).CompressAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal("/share/docs/advanced.7z", result.ConfirmedItem!.Path);
        Assert.Equal(request.Options, api.Options);
        Assert.Equal("/share/docs/advanced.7z", api.Destination);
        Assert.DoesNotContain(" synthetic ", request.ToString());
    }

    [Fact]
    public async Task ChangingPasswordDuringUnknownOperationCannotReplayOrAdoptIt()
    {
        var api = new FakeApi(Page(Item("/share/docs/a.txt", "a.txt", 7)),
            Page(Item("/share/docs/a.txt", "a.txt", 7)),
            Page(Item("/share/docs/a.txt", "a.txt", 7), Item("/share/docs/protected.7z", "protected.7z", 12)))
            { StatusException = new IOException("synthetic") };
        var request = Request() with { DestinationName = "protected",
            Options = new(FileArchiveFormat.SevenZip, FileArchiveCompressionLevel.Best, "synthetic-first") };
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, (await Repository(api).CompressAsync(request)).Result.Status);
        var changed = await Repository(api).CompressAsync(request with { Options = request.Options with { Password = "synthetic-other" } });
        Assert.Equal(MutationErrorCategory.Conflict, changed.Result.ErrorCategory);
        Assert.False(changed.Result.Submitted);
        api.StatusException = null;
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await Repository(api).CompressAsync(request)).Result.Status);
        Assert.Equal(1, api.StartCount);
    }

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
    public async Task LostStartReceiptCannotBeConfirmedByAnExistingFileOrReplayed()
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
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, reviewed.Result.Status);
        Assert.Null(reviewed.ConfirmedItem);
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
        Assert.Equal(2, api.StatusCount);
    }

    [Fact]
    public async Task PartialOutputWithoutFinishedTaskIsNotSuccessAndLaterStatusCanConfirm()
    {
        var output = Page(Item("/share/docs/a.txt", "a.txt", 7), Item("/share/docs/archive.zip", "archive.zip", 12));
        var api = new FakeApi(Page(Item("/share/docs/a.txt", "a.txt", 7)), output, (JsonObject)output.DeepClone())
            { TaskStatus = FileArchiveCompressionTaskTransportStatus.Unsupported };
        var first = await Repository(api).CompressAsync(Request());
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Null(first.ConfirmedItem);
        api.TaskStatus = FileArchiveCompressionTaskTransportStatus.Finished;
        var reviewed = await Repository(api).CompressAsync(Request());
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(2, api.StatusCount);
    }

    [Fact]
    public async Task FailedTaskWithPartialOutputIsFailure()
    {
        var api = new FakeApi(Page(Item("/share/docs/a.txt", "a.txt", 7)),
            Page(Item("/share/docs/a.txt", "a.txt", 7), Item("/share/docs/archive.zip", "archive.zip", 12)))
            { TaskStatus = FileArchiveCompressionTaskTransportStatus.ConfirmedFailure };
        var result = await Repository(api).CompressAsync(Request());
        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Null(result.ConfirmedItem);
        Assert.Equal(1, api.StartCount);
    }

    private DsmRepository Repository(IDsmApiClient api) => new(
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

    private FileArchiveCompressionRequest Request() => new(
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

    private readonly NasProfile Profile = new(
        Guid.NewGuid(),
        "NAS", "nas.example.invalid", null, "user");
    private DsmSession Session => new(Profile.Id, "synthetic", null, null);

    private sealed class FakeApi(params JsonObject[] pages) : IDsmApiClient
    {
        private readonly Queue<JsonObject> _pages = new(pages);
        public int ListCount { get; private set; }
        public int PermissionCount { get; private set; }
        public int StartCount { get; private set; }
        public int StatusCount { get; private set; }
        public FileArchiveCompressionOptions? Options { get; private set; }
        public string? Destination { get; private set; }
        public IReadOnlyList<string>? Paths { get; private set; }
        public Exception? StartException { get; set; }
        public Exception? StatusException { get; set; }
        public FileArchiveCompressionTaskTransportStatus TaskStatus { get; set; } = FileArchiveCompressionTaskTransportStatus.Finished;

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

        public Task<FileArchiveCompressionStartTransportResult> StartFileArchiveCompressionAsync(
            NasProfile profile, DsmSession session, ApiCapability capability,
            IReadOnlyList<string> sourcePaths, string destinationPath, FileArchiveCompressionOptions options,
            CancellationToken cancellationToken = default)
        {
            Options = options;
            Destination = destinationPath;
            return StartFileArchiveCompressionAsync(profile, session, capability, sourcePaths, destinationPath, cancellationToken);
        }

        public Task<FileArchiveCompressionStartTransportResult>
            StartFileArchiveCompressionAsync(
                NasProfile profile, DsmSession session, ApiCapability capability,
                IReadOnlyList<string> sourcePaths, string destinationPath,
                CancellationToken cancellationToken = default)
        {
            StartCount++;
            Paths = sourcePaths.ToArray();
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
                TaskStatus));
        }
    }
}
