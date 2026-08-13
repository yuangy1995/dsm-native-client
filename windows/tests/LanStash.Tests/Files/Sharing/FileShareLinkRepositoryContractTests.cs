using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Files.Sharing;

public sealed class FileShareLinkRepositoryContractTests
{
    private static readonly Guid ProfileId = Guid.Parse("11111111-1111-1111-1111-111111111111");
    private static readonly DateTimeOffset Modified = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

    [Fact]
    public async Task PhotoMediaBaselineUsesTheExistingReadPreflightAndStillChecksRevision()
    {
        var api = new SharingApiClient(
            [TargetResponse(false, owner: "another-user"), LinkPage(0), LinkPage(1, Link("new", "/share/a.txt"))],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));

        var result = await Repository(api).CreateFileShareLinkAsync(new(
            Target(false) with
            {
                Owner = null,
                CanWrite = false,
                CanDelete = false,
                Baseline = FileShareLinkTargetBaseline.PhotoMedia,
            }));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(1, api.Requests.Count(request => request.Method == "getinfo"));
    }

    [Fact]
    public async Task ChangedOrUnreadablePhotoMediaBaselineMakesZeroWrites()
    {
        var changedResponse = TargetResponse(false);
        changedResponse["files"]![0]!["size"] = 11;
        var changedApi = new SharingApiClient([changedResponse], UnsupportedTransport());
        var unreadableApi = new SharingApiClient(
            [TargetResponse(false, canRead: false)],
            UnsupportedTransport());
        var target = Target(false) with
        {
            Owner = null,
            CanWrite = false,
            CanDelete = false,
            Baseline = FileShareLinkTargetBaseline.PhotoMedia,
        };

        var changed = await Repository(changedApi).CreateFileShareLinkAsync(new(target));
        var unreadable = await Repository(unreadableApi).CreateFileShareLinkAsync(new(target));

        Assert.Equal(MutationErrorCategory.Conflict, changed.Result.ErrorCategory);
        Assert.Equal(MutationErrorCategory.Conflict, unreadable.Result.ErrorCategory);
        Assert.Equal(0, changedApi.CreateCount);
        Assert.Equal(0, unreadableApi.CreateCount);
    }

    [Fact]
    public async Task PhotoMediaBaselineRejectsInventedFilePermissionsBeforeAnyRequest()
    {
        var api = new SharingApiClient([], UnsupportedTransport());
        var target = Target(false) with
        {
            Owner = null,
            CanWrite = true,
            CanDelete = false,
            Baseline = FileShareLinkTargetBaseline.PhotoMedia,
        };

        var result = await Repository(api).CreateFileShareLinkAsync(new(target));

        Assert.Equal(MutationErrorCategory.Validation, result.Result.ErrorCategory);
        Assert.Empty(api.Requests);
        Assert.Equal(0, api.CreateCount);
    }

    [Fact]
    public async Task ListUsesStrictBoundedPagination()
    {
        var api = new SharingApiClient(
            [
                LinkPageAt(0, 2, Link("one", "/share/a.txt")),
                LinkPageAt(1, 2, Link("two", "/share/folder")),
            ],
            UnsupportedTransport());

        var links = await Repository(api).ListFileShareLinksAsync();

        Assert.Equal(["one", "two"], links.Select(link => link.Id));
        Assert.Equal(2, api.Requests.Count);
        Assert.All(api.Requests, request =>
        {
            Assert.Equal("list", request.Method);
            Assert.Equal(3, request.Capability.MinVersion);
            Assert.Equal(3, request.Capability.MaxVersion);
        });
    }

    [Fact]
    public async Task DeleteConfirmsStableIdIsAbsentAfterOneSubmission()
    {
        var link = LinkModel("one", "/share/a.txt");
        var api = new SharingApiClient(
            [LinkPage(1, Link("one", "/share/a.txt")), LinkPage(0)],
            UnsupportedTransport(),
            deleteResult: new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived));

        var outcome = await Repository(api).DeleteFileShareLinkAsync(new(link));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.True(outcome.Result.Submitted);
        Assert.Equal("shareLinkDelete", outcome.Result.Operation);
        Assert.Equal("one", outcome.Link?.Id);
        Assert.Equal(1, api.DeleteCount);
        Assert.Equal("one", api.DeleteId);
    }

    [Fact]
    public async Task ChangedDeletionBaselineMakesZeroWrites()
    {
        var api = new SharingApiClient(
            [LinkPage(1, Link("one", "/share/a.txt", url: "https://share.invalid/changed"))],
            UnsupportedTransport(),
            deleteResult: new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived));

        var outcome = await Repository(api).DeleteFileShareLinkAsync(
            new(LinkModel("one", "/share/a.txt")));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, outcome.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, outcome.Result.ErrorCategory);
        Assert.False(outcome.Result.Submitted);
        Assert.Equal(0, api.DeleteCount);
    }

    [Fact]
    public async Task AlreadyAbsentDeletionTargetMakesZeroWritesAndRequestsRefresh()
    {
        var api = new SharingApiClient(
            [LinkPage(0)],
            UnsupportedTransport(),
            deleteResult: new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived));

        var outcome = await Repository(api).DeleteFileShareLinkAsync(
            new(LinkModel("one", "/share/a.txt")));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, outcome.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, outcome.Result.ErrorCategory);
        Assert.False(outcome.Result.Submitted);
        Assert.Equal(0, api.DeleteCount);
    }

    [Fact]
    public async Task UnknownDeleteBlocksReplayAndSecondAttemptOnlyReadsBack()
    {
        var link = LinkModel("one", "/share/a.txt");
        var api = new SharingApiClient(
            [
                LinkPage(1, Link("one", "/share/a.txt")),
                LinkPage(1, Link("one", "/share/a.txt")),
                LinkPage(0),
            ],
            UnsupportedTransport(),
            deleteResult: new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.SubmittedButUnverified,
                ErrorCategory: MutationErrorCategory.Network));
        var first = await Repository(api).DeleteFileShareLinkAsync(new(link));
        var second = await Repository(api).DeleteFileShareLinkAsync(new(link));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, second.Result.Status);
        Assert.Equal(1, api.DeleteCount);
        Assert.Equal(3, api.Requests.Count(request => request.Method == "list"));
    }

    [Fact]
    public async Task ConcurrentSameLinkDeletionAllowsOnlyOneSubmission()
    {
        var entered = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var link = LinkModel("one", "/share/a.txt");
        var api = new SharingApiClient(
            [LinkPage(1, Link("one", "/share/a.txt")), LinkPage(0)],
            UnsupportedTransport(),
            deleteResult: new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived),
            beforeDelete: async () =>
            {
                entered.SetResult(true);
                await release.Task;
            });
        var first = Repository(api).DeleteFileShareLinkAsync(new(link));
        await entered.Task;

        var duplicate = await Repository(api).DeleteFileShareLinkAsync(new(link));
        release.SetResult(true);
        var completed = await first;

        Assert.Equal(MutationErrorCategory.Conflict, duplicate.Result.ErrorCategory);
        Assert.False(duplicate.Result.Submitted);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, completed.Result.Status);
        Assert.Equal(1, api.DeleteCount);
    }

    [Fact]
    public async Task ConfirmedFileCreationUsesFixedContractsAndStrictReadback()
    {
        var api = new SharingApiClient(
            reads:
            [
                TargetResponse(isDirectory: false),
                LinkPage(0),
                LinkPage(1, Link(
                    "new",
                    "/share/a.txt",
                    password: true,
                    expiry: "2026-12-31",
                    url: "HTTPS://share.invalid/new")),
            ],
            createResult: new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));
        var repository = Repository(api);
        Assert.Equal(3, repository.ShareLinkAvailability.ResolvedVersion);

        var outcome = await repository.CreateFileShareLinkAsync(new(
            Target(isDirectory: false),
            Password: " secret ",
            ExpiresOn: new DateOnly(2026, 12, 31)));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal("shareLinkCreate", outcome.Result.Operation);
        Assert.Equal("new", outcome.Link?.Id);
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(" secret ", api.CreateParameters!["password"]);
        Assert.Equal("2026-12-31", api.CreateParameters["date_expired"]);
        Assert.Equal("[\"/share/a.txt\"]", api.CreateParameters["path"]);
        Assert.All(api.Requests, request => Assert.Equal("FORM", request.Capability.RequestFormat));
        Assert.Contains(api.Requests, request =>
            request.Capability.Name == "SYNO.FileStation.List" &&
            request.Capability.MinVersion == 2 && request.Capability.MaxVersion == 2);
        Assert.Contains(api.Requests, request =>
            request.Capability.Name == "SYNO.FileStation.Sharing" &&
            request.Capability.MinVersion == 3 && request.Capability.MaxVersion == 3);
    }

    [Fact]
    public async Task DirectoryBaselineDoesNotCompareSizeOrModifiedTime()
    {
        var api = new SharingApiClient(
            [TargetResponse(isDirectory: true), LinkPage(0), LinkPage(1, Link("new", "/share/folder"))],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));
        var target = Target(isDirectory: true) with { Size = 999, ModifiedAt = Modified.AddDays(1) };

        var result = await Repository(api).CreateFileShareLinkAsync(new(target));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task CapabilityProfileInputAndPasswordFailuresMakeZeroRequests()
    {
        var unavailableApi = new SharingApiClient([], UnsupportedTransport());
        var unavailable = Repository(unavailableApi, sharingVersion: 2);
        var wrongProfileApi = new SharingApiClient([], UnsupportedTransport());
        var invalidApi = new SharingApiClient([], UnsupportedTransport());

        var unavailableResult = await unavailable.CreateFileShareLinkAsync(new(Target(false)));
        var wrongProfileResult = await Repository(wrongProfileApi).CreateFileShareLinkAsync(
            new(Target(false) with { ProfileId = Guid.NewGuid() }));
        var invalidResult = await Repository(invalidApi).CreateFileShareLinkAsync(
            new(Target(false), new string('x', 17)));

        Assert.Equal(MutationResultStatus.Unsupported, unavailableResult.Result.Status);
        Assert.Equal(MutationResultStatus.Unsupported, wrongProfileResult.Result.Status);
        Assert.Equal(MutationErrorCategory.Validation, invalidResult.Result.ErrorCategory);
        Assert.Empty(unavailableApi.Requests);
        Assert.Empty(wrongProfileApi.Requests);
        Assert.Empty(invalidApi.Requests);
    }

    [Fact]
    public async Task UnreadableOrDriftedBaselinePreventsCreate()
    {
        var unreadable = new SharingApiClient(
            [TargetResponse(false, canRead: false)],
            UnsupportedTransport());
        var drifted = new SharingApiClient(
            [TargetResponse(false, owner: "changed")],
            UnsupportedTransport());

        var unreadableResult = await Repository(unreadable).CreateFileShareLinkAsync(new(Target(false)));
        var driftedResult = await Repository(drifted).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, unreadableResult.Result.Status);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, driftedResult.Result.Status);
        Assert.Equal(0, unreadable.CreateCount);
        Assert.Equal(0, drifted.CreateCount);
    }

    [Fact]
    public async Task MissingResponseIdCanClaimOnlyUniqueNewSamePathLink()
    {
        var api = new SharingApiClient(
            [
                TargetResponse(false),
                LinkPage(1, Link("old", "/share/a.txt")),
                LinkPage(2, Link("old", "/share/a.txt"), Link("new", "/share/a.txt")),
            ],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                CreateDataWithoutId()));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal("new", result.Link?.Id);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task ExistingOrAmbiguousLinksNeverImpersonateCreatedLink()
    {
        var api = new SharingApiClient(
            [
                TargetResponse(false),
                LinkPage(1, Link("old", "/share/a.txt")),
                LinkPage(3,
                    Link("old", "/share/a.txt"),
                    Link("new-1", "/share/a.txt"),
                    Link("new-2", "/share/a.txt")),
            ],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                CreateDataWithoutId()));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        Assert.Null(result.Link);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task SubmittedIdMustBeNewAndMatchExactPathAndOptions()
    {
        var api = new SharingApiClient(
            [
                TargetResponse(false),
                LinkPage(1, Link("old", "/share/a.txt")),
                LinkPage(2, Link("old", "/share/a.txt"), Link("other", "/share/a.txt")),
            ],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "old" }));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        Assert.Null(result.Link);
    }

    [Fact]
    public async Task PasswordOrExpiryMismatchNeverExposesLink()
    {
        var api = new SharingApiClient(
            [
                TargetResponse(false),
                LinkPage(0),
                LinkPage(1, Link("new", "/share/a.txt", password: false, expiry: "2026-12-30")),
            ],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));

        var result = await Repository(api).CreateFileShareLinkAsync(new(
            Target(false),
            Password: "secret",
            ExpiresOn: new DateOnly(2026, 12, 31)));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        Assert.Null(result.Link);
        Assert.Equal(1, api.CreateCount);
    }

    [Theory]
    [InlineData("duplicate")]
    [InlineData("total-drift")]
    [InlineData("invalid-url")]
    [InlineData("zero-progress")]
    [InlineData("offset-mismatch")]
    [InlineData("page-exceeds-total")]
    [InlineData("over-limit")]
    public async Task InvalidPreflightPaginationMakesZeroCreateRequests(string failure)
    {
        var reads = failure switch
        {
            "duplicate" => new[]
            {
                TargetResponse(false),
                LinkPage(2, Link("same", "/a"), Link("same", "/b")),
            },
            "total-drift" => new[]
            {
                TargetResponse(false),
                LinkPage(501, Enumerable.Range(0, 500).Select(index => Link($"id-{index}", $"/{index}")).ToArray()),
                LinkPageAt(500, 502, Link("last", "/last")),
            },
            "invalid-url" => new[]
            {
                TargetResponse(false),
                LinkPage(1, Link("bad", "/bad", url: "file:///bad")),
            },
            "zero-progress" => new[] { TargetResponse(false), LinkPage(1) },
            "offset-mismatch" => new[]
            {
                TargetResponse(false),
                LinkPageAt(1, 1, Link("bad", "/bad")),
            },
            "page-exceeds-total" => new[]
            {
                TargetResponse(false),
                LinkPageAt(0, 0, Link("bad", "/bad")),
            },
            _ => new[] { TargetResponse(false), LinkPage(5_001) },
        };
        var api = new SharingApiClient(reads, UnsupportedTransport());

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(0, api.CreateCount);
    }

    [Fact]
    public async Task UnknownOrCancelledSubmissionIsReadBackWithoutReplay()
    {
        foreach (var status in new[]
                 {
                     FileShareLinkTransportStatus.SubmittedButUnverified,
                     FileShareLinkTransportStatus.CancellationRequestedAfterSubmission,
                 })
        {
            var api = new SharingApiClient(
                [TargetResponse(false), LinkPage(0), LinkPage(1, Link("new", "/share/a.txt"))],
                new FileShareLinkTransportResult(status));

            var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

            Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
            Assert.Equal("new", result.Link?.Id);
            Assert.Equal(1, api.CreateCount);
        }
    }

    [Theory]
    [InlineData(FileShareLinkTransportStatus.SubmittedButUnverified)]
    [InlineData(FileShareLinkTransportStatus.CancellationRequestedAfterSubmission)]
    public async Task CallerCancellationAfterCreateStillUsesIndependentReadback(
        FileShareLinkTransportStatus status)
    {
        using var cancellation = new CancellationTokenSource();
        var api = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(1, Link("new", "/share/a.txt"))],
            new FileShareLinkTransportResult(status),
            () =>
            {
                cancellation.Cancel();
                return Task.CompletedTask;
            });

        var result = await Repository(api).CreateFileShareLinkAsync(
            new(Target(false)), cancellation.Token);

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal("new", result.Link?.Id);
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(4, api.Requests.Count);
    }

    [Fact]
    public async Task CallerCancellationAfterCreateCanRemainUnknownAfterIndependentReadback()
    {
        using var cancellation = new CancellationTokenSource();
        var api = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(0)],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.CancellationRequestedAfterSubmission),
            () =>
            {
                cancellation.Cancel();
                return Task.CompletedTask;
            });

        var result = await Repository(api).CreateFileShareLinkAsync(
            new(Target(false)), cancellation.Token);

        Assert.Equal(
            MutationResultStatus.CancellationRequestedAfterSubmission,
            result.Result.Status);
        Assert.True(result.Result.RequiresRefresh);
        Assert.Null(result.Link);
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(4, api.Requests.Count);
    }

    [Fact]
    public async Task CompletePaginationUsesExactOffsetsBeforeAndAfterCreate()
    {
        var firstPage = Enumerable.Range(0, 500)
            .Select(index => Link($"id-{index}", $"/share/{index}"))
            .ToArray();
        var lastOld = Link("id-500", "/share/500");
        var api = new SharingApiClient(
            [
                TargetResponse(false),
                LinkPageAt(0, 501, firstPage),
                LinkPageAt(500, 501, lastOld),
                LinkPageAt(0, 502, firstPage),
                LinkPageAt(500, 502, lastOld, Link("new", "/share/a.txt")),
            ],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Equal(
            new[] { "0", "500", "0", "500" },
            api.Requests
                .Where(request => request.Method == "list")
                .Select(request => request.Parameters["offset"])
                .ToArray());
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task MissingPasswordStateOrErroredCreateItemNeverConfirms()
    {
        var missingPassword = Link("new", "/share/a.txt");
        missingPassword.Remove("has_password");
        var missingApi = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(1, missingPassword)],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));
        var erroredApi = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(1, Link("new", "/share/a.txt"))],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject
                {
                    ["links"] = new JsonArray(new JsonObject
                    {
                        ["id"] = "new",
                        ["error"] = 1,
                    }),
                }));

        var missing = await Repository(missingApi).CreateFileShareLinkAsync(new(Target(false)));
        var errored = await Repository(erroredApi).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, missing.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, errored.Result.Status);
        Assert.Null(missing.Link);
        Assert.Null(errored.Link);
    }

    [Fact]
    public async Task StringEncodedPasswordStateAndPaginationNumbersAreRejected()
    {
        var badPassword = Link("new", "/share/a.txt");
        badPassword["has_password"] = "false";
        var badPasswordApi = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(1, badPassword)],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));
        var badPage = LinkPage(0);
        badPage["offset"] = "0";
        var badPageApi = new SharingApiClient(
            [TargetResponse(false), badPage],
            UnsupportedTransport());

        var passwordResult = await Repository(badPasswordApi)
            .CreateFileShareLinkAsync(new(Target(false)));
        var pageResult = await Repository(badPageApi)
            .CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, passwordResult.Result.Status);
        Assert.Null(passwordResult.Link);
        Assert.Equal(MutationResultStatus.ConfirmedFailure, pageResult.Result.Status);
        Assert.Equal(0, badPageApi.CreateCount);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("null")]
    [InlineData("empty")]
    [InlineData("numeric-nonzero")]
    [InlineData("bool")]
    public async Task InvalidExpiryFieldNeverConfirms(string failure)
    {
        var link = Link("new", "/share/a.txt");
        switch (failure)
        {
            case "missing":
                link.Remove("date_expired");
                break;
            case "null":
                link["date_expired"] = null;
                break;
            case "empty":
                link["date_expired"] = string.Empty;
                break;
            case "numeric-nonzero":
                link["date_expired"] = 1;
                break;
            default:
                link["date_expired"] = false;
                break;
        }
        var api = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(1, link)],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        Assert.Null(result.Link);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task NativeNumericZeroExpiryIsAccepted()
    {
        var link = Link("new", "/share/a.txt");
        link["date_expired"] = 0;
        var api = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(1, link)],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, result.Result.Status);
        Assert.Null(result.Link?.ExpiresOn);
    }

    [Theory]
    [InlineData("isdir")]
    [InlineData("read")]
    [InlineData("write")]
    [InlineData("delete")]
    [InlineData("size")]
    [InlineData("mtime")]
    public async Task StringEncodedPreflightFieldsPreventCreate(string field)
    {
        var target = TargetResponse(false);
        var item = (JsonObject)((JsonArray)target["files"]!)[0]!;
        var additional = (JsonObject)item["additional"]!;
        var permissions = (JsonObject)additional["perm"]!;
        if (field is "isdir" or "size")
        {
            item[field] = item[field]!.ToString();
        }
        else if (field == "mtime")
        {
            ((JsonObject)additional["time"]!)[field] = Modified.ToUnixTimeSeconds().ToString();
        }
        else
        {
            permissions[field] = permissions[field]!.ToString();
        }
        var api = new SharingApiClient([target], UnsupportedTransport());

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(0, api.CreateCount);
    }

    [Theory]
    [InlineData("/share/folder/")]
    [InlineData("/share/../file")]
    [InlineData("/share\\file")]
    [InlineData("//share/file")]
    public async Task InvalidDsmPathInReadbackNeverExposesLink(string path)
    {
        var api = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(1, Link("new", path))],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        Assert.Null(result.Link);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task MalformedPostWritePaginationIsUnverifiedWithoutReplay()
    {
        var api = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPageAt(1, 1, Link("new", "/share/a.txt"))],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                new JsonObject { ["id"] = "new" }));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        Assert.Null(result.Link);
        Assert.Equal(1, api.CreateCount);
    }

    [Theory]
    [InlineData("empty")]
    [InlineData("mixed")]
    [InlineData("multiple")]
    [InlineData("string-error")]
    [InlineData("non-object")]
    public async Task AmbiguousCreateDataNeverImpersonatesCreatedLink(string failure)
    {
        JsonNode data = failure switch
        {
            "empty" => new JsonObject(),
            "mixed" => new JsonObject
            {
                ["id"] = "new",
                ["links"] = new JsonArray(new JsonObject { ["id"] = "new", ["error"] = 0 }),
            },
            "multiple" => new JsonObject
            {
                ["links"] = new JsonArray(
                    new JsonObject { ["id"] = "new", ["error"] = 0 },
                    new JsonObject { ["id"] = "other", ["error"] = 0 }),
            },
            "string-error" => new JsonObject
            {
                ["links"] = new JsonArray(new JsonObject { ["id"] = "new", ["error"] = "0" }),
            },
            _ => new JsonArray(),
        };
        var api = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(1, Link("new", "/share/a.txt"))],
            new FileShareLinkTransportResult(FileShareLinkTransportStatus.ResponseReceived, data));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        Assert.Null(result.Link);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task UnknownSubmissionWithoutMatchingReadbackStaysUnverified()
    {
        var api = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(0)],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.SubmittedButUnverified,
                ErrorCategory: MutationErrorCategory.Network));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, result.Result.Status);
        Assert.True(result.Result.RequiresRefresh);
        Assert.Null(result.Link);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task CancellationBeforeSubmissionMakesZeroRequests()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var api = new SharingApiClient([], UnsupportedTransport());

        var result = await Repository(api).CreateFileShareLinkAsync(
            new(Target(false)), cancellation.Token);

        Assert.Equal(MutationResultStatus.CancelledBeforeSubmission, result.Result.Status);
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task ConcurrentSamePathClaimAllowsExactlyOneCreate()
    {
        var started = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new SharingApiClient(
            [TargetResponse(false), LinkPage(0), LinkPage(1, Link("new", "/share/a.txt"))],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ResponseReceived,
                CreateDataWithoutId()),
            async () =>
            {
                started.SetResult(true);
                await release.Task;
            });
        var repository = Repository(api);
        var first = repository.CreateFileShareLinkAsync(new(Target(false)));
        await started.Task;

        var duplicate = await repository.CreateFileShareLinkAsync(new(Target(false)));
        release.SetResult(true);
        var completed = await first;

        Assert.Equal(MutationErrorCategory.Conflict, duplicate.Result.ErrorCategory);
        Assert.False(duplicate.Result.Submitted);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, completed.Result.Status);
        Assert.Equal(1, api.CreateCount);
    }

    [Fact]
    public async Task ExplicitPermissionFailureIsSubmittedAndNeverReadBackOrReplayed()
    {
        var api = new SharingApiClient(
            [TargetResponse(false), LinkPage(0)],
            new FileShareLinkTransportResult(
                FileShareLinkTransportStatus.ConfirmedFailure,
                ErrorCategory: MutationErrorCategory.Permission,
                DiagnosticTag: "file.share.create.dsm-105"));

        var result = await Repository(api).CreateFileShareLinkAsync(new(Target(false)));

        Assert.Equal(MutationResultStatus.PermissionDenied, result.Result.Status);
        Assert.True(result.Result.Submitted);
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(3, api.Requests.Count);
    }

    private static DsmRepository Repository(
        IDsmApiClient api,
        int sharingVersion = 3,
        int listVersion = 2) => new(
        new NasProfile(ProfileId, "Synthetic", "nas.invalid", 5001, "tester"),
        new DsmSession(ProfileId, "synthetic-sid", null, null),
        api,
        new[]
        {
            new ApiCapability("SYNO.FileStation.Sharing", "entry.cgi", sharingVersion, sharingVersion, "FORM"),
            new ApiCapability("SYNO.FileStation.List", "entry.cgi", listVersion, listVersion, "FORM"),
        }.ToDictionary(item => item.Name, StringComparer.Ordinal));

    private static FileShareLinkTarget Target(bool isDirectory) => new(
        ProfileId,
        isDirectory ? "/share/folder" : "/share/a.txt",
        isDirectory ? "folder" : "a.txt",
        isDirectory,
        isDirectory ? 0 : 10,
        isDirectory ? null : Modified,
        "tester",
        CanWrite: true,
        CanDelete: true);

    private static JsonObject TargetResponse(
        bool isDirectory,
        bool canRead = true,
        string owner = "tester") => new()
    {
        ["files"] = new JsonArray(new JsonObject
        {
            ["path"] = isDirectory ? "/share/folder" : "/share/a.txt",
            ["name"] = isDirectory ? "folder" : "a.txt",
            ["isdir"] = isDirectory,
            ["size"] = isDirectory ? 999 : 10,
            ["additional"] = new JsonObject
            {
                ["owner"] = new JsonObject { ["user"] = owner },
                ["time"] = new JsonObject { ["mtime"] = Modified.ToUnixTimeSeconds() },
                ["perm"] = new JsonObject
                {
                    ["read"] = canRead,
                    ["write"] = true,
                    ["delete"] = true,
                },
            },
        }),
    };

    private static JsonObject LinkPage(int total, params JsonObject[] links) => LinkPageAt(0, total, links);

    private static JsonObject LinkPageAt(int offset, int total, params JsonObject[] links) => new()
    {
        ["offset"] = offset,
        ["total"] = total,
        ["links"] = new JsonArray(links.Select(link => link.DeepClone()).ToArray()),
    };

    private static JsonObject Link(
        string id,
        string path,
        bool password = false,
        string? expiry = null,
        string? url = null) => new()
    {
        ["id"] = id,
        ["path"] = path,
        ["url"] = url ?? $"https://share.invalid/{id}",
        ["has_password"] = password,
        ["date_expired"] = expiry ?? "0",
    };

    private static FileShareLink LinkModel(string id, string path) => new(
        id,
        path,
        new Uri($"https://share.invalid/{id}"),
        HasPassword: false,
        ExpiresOn: null);

    private static JsonObject CreateDataWithoutId() => new()
    {
        ["links"] = new JsonArray(new JsonObject { ["error"] = 0 }),
    };

    private static FileShareLinkTransportResult UnsupportedTransport() => new(
        FileShareLinkTransportStatus.Unsupported,
        ErrorCategory: MutationErrorCategory.Unsupported);

    private sealed record ReadRequest(
        ApiCapability Capability,
        string Method,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed class SharingApiClient(
        IEnumerable<JsonObject> reads,
        FileShareLinkTransportResult createResult,
        Func<Task>? beforeCreate = null,
        FileShareLinkTransportResult? deleteResult = null,
        Func<Task>? beforeDelete = null) : IDsmApiClient
    {
        private readonly Queue<JsonObject> _reads = new(reads.Select(item => item.DeepClone().AsObject()));
        public List<ReadRequest> Requests { get; } = [];
        public int CreateCount { get; private set; }
        public int DeleteCount { get; private set; }
        public string? DeleteId { get; private set; }
        public IReadOnlyDictionary<string, string>? CreateParameters { get; private set; }

        public async Task<FileShareLinkTransportResult> CreateFileShareLinkAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            IReadOnlyDictionary<string, string> parameters,
            CancellationToken cancellationToken = default)
        {
            CreateCount++;
            CreateParameters = new Dictionary<string, string>(parameters, StringComparer.Ordinal);
            Requests.Add(new ReadRequest(capability, "create", CreateParameters));
            if (beforeCreate is not null)
            {
                await beforeCreate();
            }
            return createResult;
        }

        public async Task<FileShareLinkTransportResult> DeleteFileShareLinkAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string id,
            CancellationToken cancellationToken = default)
        {
            DeleteCount++;
            DeleteId = id;
            Requests.Add(new ReadRequest(
                capability,
                "delete",
                new Dictionary<string, string> { ["id"] = id }));
            if (beforeDelete is not null)
            {
                await beforeDelete();
            }
            return deleteResult ?? UnsupportedTransport();
        }

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Requests.Add(new ReadRequest(
                capability,
                method,
                new Dictionary<string, string>(parameters!, StringComparer.Ordinal)));
            return Task.FromResult(_reads.Dequeue());
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
