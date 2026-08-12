using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveExtractionRepositoryContractTests
{
    [Fact]
    public async Task PreflightSubmitPollAndReadbackConfirmAllTopLevelOutputs()
    {
        var profile = NewProfile();
        var api = new FakeApi(
            [ArchiveItem("folder", true), ArchiveItem("zero.txt", false)],
            FolderPage(Source()),
            Destination(),
            FolderPage(Source(), Folder("folder"), File("zero.txt", 0)));

        var result = await Repository(profile, api).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(2, result.ConfirmedItems?.Count);
        Assert.Contains(result.ConfirmedItems!, item => item.Name == "zero.txt" && item.Size == 0);
        Assert.Equal(1, api.ArchiveListCount);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(1, api.StatusCount);
        Assert.Equal(3, api.FileListCount);
    }

    [Fact]
    public async Task TwoHundredItemsAreRejectedAsPossiblyTruncatedBeforeSubmit()
    {
        var profile = NewProfile();
        var items = Enumerable.Range(0, 200)
            .Select(index => ArchiveItem($"item-{index}.txt", false)).ToArray();
        var api = new FakeApi(items);

        var result = await Repository(profile, api).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal("file.archive-extraction.archive-list-truncated", result.Result.DiagnosticTag);
        Assert.Equal(0, api.StartCount);
        Assert.Equal(0, api.FileListCount);
    }

    [Theory]
    [InlineData("../escape")]
    [InlineData("folder/name")]
    [InlineData("bad\\name")]
    [InlineData(".")]
    [InlineData("bad\tname")]
    public async Task DangerousTopLevelNameIsRejectedBeforeSubmit(string name)
    {
        var profile = NewProfile();
        var api = new FakeApi([ArchiveItem(name, false)]);

        var result = await Repository(profile, api).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(0, api.StartCount);
        Assert.Equal(0, api.FileListCount);
    }

    [Fact]
    public async Task CaseInsensitiveDuplicateTopLevelNamesAreRejectedBeforeSubmit()
    {
        var profile = NewProfile();
        var api = new FakeApi(
            [ArchiveItem("Readme.txt", false), ArchiveItem("README.TXT", false)]);

        var result = await Repository(profile, api).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(0, api.StartCount);
    }

    [Fact]
    public async Task CaseInsensitiveExistingOutputRejectsBeforeSubmit()
    {
        var profile = NewProfile();
        var api = new FakeApi(
            [ArchiveItem("Readme.txt", false)],
            FolderPage(Source(), File("README.TXT", 4)),
            Destination());

        var result = await Repository(profile, api).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory);
        Assert.Equal(0, api.StartCount);
    }

    [Fact]
    public async Task ChangedSourceBaselineAndReadOnlyDestinationRejectBeforeSubmit()
    {
        var changedProfile = NewProfile();
        var changedApi = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Item("/share/docs/archive.zip", "archive.zip", false, 12, false)),
            Destination());
        var changed = await Repository(changedProfile, changedApi)
            .ExtractAsync(Request(changedProfile));

        var readOnlyProfile = NewProfile();
        var readOnlyApi = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Source()),
            Destination(canWrite: false));
        var readOnly = await Repository(readOnlyProfile, readOnlyApi)
            .ExtractAsync(Request(readOnlyProfile));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, changed.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, changed.Result.ErrorCategory);
        Assert.Equal(MutationResultStatus.PermissionDenied, readOnly.Result.Status);
        Assert.Equal(0, changedApi.StartCount);
        Assert.Equal(0, readOnlyApi.StartCount);
    }

    [Fact]
    public async Task TypeMismatchNeverConfirmsCompleteSuccess()
    {
        var profile = NewProfile();
        var api = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Source()),
            Destination(),
            FolderPage(Source(), Folder("output.txt")));

        var result = await Repository(profile, api).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        Assert.Null(result.ConfirmedItems);
        Assert.Equal(1, result.Result.Counts.Unknown);
    }

    [Fact]
    public async Task ExplicitTaskFailureWithNoOutputIsConfirmedFailure()
    {
        var profile = NewProfile();
        var api = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Source()),
            Destination(),
            FolderPage(Source()))
        {
            StatusResult = new FileArchiveExtractionTaskTransportResult(
                FileArchiveExtractionTaskTransportStatus.ConfirmedFailure,
                MutationErrorCategory.Server,
                "file.archive-extraction.status-failure"),
        };

        var result = await Repository(profile, api).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(MutationErrorCategory.Server, result.Result.ErrorCategory);
        Assert.Equal(1, result.Result.Counts.Failed);
    }

    [Fact]
    public async Task ExplicitTaskFailureWithPartialOutputReportsRemainingFailure()
    {
        var profile = NewProfile();
        var api = new FakeApi(
            [ArchiveItem("one.txt", false), ArchiveItem("two.txt", false)],
            FolderPage(Source()),
            Destination(),
            FolderPage(Source(), File("one.txt", 0)))
        {
            StatusResult = new FileArchiveExtractionTaskTransportResult(
                FileArchiveExtractionTaskTransportStatus.ConfirmedFailure,
                MutationErrorCategory.Server,
                "file.archive-extraction.status-failure"),
        };

        var result = await Repository(profile, api).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.PartialSuccess, result.Result.Status);
        Assert.Equal(1, result.Result.Counts.Succeeded);
        Assert.Equal(1, result.Result.Counts.Failed);
        Assert.Equal(0, result.Result.Counts.Unknown);
        Assert.Single(result.ConfirmedItems!);
    }

    [Fact]
    public async Task PartialReadbackReportsCountsAndLaterSameRequestOnlyReadsBack()
    {
        var profile = NewProfile();
        var api = new FakeApi(
            [ArchiveItem("one.txt", false), ArchiveItem("two", true)],
            FolderPage(Source()),
            Destination(),
            FolderPage(Source(), File("one.txt", 0)),
            FolderPage(Source(), File("one.txt", 0), Folder("two")));
        var repository = Repository(profile, api);

        var first = await repository.ExtractAsync(Request(profile));
        var reviewed = await repository.ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.PartialSuccess, first.Result.Status);
        Assert.Equal(1, first.Result.Counts.Succeeded);
        Assert.Equal(1, first.Result.Counts.Unknown);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(1, api.ArchiveListCount);
    }

    [Fact]
    public async Task UnknownReviewSurvivesDifferentApiClientAndRepositoryForSameProfile()
    {
        var profile = NewProfile();
        var firstApi = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Source()),
            Destination(),
            FolderPage(Source()))
        {
            StartException = new IOException("synthetic"),
        };
        var secondApi = new FakeApi(
            [],
            FolderPage(Source(), File("output.txt", 0)));

        var first = await Repository(profile, firstApi).ExtractAsync(Request(profile));
        var reviewed = await Repository(profile, secondApi).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, firstApi.StartCount);
        Assert.Equal(0, secondApi.StartCount);
        Assert.Equal(0, secondApi.ArchiveListCount);
        Assert.Equal(1, secondApi.FileListCount);
    }

    [Fact]
    public async Task AuthenticationFailureAfterSubmitSurvivesReconnectWithoutReplay()
    {
        var profile = NewProfile();
        var firstApi = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Source()),
            Destination())
        {
            StatusException = new DsmException(
                "synthetic", "synthetic", authenticationFailure: true),
        };

        await Assert.ThrowsAsync<DsmException>(() =>
            Repository(profile, firstApi).ExtractAsync(Request(profile)));

        var secondApi = new FakeApi(
            [],
            FolderPage(Source(), File("output.txt", 0)));
        var reviewed = await Repository(profile, secondApi).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, firstApi.StartCount);
        Assert.Equal(0, secondApi.StartCount);
        Assert.Equal(0, secondApi.ArchiveListCount);
    }

    [Fact]
    public async Task AuthenticationFailureDuringFinalReadbackSurvivesReconnectWithoutReplay()
    {
        var profile = NewProfile();
        var firstApi = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Source()),
            Destination())
        {
            FileReadException = new DsmException(
                "synthetic", "synthetic", authenticationFailure: true),
            FileReadExceptionOnCall = 3,
        };

        await Assert.ThrowsAsync<DsmException>(() =>
            Repository(profile, firstApi).ExtractAsync(Request(profile)));

        var secondApi = new FakeApi(
            [],
            FolderPage(Source(), File("output.txt", 0)));
        var reviewed = await Repository(profile, secondApi).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, reviewed.Result.Status);
        Assert.Equal(1, firstApi.StartCount);
        Assert.Equal(0, secondApi.StartCount);
        Assert.Equal(0, secondApi.ArchiveListCount);
    }

    [Fact]
    public async Task PendingReviewBlocksDifferentArchiveInSameDestination()
    {
        var profile = NewProfile();
        var firstApi = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Source()),
            Destination(),
            FolderPage(Source()))
        {
            StartException = new IOException("synthetic"),
        };
        var first = await Repository(profile, firstApi).ExtractAsync(Request(profile));

        var secondApi = new FakeApi([ArchiveItem("other.txt", false)]);
        var second = await Repository(profile, secondApi).ExtractAsync(
            Request(profile, "other.zip"));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, second.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, second.Result.ErrorCategory);
        Assert.Equal(0, secondApi.ArchiveListCount);
        Assert.Equal(0, secondApi.StartCount);
    }

    [Fact]
    public async Task PendingExtractionReviewBlocksCompressionInSameDestination()
    {
        var profile = NewProfile();
        var firstApi = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Source()),
            Destination(),
            FolderPage(Source()))
        {
            StartException = new IOException("synthetic"),
        };
        _ = await Repository(profile, firstApi).ExtractAsync(Request(profile));

        var repository = Repository(profile, new FakeApi([]));
        var compression = await repository.CompressAsync(new FileArchiveCompressionRequest(
            profile.Id,
            [new FileArchiveCompressionSource(new FileItem(
                "/share/docs/input.txt", "input.txt", false, 1,
                DateTimeOffset.FromUnixTimeSeconds(10), null, false, false))],
            "new.zip"));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, compression.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, compression.Result.ErrorCategory);
    }

    [Fact]
    public async Task SameProfileSameFolderConcurrentRepositoriesAllowOnlyOneStart()
    {
        var profile = NewProfile();
        var gate = new TaskCompletionSource<FileArchiveExtractionStartTransportResult>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var firstApi = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Source()),
            Destination(),
            FolderPage(Source(), File("output.txt", 0)))
        {
            StartGate = gate,
        };
        var secondApi = new FakeApi(
            [ArchiveItem("other.txt", false)],
            FolderPage(Source("other.zip")),
            Destination(),
            FolderPage(Source("other.zip"), File("other.txt", 0)));

        var firstTask = Repository(profile, firstApi).ExtractAsync(Request(profile));
        await firstApi.StartEntered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var second = await Repository(profile, secondApi).ExtractAsync(
            Request(profile, "other.zip"));
        gate.SetResult(new FileArchiveExtractionStartTransportResult(
            FileMutationTransportStatus.ResponseReceived, "synthetic-task"));
        var first = await firstTask;

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, second.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, second.Result.ErrorCategory);
        Assert.Equal(1, firstApi.StartCount);
        Assert.Equal(0, secondApi.StartCount);
        Assert.Equal(0, secondApi.ArchiveListCount);
    }

    [Fact]
    public async Task CancellationWithKnownTaskAttemptsStopAndKeepsReview()
    {
        var profile = NewProfile();
        using var cancellation = new CancellationTokenSource();
        var api = new FakeApi(
            [ArchiveItem("output.txt", false)],
            FolderPage(Source()),
            Destination(),
            FolderPage(Source()))
        {
            OnStart = cancellation.Cancel,
        };

        var result = await Repository(profile, api)
            .ExtractAsync(Request(profile), cancellation.Token);

        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission,
            result.Result.Status);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(1, api.StopCount);
    }

    private static DsmRepository Repository(NasProfile profile, IDsmApiClient api) => new(
        profile,
        new DsmSession(profile.Id, "synthetic", null, null),
        api,
        new Dictionary<string, ApiCapability>
        {
            ["SYNO.FileStation.Extract"] = new(
                "SYNO.FileStation.Extract", "entry.cgi", 2, 2, "FORM"),
            ["SYNO.FileStation.List"] = new(
                "SYNO.FileStation.List", "entry.cgi", 2, 2, "FORM"),
        });

    private static FileArchiveExtractionRequest Request(
        NasProfile profile,
        string sourceName = "archive.zip") => new(
        profile.Id,
        new FileArchiveExtractionSource(new FileItem(
            $"/share/docs/{sourceName}", sourceName, false, 11,
            DateTimeOffset.FromUnixTimeSeconds(10), null, false, false)),
        "/share/docs");

    private static NasProfile NewProfile() => new(
        Guid.NewGuid(), "NAS", "nas.example.invalid", null, "user");

    private static JsonObject FolderPage(params JsonObject[] items) => new()
    {
        ["offset"] = 0,
        ["total"] = items.Length,
        ["files"] = new JsonArray(items.Select(item => (JsonNode)item).ToArray()),
    };

    private static JsonObject Destination(bool canWrite = true) => new()
    {
        ["files"] = new JsonArray(Item(
            "/share/docs", "docs", true, 0, canWrite)),
    };

    private static JsonObject Source(string name = "archive.zip") =>
        Item($"/share/docs/{name}", name, false, 11, false);

    private static JsonObject File(string name, long size) =>
        Item($"/share/docs/{name}", name, false, size, false);

    private static JsonObject Folder(string name) =>
        Item($"/share/docs/{name}", name, true, 0, true);

    private static JsonObject Item(
        string path,
        string name,
        bool isDirectory,
        long size,
        bool canWrite) => new()
    {
        ["path"] = path,
        ["name"] = name,
        ["isdir"] = isDirectory,
        ["additional"] = new JsonObject
        {
            ["size"] = size,
            ["time"] = new JsonObject { ["mtime"] = 10L },
            ["perm"] = new JsonObject
            {
                ["read"] = true,
                ["write"] = canWrite,
                ["delete"] = false,
            },
        },
    };

    private static FileArchiveExtractionListedItem ArchiveItem(
        string name,
        bool isDirectory) => new(name, isDirectory);

    private sealed class FakeApi(
        IReadOnlyList<FileArchiveExtractionListedItem> archiveItems,
        params JsonObject[] fileReads) : IDsmApiClient
    {
        private readonly Queue<JsonObject> _fileReads = new(fileReads);
        public int ArchiveListCount { get; private set; }
        public int FileListCount { get; private set; }
        public int StartCount { get; private set; }
        public int StatusCount { get; private set; }
        public int StopCount { get; private set; }
        public Exception? StartException { get; init; }
        public Exception? StatusException { get; init; }
        public Exception? FileReadException { get; init; }
        public int FileReadExceptionOnCall { get; init; }
        public FileArchiveExtractionTaskTransportResult StatusResult { get; init; } = new(
            FileArchiveExtractionTaskTransportStatus.Finished);
        public Action? OnStart { get; init; }
        public TaskCompletionSource<FileArchiveExtractionStartTransportResult>? StartGate
        {
            get;
            init;
        }
        public TaskCompletionSource StartEntered { get; } = new(
            TaskCreationOptions.RunContinuationsAsynchronously);

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

        public Task<IReadOnlyList<FileArchiveExtractionListedItem>>
            ListFileArchiveExtractionItemsAsync(
                NasProfile profile,
                DsmSession session,
                ApiCapability capability,
                string sourcePath,
                CancellationToken cancellationToken = default)
        {
            ArchiveListCount++;
            return Task.FromResult(archiveItems);
        }

        public Task<JsonObject> CallReadJsonObjectAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            int requiredVersion,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            FileListCount++;
            if (FileReadException is not null && FileListCount == FileReadExceptionOnCall)
                return Task.FromException<JsonObject>(FileReadException);
            return Task.FromResult(_fileReads.Dequeue());
        }

        public async Task<FileArchiveExtractionStartTransportResult>
            StartFileArchiveExtractionAsync(
                NasProfile profile,
                DsmSession session,
                ApiCapability capability,
                string sourcePath,
                string destinationFolder,
                CancellationToken cancellationToken = default)
        {
            StartCount++;
            StartEntered.TrySetResult();
            OnStart?.Invoke();
            if (StartException is not null)
                throw StartException;
            if (StartGate is not null)
                return await StartGate.Task;
            return new FileArchiveExtractionStartTransportResult(
                FileMutationTransportStatus.ResponseReceived, "synthetic-task");
        }

        public Task<FileArchiveExtractionTaskTransportResult>
            ReadFileArchiveExtractionStatusAsync(
                NasProfile profile,
                DsmSession session,
                ApiCapability capability,
                string taskId,
                CancellationToken cancellationToken = default)
        {
            StatusCount++;
            if (cancellationToken.IsCancellationRequested)
                return Task.FromCanceled<FileArchiveExtractionTaskTransportResult>(
                    cancellationToken);
            if (StatusException is not null)
                return Task.FromException<FileArchiveExtractionTaskTransportResult>(
                    StatusException);
            return Task.FromResult(StatusResult);
        }


        public Task<FileArchiveExtractionStopTransportResult>
            StopFileArchiveExtractionAsync(
                NasProfile profile,
                DsmSession session,
                ApiCapability capability,
                string taskId,
                CancellationToken cancellationToken = default)
        {
            StopCount++;
            return Task.FromResult(new FileArchiveExtractionStopTransportResult(
                FileMutationTransportStatus.ResponseReceived));
        }
    }
}
