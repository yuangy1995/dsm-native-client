using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Archive;

public sealed class FileArchiveExtractionRepositoryContractTests
{
    [Fact]
    public async Task FolderWithOverFiveThousandItemsIsCompletelyChecked()
    {
        var profile = NewProfile();
        var api = new FakeApi([ArchiveItem("new.txt", false)]);
        api.ReadProvider = (method, parameters) =>
        {
            if (method == "getinfo") return Destination();
            var offset = int.Parse(parameters!["offset"]);
            var limit = int.Parse(parameters["limit"]);
            var total = api.StartCount == 0 ? 5001 : 5002;
            return new JsonObject { ["offset"] = offset, ["total"] = total,
                ["files"] = new JsonArray(Enumerable.Range(offset, Math.Min(limit, total - offset))
                    .Select(index => (JsonNode)(index == 0 ? Source() : File(index == 5001 ? "new.txt" : $"other-{index}.txt", 0))).ToArray()) };
        };
        var result = await Repository(profile, api).ExtractAsync(Request(profile));
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal("new.txt", Assert.Single(result.ConfirmedItems!).Name);
        Assert.Equal(103, api.FileListCount);
        Assert.Equal(1, api.StartCount);
    }

    [Fact]
    public async Task SubfolderAndNestedContentsAreReadBackIncludingSizes()
    {
        var profile = NewProfile();
        var api = new FakeApi([ArchiveItem("dir", true), ArchiveItem("a.txt", false) with { RelativePath = "dir/a.txt", Size = 12 }],
            FolderPage(Source()), Destination(), FolderPage(Source(), Folder("archive")),
            FolderPage(Item("/share/docs/archive/dir", "dir", true, 0, true)),
            FolderPage(Item("/share/docs/archive/dir/a.txt", "a.txt", false, 12, true)));
        var result = await Repository(profile, api).ExtractAsync(Request(profile) with { Options = new() { CreateSubfolder = true } });
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(3, result.ConfirmedItems!.Count);
        Assert.True(api.StartedOptions!.CreateSubfolder);
        Assert.Equal(5, api.FileListCount);
    }

    [Fact]
    public async Task ParentDirectoryAloneCannotConfirmNestedFiles()
    {
        var profile = NewProfile();
        var api = new FakeApi([ArchiveItem("dir", true), ArchiveItem("a.txt", false) with { RelativePath = "dir/a.txt", Size = 12 }],
            FolderPage(Source()), Destination(), FolderPage(Source(), Folder("dir")),
            FolderPage(Item("/share/docs/dir/a.txt", "a.txt", false, 4, true)));
        var result = await Repository(profile, api).ExtractAsync(Request(profile));
        Assert.Equal(MutationResultStatus.PartialSuccess, result.Result.Status);
        Assert.Equal(1, result.Result.Counts.Unknown);
        Assert.DoesNotContain(result.ConfirmedItems!, item => !item.IsDirectory);
    }

    [Fact]
    public async Task FlatteningUsesLeafNamesAndRejectsCollisionsBeforeWrite()
    {
        var profile = NewProfile();
        var entries = new[] { ArchiveItem("dir", true), ArchiveItem("a.txt", false) with { RelativePath = "dir/a.txt", Size = 12 } };
        var api = new FakeApi(entries, FolderPage(Source()), Destination(), FolderPage(Source(), File("a.txt", 12)));
        var request = Request(profile) with { Options = new() { KeepDirectoryStructure = false } };
        var result = await Repository(profile, api).ExtractAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal("/share/docs/a.txt", Assert.Single(result.ConfirmedItems!).Path);
        Assert.False(api.StartedOptions!.KeepDirectoryStructure);

        var otherProfile = NewProfile();
        var collision = new FakeApi([.. entries, ArchiveItem("a.txt", false)]);
        var rejected = await Repository(otherProfile, collision).ExtractAsync(request with { ProfileId = otherProfile.Id });
        Assert.Equal(MutationResultStatus.ConfirmedFailure, rejected.Result.Status);
        Assert.Equal(0, collision.StartCount);
        Assert.Equal(0, collision.FileListCount);
    }

    [Theory]
    [InlineData(false, true, false, MutationResultStatus.ConfirmedFailure)]
    [InlineData(true, false, false, MutationResultStatus.PermissionDenied)]
    [InlineData(true, true, true, MutationResultStatus.ConfirmedFailure)]
    [InlineData(true, true, false, MutationResultStatus.ConfirmedSuccess)]
    public async Task OverwriteNeedsExplicitConfirmationPermissionAndMatchingType(bool confirmed, bool writable, bool directory, MutationResultStatus expected)
    {
        var profile = NewProfile();
        var api = new FakeApi([ArchiveItem("a.txt", false) with { Size = 12 }],
            FolderPage(Source(), Item("/share/docs/a.txt", "a.txt", directory, 3, writable)), Destination(), FolderPage(Source(), File("a.txt", 12)));
        var result = await Repository(profile, api).ExtractAsync(Request(profile) with
            { Options = new() { Overwrite = true }, OverwriteConfirmed = confirmed });
        Assert.Equal(expected, result.Result.Status);
        Assert.Equal(expected == MutationResultStatus.ConfirmedSuccess ? 1 : 0, api.StartCount);
        if (!confirmed) Assert.Equal(0, api.ArchiveListCount);
    }

    [Fact]
    public async Task OverwriteCannotReplaceSourceArchive()
    {
        var profile = NewProfile(); var api = new FakeApi([ArchiveItem("archive.zip", false)]);
        var result = await Repository(profile, api).ExtractAsync(Request(profile) with { Options = new() { Overwrite = true }, OverwriteConfirmed = true });
        Assert.False(result.Result.Submitted);
        Assert.Equal(0, api.StartCount);
    }

    [Fact]
    public async Task ExistingSubdirectoryChecksNestedFilePermissionBeforeWrite()
    {
        var profile = NewProfile();
        var api = new FakeApi([ArchiveItem("dir", true), ArchiveItem("a.txt", false) with { RelativePath = "dir/a.txt" }],
            FolderPage(Source(), Folder("dir")), Destination(), FolderPage(Item("/share/docs/dir/a.txt", "a.txt", false, 3, false)));
        var result = await Repository(profile, api).ExtractAsync(Request(profile) with { Options = new() { Overwrite = true }, OverwriteConfirmed = true });
        Assert.Equal(MutationResultStatus.PermissionDenied, result.Result.Status);
        Assert.Equal(0, api.StartCount);
    }

    [Theory]
    [InlineData(null, "Ã¤.txt", "中文.txt", "chs", 2)]
    [InlineData(null, "normal.txt", "中文.txt", null, 1)]
    [InlineData(null, "Ã¤.txt", "Ã¤.txt", null, 2)]
    [InlineData("jpn", "日本語.txt", "中文.txt", "jpn", 1)]
    public async Task SelectedEncodingIsSharedByPreflightAndStart(string? requested, string original, string chinese, string? expected, int reads)
    {
        var profile = NewProfile();
        var output = expected == "chs" ? chinese : original;
        var api = new FakeApi([], FolderPage(Source()), Destination(), FolderPage(Source(), File(output, 0)))
        { ListProvider = options => [ArchiveItem(options.Codepage == "chs" ? chinese : original, false)] };
        var request = Request(profile) with { Options = new(" synthetic ", requested) };
        var result = await Repository(profile, api).ExtractAsync(request);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(reads, api.ArchiveListCount);
        Assert.Equal(expected, api.StartedOptions?.Codepage);
        Assert.Equal(" synthetic ", api.StartedOptions?.Password);
        Assert.All(api.ListedOptions, options => Assert.Equal(" synthetic ", options.Password));
        Assert.DoesNotContain(" synthetic ", request.ToString());
    }

    [Fact]
    public async Task WrongPasswordReturnsRecoverableErrorBeforeAnyWrite()
    {
        var profile = NewProfile();
        var api = new FakeApi([]) { ListProvider = _ => throw new DsmException("synthetic", "synthetic", 1403) };
        var result = await Repository(profile, api).ExtractAsync(Request(profile) with { Options = new("synthetic") });
        Assert.False(result.Result.Submitted);
        Assert.Equal("file.archive-extraction.password-required", result.Result.DiagnosticTag);
        Assert.Equal(0, api.StartCount);
        Assert.Equal(0, api.FileListCount);
    }

    [Fact]
    public async Task OptionalEncodingComparisonFailureKeepsOriginalButAuthenticationFailureStops()
    {
        var profile = NewProfile();
        var api = new FakeApi([], FolderPage(Source()), Destination(), FolderPage(Source(), File("Ã¤.txt", 0)))
        { ListProvider = options => options.Codepage == "chs" ? throw new IOException("synthetic") : [ArchiveItem("Ã¤.txt", false)] };
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await Repository(profile, api).ExtractAsync(Request(profile))).Result.Status);
        Assert.Null(api.StartedOptions?.Codepage);
        Assert.Equal(2, api.ArchiveListCount);

        var otherProfile = NewProfile();
        var denied = new FakeApi([])
        { ListProvider = options => options.Codepage == "chs" ? throw new DsmException("synthetic", "synthetic", authenticationFailure: true) : [ArchiveItem("Ã¤.txt", false)] };
        await Assert.ThrowsAsync<DsmException>(() => Repository(otherProfile, denied).ExtractAsync(Request(otherProfile)));
        Assert.Equal(0, denied.StartCount);
        Assert.Equal(0, denied.FileListCount);
    }

    [Fact]
    public async Task ExistingOutputNeedsFinishedTaskAndChangedPasswordCannotAdoptPendingOperation()
    {
        var profile = NewProfile();
        var api = new FakeApi([ArchiveItem("output.txt", false)], FolderPage(Source()), Destination(),
            FolderPage(Source(), File("output.txt", 0)), FolderPage(Source(), File("output.txt", 0)))
            { StatusResult = new(FileArchiveExtractionTaskTransportStatus.Unsupported) };
        var request = Request(profile) with { Options = new("synthetic") };
        var repository = Repository(profile, api);
        var first = await repository.ExtractAsync(request);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Null(first.ConfirmedItems);
        var changed = await repository.ExtractAsync(request with { Options = new("different") });
        Assert.Equal(MutationErrorCategory.Conflict, changed.Result.ErrorCategory);
        api.StatusResult = new(FileArchiveExtractionTaskTransportStatus.Finished);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, (await repository.ExtractAsync(request)).Result.Status);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(2, api.StatusCount);
    }

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
    public async Task CompleteArchiveWithMoreThanTwoHundredItemsIsExtractedAndReadBack()
    {
        var profile = NewProfile();
        var items = Enumerable.Range(0, 250)
            .Select(index => ArchiveItem($"item-{index}.txt", false)).ToArray();
        var outputs = items.Select(item => File(item.Name, 0)).Prepend(Source()).ToArray();
        var pages = Enumerable.Range(0, 3).Select(page => new JsonObject { ["offset"] = page * 100, ["total"] = outputs.Length,
            ["files"] = new JsonArray(outputs.Skip(page * 100).Take(100).Select(item => (JsonNode)item).ToArray()) });
        var api = new FakeApi(items, new[] { FolderPage(Source()), Destination() }.Concat(pages).ToArray());

        var result = await Repository(profile, api).ExtractAsync(Request(profile));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(250, result.ConfirmedItems!.Count);
        Assert.Equal(1, api.StartCount);
        Assert.Equal(5, api.FileListCount);
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
    public async Task ExplicitTaskFailureCannotConfirmPartialOutputContents()
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

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(0, result.Result.Counts.Succeeded);
        Assert.Equal(2, result.Result.Counts.Failed);
        Assert.Equal(0, result.Result.Counts.Unknown);
        Assert.Null(result.ConfirmedItems);
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
    public async Task LostReceiptStaysUnknownAcrossRepositoryRecreationEvenIfOutputExists()
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
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, reviewed.Result.Status);
        Assert.Equal(1, firstApi.StartCount);
        Assert.Equal(0, secondApi.StartCount);
        Assert.Equal(0, secondApi.ArchiveListCount);
        Assert.Equal(0, secondApi.StatusCount);
        Assert.Equal(0, secondApi.FileListCount);
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
        public Func<string, IReadOnlyDictionary<string, string>?, JsonObject>? ReadProvider { get; set; }
        public FileArchiveExtractionTaskTransportResult StatusResult { get; set; } = new(
            FileArchiveExtractionTaskTransportStatus.Finished);
        public List<FileArchiveExtractionOptions> ListedOptions { get; } = [];
        public FileArchiveExtractionOptions? StartedOptions { get; private set; }
        public Func<FileArchiveExtractionOptions, IReadOnlyList<FileArchiveExtractionListedItem>>? ListProvider { get; init; }
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

        public Task<IReadOnlyList<FileArchiveExtractionListedItem>> ListFileArchiveExtractionItemsAsync(
            NasProfile profile, DsmSession session, ApiCapability capability, string sourcePath,
            FileArchiveExtractionOptions options, CancellationToken cancellationToken = default)
        {
            ListedOptions.Add(options);
            if (ListProvider is null) return ListFileArchiveExtractionItemsAsync(profile, session, capability, sourcePath, cancellationToken);
            ArchiveListCount++;
            return Task.FromResult(ListProvider(options));
        }

        public Task<FileArchiveExtractionStartTransportResult> StartFileArchiveExtractionAsync(
            NasProfile profile, DsmSession session, ApiCapability capability, string sourcePath, string destinationFolder,
            FileArchiveExtractionOptions options, CancellationToken cancellationToken = default)
        {
            StartedOptions = options;
            return StartFileArchiveExtractionAsync(profile, session, capability, sourcePath, destinationFolder, cancellationToken);
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
            if (ReadProvider is not null) return Task.FromResult(ReadProvider(method, parameters));
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
