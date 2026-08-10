using System.Text.Json;
using System.Text.Json.Nodes;
using LanStash.Domain;
using LanStash.Infrastructure;

namespace LanStash.Tests.Downloads;

public sealed class DownloadStationRepositoryContractTests
{
    private static readonly Guid ProfileId =
        Guid.Parse("11111111-1111-1111-1111-111111111111");

    [Theory]
    [InlineData(1, 1, DownloadStationAvailabilityStatus.Available, true)]
    [InlineData(1, 4, DownloadStationAvailabilityStatus.Available, true)]
    [InlineData(2, 4, DownloadStationAvailabilityStatus.Unavailable, false)]
    [InlineData(0, 0, DownloadStationAvailabilityStatus.Unavailable, false)]
    public void AvailabilityRequiresOfficialTaskCapabilityContainingVersionOne(
        int minimum,
        int maximum,
        DownloadStationAvailabilityStatus expected,
        bool moduleVisible)
    {
        var repository = CreateRepository(
            new DownloadRecordingApiClient(_ => EmptyPage()),
            Capability(PublicTaskApi, minimum, maximum));
        var contract = (IDownloadStationRepository)repository;

        Assert.Equal(ProfileId, contract.ProfileId);
        Assert.Equal(expected, contract.Availability.Status);
        Assert.Equal(moduleVisible, repository.AvailableModules.Contains(AppModule.Downloads));
        Assert.Equal(
            moduleVisible ? new[] { DownloadStationReadFeature.Tasks } : [],
            contract.Availability.SupportedFeatures.Order());
    }

    [Fact]
    public async Task OfficialTaskIsPreferredAndWireIsFixedToRecordedVersionAndParameters()
    {
        var api = new DownloadRecordingApiClient(_ => Page(
            7,
            8,
            TaskItem("task-1", "downloading")));
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi, 1, 9),
            Capability("SYNO.DownloadStation2.Task", 1, 2));

        var page = await repository.ListTasksAsync(7, 250);

        var request = Assert.Single(api.Requests);
        Assert.Equal(PublicTaskApi, request.ApiName);
        Assert.Equal("list", request.Method);
        Assert.Equal(1, request.Version);
        Assert.Equal(
            new[] { "additional", "limit", "offset" },
            request.Parameters.Keys.Order(StringComparer.Ordinal));
        Assert.Equal("7", request.Parameters["offset"]);
        Assert.Equal("100", request.Parameters["limit"]);
        Assert.Equal(
            "detail,transfer",
            request.Parameters["additional"]);
        Assert.Equal(7, page.SourceOffset);
        Assert.Equal(8, page.SourceTotal);
        Assert.False(page.HasMore);
    }

    [Fact]
    public async Task InternalTaskCapabilityAloneIsUnavailableAndIssuesNoRequest()
    {
        var api = new DownloadRecordingApiClient(_ => throw new InvalidOperationException());
        var repository = CreateRepository(
            api,
            Capability("SYNO.DownloadStation2.Task", 1, 2));
        var contract = (IDownloadStationRepository)repository;

        Assert.Equal(DownloadStationAvailabilityStatus.Unavailable, contract.Availability.Status);
        Assert.DoesNotContain(AppModule.Downloads, repository.AvailableModules);
        await Assert.ThrowsAsync<DsmException>(() => contract.ListTasksAsync(0, 100));
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task StringAndNumericIdsMapInvariantlyAndUnknownStatusKeepsRawValue()
    {
        var api = new DownloadRecordingApiClient(_ => Page(
            0,
            2,
            TaskItem("string-id", "downloading"),
            TaskItem(42, "future_state")));
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));

        var page = await repository.ListTasksAsync(0, 100);

        Assert.Equal(new[] { "string-id", "42" }, page.Tasks.Select(task => task.Id));
        Assert.Equal(DownloadTaskState.Downloading, page.Tasks[0].State);
        Assert.Equal(DownloadTaskState.Unknown, page.Tasks[1].State);
        Assert.Equal("future_state", page.Tasks[1].RawStatus);
        Assert.Equal("future_state", page.Tasks[1].Status);
        Assert.Equal(12L, page.Tasks[0].Downloaded);
        Assert.Equal(3L, page.Tasks[0].Uploaded);
        Assert.Equal(4L, page.Tasks[0].DownloadSpeed);
        Assert.Equal(5L, page.Tasks[0].UploadSpeed);
    }

    [Fact]
    public async Task ErrorDetailComesFromOfficialStatusExtraObject()
    {
        var task = TaskItem("error-task", "error");
        task["status_extra"] = new JsonObject
        {
            ["error_detail"] = "broken_link",
        };
        task["additional"]!["detail"]!["error_detail"] = "must-not-use";
        var repository = (IDownloadStationRepository)CreateRepository(
            new DownloadRecordingApiClient(_ => Page(0, 1, task)),
            Capability(PublicTaskApi));

        var page = await repository.ListTasksAsync(0, 100);

        Assert.Equal("broken_link", Assert.Single(page.Tasks).Error);
    }

    [Fact]
    public async Task SnapshotKeepsTaskPageWhenOptionalActivityRequestFails()
    {
        var api = new DownloadRecordingApiClient(request => request.ApiName switch
        {
            PublicTaskApi => Page(0, 1, TaskItem("safe-task", "paused")),
            PublicStatisticApi => throw new DsmException("synthetic", "synthetic"),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi),
            Capability(PublicStatisticApi));

        var snapshot = await repository.LoadSnapshotAsync(0, 100);

        Assert.Equal(ProfileId, snapshot.ProfileId);
        Assert.Equal("safe-task", Assert.Single(snapshot.Tasks.Tasks).Id);
        Assert.Equal(DownloadStationSectionStatus.Failed, snapshot.Activity.Status);
        Assert.Null(snapshot.Activity.Value);
        Assert.Equal(
            DownloadStationSectionStatus.Unavailable,
            snapshot.DefaultDestination.Status);
        Assert.Null(snapshot.DefaultDestination.Value);
        Assert.Collection(
            api.Requests,
            request => Assert.Equal(PublicTaskApi, request.ApiName),
            request =>
            {
                Assert.Equal(PublicStatisticApi, request.ApiName);
                Assert.Equal("getinfo", request.Method);
                Assert.Equal(1, request.Version);
                Assert.Empty(request.Parameters);
            });
    }

    [Fact]
    public async Task SnapshotKeepsTaskPageWhenOptionalActivityResponseIsMalformed()
    {
        var api = new DownloadRecordingApiClient(request => request.ApiName switch
        {
            PublicTaskApi => Page(0, 1, TaskItem("safe-task", "paused")),
            PublicStatisticApi => throw new JsonException("synthetic malformed response"),
            _ => throw new InvalidOperationException(request.ApiName),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi),
            Capability(PublicStatisticApi));

        var snapshot = await repository.LoadSnapshotAsync(0, 100);

        Assert.Equal("safe-task", Assert.Single(snapshot.Tasks.Tasks).Id);
        Assert.Equal(DownloadStationSectionStatus.Failed, snapshot.Activity.Status);
        Assert.Null(snapshot.Activity.Value);
    }

    [Fact]
    public async Task ValidActivitySummaryIsTypedAndUsesNoUnrecordedParameters()
    {
        var api = new DownloadRecordingApiClient(request => request.ApiName switch
        {
            PublicTaskApi => EmptyPage(),
            PublicStatisticApi => new JsonObject
            {
                ["speed_download"] = 10,
                ["speed_upload"] = 20,
                ["emule_speed_download"] = 30,
                ["emule_speed_upload"] = 40,
            },
            _ => throw new InvalidOperationException(),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi),
            Capability(PublicStatisticApi, 1, 5));

        var snapshot = await repository.LoadSnapshotAsync(0, 100);

        Assert.Equal(DownloadStationSectionStatus.Available, snapshot.Activity.Status);
        Assert.Equal(new DownloadActivitySummary(10, 20, 30, 40), snapshot.Activity.Value);
        var statistic = Assert.Single(api.Requests, item => item.ApiName == PublicStatisticApi);
        Assert.Equal(1, statistic.Version);
        Assert.Empty(statistic.Parameters);
    }

    [Fact]
    public async Task BtSearchCatalogUsesOfficialV1AndParsesTypedOptions()
    {
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "getModule" => new JsonObject
            {
                ["modules"] = new JsonArray(
                    new JsonObject
                    {
                        ["id"] = "provider-a",
                        ["title"] = "Provider A",
                        ["enabled"] = true,
                    },
                    new JsonObject
                    {
                        ["id"] = "provider-b",
                        ["title"] = "Provider B",
                        ["enabled"] = false,
                    }),
            },
            "getCategory" => new JsonObject
            {
                ["categories"] = new JsonArray(
                    new JsonObject
                    {
                        ["id"] = "_allcat_",
                        ["title"] = "All",
                    },
                    new JsonObject
                    {
                        ["id"] = "Books",
                        ["title"] = "Books",
                    }),
            },
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi),
            Capability(PublicBtSearchApi));

        var catalog = await repository.LoadBtSearchCatalogAsync();

        Assert.Equal(new[] { "provider-a", "provider-b" }, catalog.Modules.Select(item => item.Id));
        Assert.Equal(new[] { true, false }, catalog.Modules.Select(item => item.IsEnabled));
        Assert.Equal(new[] { "_allcat_", "Books" }, catalog.Categories.Select(item => item.Id));
        Assert.Contains(DownloadStationReadFeature.BtSearch, repository.Availability.SupportedFeatures);
        Assert.Collection(
            api.Requests,
            request =>
            {
                Assert.Equal(PublicBtSearchApi, request.ApiName);
                Assert.Equal(1, request.Version);
                Assert.Equal("getModule", request.Method);
                Assert.Empty(request.Parameters);
            },
            request =>
            {
                Assert.Equal(PublicBtSearchApi, request.ApiName);
                Assert.Equal(1, request.Version);
                Assert.Equal("getCategory", request.Method);
                Assert.Empty(request.Parameters);
            });
    }

    [Fact]
    public async Task BtSearchCatalogRejectsDuplicateMalformedAndNonNativeOptions()
    {
        var responses = new[]
        {
            (
                Modules: new JsonArray(
                    new JsonObject { ["id"] = "provider-a", ["title"] = "A", ["enabled"] = true },
                    new JsonObject { ["id"] = "provider-a", ["title"] = "B", ["enabled"] = false }),
                Categories: new JsonArray()
            ),
            (
                Modules: new JsonArray(
                    new JsonObject { ["id"] = "provider,a", ["title"] = "A", ["enabled"] = true }),
                Categories: new JsonArray()
            ),
            (
                Modules: new JsonArray(
                    new JsonObject { ["id"] = "provider-a", ["title"] = "A", ["enabled"] = "true" }),
                Categories: new JsonArray()
            ),
        };

        foreach (var (modules, categories) in responses)
        {
            var api = new DownloadRecordingApiClient(request => request.Method switch
            {
                "getModule" => new JsonObject { ["modules"] = modules.DeepClone() },
                "getCategory" => new JsonObject { ["categories"] = categories.DeepClone() },
                _ => throw new InvalidOperationException(request.Method),
            });
            var repository = (IDownloadStationRepository)CreateRepository(
                api,
                Capability(PublicTaskApi),
                Capability(PublicBtSearchApi));

            await Assert.ThrowsAsync<DsmException>(() => repository.LoadBtSearchCatalogAsync());
        }
    }

    [Fact]
    public async Task BtSearchSendsFilterSortDirectionAndAlwaysCleansFinishedTask()
    {
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "start" => new JsonObject { ["taskid"] = "search-1" },
            "list" => new JsonObject
            {
                ["finished"] = true,
                ["items"] = new JsonArray(
                    new JsonObject
                    {
                        ["title"] = "Linux Guide",
                        ["size"] = 1234,
                        ["date"] = "2026-08-01",
                        ["download_uri"] = "magnet:?xt=urn:btih:synthetic",
                        ["external_link"] = "https://example.invalid/item",
                        ["peers"] = 10,
                        ["seeds"] = 20,
                        ["leechs"] = 3,
                        ["module_title"] = "Provider A",
                    }),
            },
            "clean" => new JsonObject(),
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi),
            Capability(PublicBtSearchApi));

        var results = await repository.SearchBtAsync(new(
            ProfileId,
            "  linux  ",
            DownloadBtSearchModuleScope.Selected,
            new HashSet<string>(["provider-b", "provider-a"], StringComparer.Ordinal),
            "Books",
            DownloadBtSearchSort.Size,
            DownloadBtSearchDirection.Ascending,
            "  guide  "));

        var result = Assert.Single(results);
        Assert.Equal("Linux Guide", result.Title);
        Assert.Equal(1234, result.Size);
        Assert.Equal(20, result.Seeds);
        Assert.Equal(
            new[] { "start", "list", "clean" },
            api.Requests.Select(request => request.Method));
        Assert.Equal("linux", api.Requests[0].Parameters["keyword"]);
        Assert.Equal("provider-a,provider-b", api.Requests[0].Parameters["module"]);
        Assert.Equal("Books", api.Requests[1].Parameters["filter_category"]);
        Assert.Equal("guide", api.Requests[1].Parameters["filter_title"]);
        Assert.Equal("200", api.Requests[1].Parameters["limit"]);
        Assert.Equal("size", api.Requests[1].Parameters["sort_by"]);
        Assert.Equal("asc", api.Requests[1].Parameters["sort_direction"]);
        Assert.Equal("search-1", api.Requests[2].Parameters["taskid"]);
    }

    [Fact]
    public async Task BtSearchInvalidOptionsIssueNoRequestsAndListFailureStillCleans()
    {
        var invalidApi = new DownloadRecordingApiClient(_ => throw new InvalidOperationException());
        var invalidRepository = (IDownloadStationRepository)CreateRepository(
            invalidApi,
            Capability(PublicTaskApi),
            Capability(PublicBtSearchApi));

        await Assert.ThrowsAsync<ArgumentException>(() => invalidRepository.SearchBtAsync(new(
            ProfileId,
            "linux",
            DownloadBtSearchModuleScope.Selected,
            new HashSet<string>(StringComparer.Ordinal),
            null,
            DownloadBtSearchSort.Seeds,
            DownloadBtSearchDirection.Descending,
            string.Empty)));
        await Assert.ThrowsAsync<ArgumentException>(() =>
            invalidRepository.SearchBtAsync(new DownloadBtSearchRequest(ProfileId, "\nlinux")));
        await Assert.ThrowsAsync<ArgumentException>(() => invalidRepository.SearchBtAsync(new(
            ProfileId,
            "linux",
            DownloadBtSearchModuleScope.Enabled,
            new HashSet<string>(StringComparer.Ordinal),
            null,
            DownloadBtSearchSort.Seeds,
            DownloadBtSearchDirection.Descending,
            "guide\r")));
        Assert.Empty(invalidApi.Requests);

        var failingApi = new DownloadRecordingApiClient(request => request.Method switch
        {
            "start" => new JsonObject { ["taskid"] = "search-2" },
            "list" => throw new DsmException("synthetic", "synthetic"),
            "clean" => new JsonObject(),
            _ => throw new InvalidOperationException(request.Method),
        });
        var failingRepository = (IDownloadStationRepository)CreateRepository(
            failingApi,
            Capability(PublicTaskApi),
            Capability(PublicBtSearchApi));

        await Assert.ThrowsAsync<DsmException>(() =>
            failingRepository.SearchBtAsync(new DownloadBtSearchRequest(ProfileId, "linux")));
        Assert.Equal(
            new[] { "start", "list", "clean" },
            failingApi.Requests.Select(request => request.Method));
    }

    [Fact]
    public async Task BtSearchCleanupFailureDoesNotOverrideSuccessfulResults()
    {
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "start" => new JsonObject { ["taskid"] = "search-clean-success" },
            "list" => new JsonObject
            {
                ["finished"] = true,
                ["items"] = new JsonArray(
                    new JsonObject
                    {
                        ["title"] = "Linux",
                        ["download_uri"] = "magnet:?xt=urn:btih:clean-success",
                    }),
            },
            "clean" => throw new DsmException("synthetic-clean", "synthetic-clean"),
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi),
            Capability(PublicBtSearchApi));

        var result = await repository.SearchBtAsync(
            new DownloadBtSearchRequest(ProfileId, "linux"));

        Assert.Single(result);
        Assert.Equal(1, api.Requests.Count(request => request.Method == "clean"));
        Assert.Equal(
            new[] { "start", "list", "clean" },
            api.Requests.Select(request => request.Method));
    }

    [Fact]
    public async Task BtSearchCleanupFailureDoesNotReplaceOriginalListFailure()
    {
        var original = new DsmException("synthetic-list", "synthetic-list");
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "start" => new JsonObject { ["taskid"] = "search-clean-failure" },
            "list" => throw original,
            "clean" => throw new DsmException("synthetic-clean", "synthetic-clean"),
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi),
            Capability(PublicBtSearchApi));

        var error = await Assert.ThrowsAsync<DsmException>(() =>
            repository.SearchBtAsync(new DownloadBtSearchRequest(ProfileId, "linux")));

        Assert.Same(original, error);
        Assert.Equal(1, api.Requests.Count(request => request.Method == "clean"));
        Assert.Equal(
            new[] { "start", "list", "clean" },
            api.Requests.Select(request => request.Method));
    }

    [Fact]
    public async Task BtSearchCancellationSurvivesSingleFailingCleanupWithIndependentToken()
    {
        using var cancellation = new CancellationTokenSource();
        var api = new DownloadRecordingApiClient(request =>
        {
            if (request.Method == "start")
            {
                return new JsonObject { ["taskid"] = "search-cancelled" };
            }
            if (request.Method == "list")
            {
                cancellation.Cancel();
                throw new OperationCanceledException(cancellation.Token);
            }
            if (request.Method == "clean")
            {
                throw new DsmException("synthetic-clean", "synthetic-clean");
            }
            throw new InvalidOperationException(request.Method);
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi),
            Capability(PublicBtSearchApi));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            repository.SearchBtAsync(
                new DownloadBtSearchRequest(ProfileId, "linux"),
                cancellation.Token));

        Assert.Equal(1, api.Requests.Count(request => request.Method == "clean"));
        Assert.Equal(
            new[] { "start", "list", "clean" },
            api.Requests.Select(request => request.Method));
    }

    [Fact]
    public async Task BtSearchRejectsMoreThanRequestedResultLimitAndCleansExactlyOnce()
    {
        var items = new JsonArray();
        for (var index = 0; index < 201; index++)
        {
            items.Add(new JsonObject
            {
                ["title"] = $"Synthetic {index}",
                ["download_uri"] = $"magnet:?xt=urn:btih:synthetic-{index}",
            });
        }
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "start" => new JsonObject { ["taskid"] = "search-too-many" },
            "list" => new JsonObject
            {
                ["finished"] = true,
                ["items"] = items,
            },
            "clean" => new JsonObject(),
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi),
            Capability(PublicBtSearchApi));

        await Assert.ThrowsAsync<DsmException>(() =>
            repository.SearchBtAsync(new DownloadBtSearchRequest(ProfileId, "linux")));

        Assert.Equal("200", api.Requests.Single(request => request.Method == "list")
            .Parameters["limit"]);
        Assert.Equal(1, api.Requests.Count(request => request.Method == "clean"));
        Assert.Equal(
            new[] { "start", "list", "clean" },
            api.Requests.Select(request => request.Method));
    }

    [Fact]
    public async Task ActivityCancellationIsNotConvertedIntoAnOptionalSectionFailure()
    {
        var api = new DownloadRecordingApiClient(request => request.ApiName switch
        {
            PublicTaskApi => EmptyPage(),
            PublicStatisticApi => throw new OperationCanceledException("synthetic cancellation"),
            _ => throw new InvalidOperationException(),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi),
            Capability(PublicStatisticApi));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            repository.LoadSnapshotAsync(0, 100));
        Assert.Equal(2, api.Requests.Count);
    }

    [Fact]
    public async Task PaginationAdvancesByRawSourceRecords()
    {
        var api = new DownloadRecordingApiClient(request => request.Parameters["offset"] switch
        {
            "0" => Page(0, 3, TaskItem("one", "waiting"), TaskItem("two", "downloading")),
            "2" => Page(2, 3, TaskItem("three", "finished")),
            _ => throw new InvalidOperationException(),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));

        var first = await repository.ListTasksAsync(0, 2);
        var second = await repository.ListTasksAsync(first.NextOffset!.Value, 2);

        Assert.True(first.HasMore);
        Assert.Equal(2, first.SourceRecordCount);
        Assert.Equal(2, first.NextOffset);
        Assert.False(second.HasMore);
        Assert.Equal(2, second.SourceOffset);
        Assert.Equal(1, second.SourceRecordCount);
        Assert.Null(second.NextOffset);
    }

    [Theory]
    [MemberData(nameof(InvalidPages))]
    public async Task InvalidPaginationOrRecordsFailTheWholePage(JsonObject response)
    {
        var api = new DownloadRecordingApiClient(_ => response);
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));

        await Assert.ThrowsAsync<DsmException>(() => repository.ListTasksAsync(0, 2));
    }

    [Fact]
    public async Task CancellationPropagatesAndDoesNotReturnPartialData()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var api = new DownloadRecordingApiClient(_ => EmptyPage());
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            repository.ListTasksAsync(0, 100, cancellation.Token));
        Assert.Empty(api.Requests);
    }

    [Fact]
    public async Task PauseAndResumeUseOfficialTaskV1AndRequireReadbackConfirmation()
    {
        var pausePages = new Queue<JsonObject>(new[]
        {
            Page(0, 1, TaskItem("task-1", "downloading")),
            Page(0, 1, TaskItem("task-1", "paused")),
        });
        var pauseApi = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => pausePages.Dequeue(),
            "pause" => new JsonObject(),
            _ => throw new InvalidOperationException(request.Method),
        });
        var pauseRepository = (IDownloadStationRepository)CreateRepository(
            pauseApi,
            Capability(PublicTaskApi));

        var paused = await pauseRepository.ControlTaskAsync(new(
            ProfileId,
            TaskBaseline("task-1", "downloading"),
            DownloadTaskControlAction.Pause));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, paused.Result.Status);
        Assert.Equal("downloadPause", paused.Result.Operation);
        Assert.False(paused.Result.RequiresRefresh);
        Assert.Equal("task-1", paused.TaskId);
        Assert.Equal(DownloadTaskState.Paused, paused.Task!.State);
        Assert.Collection(
            pauseApi.Requests,
            request => Assert.Equal("list", request.Method),
            request =>
            {
                Assert.Equal(PublicTaskApi, request.ApiName);
                Assert.Equal(1, request.Version);
                Assert.Equal("pause", request.Method);
                Assert.Equal(new[] { "id" }, request.Parameters.Keys.Order(StringComparer.Ordinal));
                Assert.Equal("task-1", request.Parameters["id"]);
            },
            request => Assert.Equal("list", request.Method));

        var resumePages = new Queue<JsonObject>(new[]
        {
            Page(0, 1, TaskItem("task-1", "paused")),
            Page(0, 1, TaskItem("task-1", "waiting")),
        });
        var resumeApi = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => resumePages.Dequeue(),
            "resume" => new JsonObject(),
            _ => throw new InvalidOperationException(request.Method),
        });
        var resumeRepository = (IDownloadStationRepository)CreateRepository(
            resumeApi,
            Capability(PublicTaskApi));

        var resumed = await resumeRepository.ControlTaskAsync(new(
            ProfileId,
            TaskBaseline("task-1", "paused"),
            DownloadTaskControlAction.Resume));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, resumed.Result.Status);
        Assert.Equal("downloadResume", resumed.Result.Operation);
        Assert.Equal(DownloadTaskState.Waiting, resumed.Task!.State);
        Assert.Equal("resume", resumeApi.Requests[1].Method);
        Assert.Equal("task-1", resumeApi.Requests[1].Parameters["id"]);
    }

    [Fact]
    public async Task BaselineDriftOrWrongStateReturnsConflictWithoutSubmittingControlRequest()
    {
        var api = new DownloadRecordingApiClient(_ => Page(
            0,
            1,
            TaskItem("task-1", "paused")));
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));

        var result = await repository.ControlTaskAsync(new(
            ProfileId,
            TaskBaseline("task-1", "downloading"),
            DownloadTaskControlAction.Pause));

        Assert.Equal(MutationResultStatus.ConfirmedFailure, result.Result.Status);
        Assert.Equal(MutationErrorCategory.Conflict, result.Result.ErrorCategory);
        Assert.Single(api.Requests);
        Assert.Equal("list", api.Requests[0].Method);
    }

    [Fact]
    public async Task PostSubmitCancellationStoresReviewAndSecondCallOnlyReadsBack()
    {
        var listPages = new Queue<JsonObject>(new[]
        {
            Page(0, 1, TaskItem("task-1", "downloading")),
            Page(0, 1, TaskItem("task-1", "downloading")),
            Page(0, 1, TaskItem("task-1", "paused")),
        });
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => listPages.Dequeue(),
            "pause" => throw new OperationCanceledException("after synthetic submit"),
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));
        var baseline = new DownloadTaskControlRequest(
            ProfileId,
            TaskBaseline("task-1", "downloading"),
            DownloadTaskControlAction.Pause);

        var first = await repository.ControlTaskAsync(baseline);
        var second = await repository.ControlTaskAsync(baseline);

        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, first.Result.Status);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, second.Result.Status);
        Assert.Equal(1, api.Requests.Count(request => request.Method == "pause"));
        Assert.Equal(3, api.Requests.Count(request => request.Method == "list"));
    }

    [Fact]
    public async Task CreateLinkUsesOfficialTaskV1AndRequiresStableTaskReadback()
    {
        var listPages = new Queue<JsonObject>(new[]
        {
            EmptyPage(),
            Page(0, 1, TaskItem("created-task", "waiting")),
        });
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => listPages.Dequeue(),
            "create" => new JsonObject
            {
                ["taskid"] = "created-task",
            },
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi, 1, 9),
            Capability("SYNO.DownloadStation2.Task", 1, 2));

        var outcome = await repository.CreateTaskAsync(new(
            ProfileId,
            "https://example.invalid/synthetic.iso",
            "/synthetic"));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal("downloadCreate", outcome.Result.Operation);
        Assert.Equal("created-task", outcome.TaskId);
        Assert.Equal("created-task", outcome.Task!.Id);
        Assert.Collection(
            api.Requests,
            request => Assert.Equal("list", request.Method),
            request =>
            {
                Assert.Equal(PublicTaskApi, request.ApiName);
                Assert.Equal(1, request.Version);
                Assert.Equal("create", request.Method);
                Assert.Equal(
                    new[] { "destination", "uri" },
                    request.Parameters.Keys.Order(StringComparer.Ordinal));
                Assert.Equal("https://example.invalid/synthetic.iso", request.Parameters["uri"]);
                Assert.Equal("/synthetic", request.Parameters["destination"]);
            },
            request => Assert.Equal("list", request.Method));
        Assert.DoesNotContain(
            api.Requests,
            request => string.Equals(request.ApiName, "SYNO.DownloadStation2.Task", StringComparison.Ordinal));
    }

    [Fact]
    public async Task CreateLinkPostSubmitCancellationStoresReviewAndSecondCallDoesNotCreateAgain()
    {
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => EmptyPage(),
            "create" => throw new OperationCanceledException("after synthetic submit"),
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));
        var request = new DownloadTaskCreateRequest(
            ProfileId,
            "magnet:?xt=urn:btih:synthetic",
            null);

        var first = await repository.CreateTaskAsync(request);
        var second = await repository.CreateTaskAsync(request);

        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, first.Result.Status);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.Equal(1, api.Requests.Count(item => item.Method == "create"));
        Assert.Equal(1, api.Requests.Count(item => item.Method == "list"));
    }

    [Fact]
    public async Task CreateLinkWithoutStableTaskIdStoresReviewAndSecondCallDoesNotCreateAgain()
    {
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => EmptyPage(),
            "create" => new JsonObject(),
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));
        var request = new DownloadTaskCreateRequest(
            ProfileId,
            "https://example.invalid/synthetic.iso",
            null);

        var first = await repository.CreateTaskAsync(request);
        var second = await repository.CreateTaskAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Equal(1, api.Requests.Count(item => item.Method == "create"));
        Assert.Equal(1, api.Requests.Count(item => item.Method == "list"));
    }

    [Fact]
    public async Task CreateFileUsesOfficialTaskV1FileTransportAndRequiresStableTaskReadback()
    {
        var listPages = new Queue<JsonObject>(new[]
        {
            EmptyPage(),
            Page(0, 1, TaskItem("created-file", "waiting")),
        });
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => listPages.Dequeue(),
            _ => throw new InvalidOperationException(request.Method),
        });
        api.FileCreateResults.Enqueue(new DownloadTaskFileCreateTransportResult(
            DownloadTaskFileCreateTransportStatus.Accepted,
            TaskId: "created-file",
            DiagnosticTag: "download-station.create.file.accepted"));
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi, 1, 9),
            Capability("SYNO.DownloadStation2.Task", 1, 2));
        await using var content = new MemoryStream([0x64, 0x38, 0x3A, 0x61]);

        var outcome = await repository.CreateTaskFromFileAsync(new(
            ProfileId,
            content,
            content.Length,
            "synthetic.torrent",
            "/synthetic"));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal("downloadCreate", outcome.Result.Operation);
        Assert.Equal("created-file", outcome.TaskId);
        Assert.Equal("created-file", outcome.Task!.Id);
        var fileRequest = Assert.Single(api.FileCreateRequests);
        Assert.Equal(ProfileId, fileRequest.ProfileId);
        Assert.Equal("synthetic.torrent", fileRequest.FileName);
        Assert.Equal(4, fileRequest.Length);
        Assert.Equal("/synthetic", fileRequest.Destination);
        Assert.Collection(
            api.Requests,
            request => Assert.Equal("list", request.Method),
            request => Assert.Equal("list", request.Method));
        Assert.DoesNotContain(
            api.Requests,
            request => string.Equals(request.ApiName, "SYNO.DownloadStation2.Task", StringComparison.Ordinal));
    }

    [Fact]
    public async Task CreateFilePostSubmitCancellationStoresReviewAndSecondCallDoesNotUploadAgain()
    {
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => EmptyPage(),
            _ => throw new InvalidOperationException(request.Method),
        });
        api.FileCreateResults.Enqueue(new DownloadTaskFileCreateTransportResult(
            DownloadTaskFileCreateTransportStatus.CancellationRequestedAfterSubmission,
            ErrorCategory: MutationErrorCategory.Network,
            DiagnosticTag: "download-station.create.file.cancelled-after-submit"));
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));
        await using var content = new MemoryStream([0x64, 0x38, 0x3A, 0x61]);
        var request = new DownloadTaskFileCreateRequest(
            ProfileId,
            content,
            content.Length,
            "synthetic.torrent",
            null);

        var first = await repository.CreateTaskFromFileAsync(request);
        var second = await repository.CreateTaskFromFileAsync(request);

        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, first.Result.Status);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.Single(api.FileCreateRequests);
        Assert.Equal(1, api.Requests.Count(item => item.Method == "list"));
    }

    [Fact]
    public async Task CreateFileTransportThrowAfterBoundaryStoresReviewAndSecondCallDoesNotUploadAgain()
    {
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => EmptyPage(),
            _ => throw new InvalidOperationException(request.Method),
        });
        api.FileCreateResults.Enqueue(new InvalidOperationException("after synthetic submit"));
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));
        await using var content = new MemoryStream([0x64, 0x38, 0x3A, 0x61]);
        var request = new DownloadTaskFileCreateRequest(
            ProfileId,
            content,
            content.Length,
            "synthetic.torrent",
            null);

        var first = await repository.CreateTaskFromFileAsync(request);
        var second = await repository.CreateTaskFromFileAsync(request);

        Assert.Equal(MutationResultStatus.SubmittedButUnverified, first.Result.Status);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Equal(MutationResultStatus.SubmittedButUnverified, second.Result.Status);
        Assert.Single(api.FileCreateRequests);
        Assert.Equal(1, api.Requests.Count(item => item.Method == "list"));
    }

    [Fact]
    public async Task DeleteTaskUsesOfficialTaskV1WithoutRemovingDownloadedDataAndRequiresDisappearance()
    {
        var listPages = new Queue<JsonObject>(new[]
        {
            Page(0, 1, TaskItem("task-1", "finished")),
            EmptyPage(),
        });
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => listPages.Dequeue(),
            "delete" => new JsonObject(),
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi, 1, 9),
            Capability("SYNO.DownloadStation2.Task", 1, 2));

        var outcome = await repository.DeleteTaskAsync(new(
            ProfileId,
            TaskBaseline("task-1", "finished")));

        Assert.Equal(MutationResultStatus.ConfirmedSuccess, outcome.Result.Status);
        Assert.Equal("downloadTaskDelete", outcome.Result.Operation);
        Assert.Equal("task-1", outcome.TaskId);
        Assert.Collection(
            api.Requests,
            request => Assert.Equal("list", request.Method),
            request =>
            {
                Assert.Equal(PublicTaskApi, request.ApiName);
                Assert.Equal(1, request.Version);
                Assert.Equal("delete", request.Method);
                Assert.Equal(
                    new[] { "force_complete", "id" },
                    request.Parameters.Keys.Order(StringComparer.Ordinal));
                Assert.Equal("task-1", request.Parameters["id"]);
                Assert.Equal("false", request.Parameters["force_complete"]);
            },
            request => Assert.Equal("list", request.Method));
        Assert.DoesNotContain(
            api.Requests,
            request => string.Equals(request.ApiName, "SYNO.DownloadStation2.Task", StringComparison.Ordinal));
    }

    [Fact]
    public async Task DeleteTaskPostSubmitCancellationStoresReviewAndSecondCallDoesNotDeleteAgain()
    {
        var listPages = new Queue<JsonObject>(new[]
        {
            Page(0, 1, TaskItem("task-1", "finished")),
            Page(0, 1, TaskItem("task-1", "finished")),
            EmptyPage(),
        });
        var api = new DownloadRecordingApiClient(request => request.Method switch
        {
            "list" => listPages.Dequeue(),
            "delete" => throw new OperationCanceledException("after synthetic submit"),
            _ => throw new InvalidOperationException(request.Method),
        });
        var repository = (IDownloadStationRepository)CreateRepository(
            api,
            Capability(PublicTaskApi));
        var request = new DownloadTaskDeleteRequest(
            ProfileId,
            TaskBaseline("task-1", "finished"));

        var first = await repository.DeleteTaskAsync(request);
        var second = await repository.DeleteTaskAsync(request);

        Assert.Equal(MutationResultStatus.CancellationRequestedAfterSubmission, first.Result.Status);
        Assert.True(first.Result.RequiresRefresh);
        Assert.Equal(MutationResultStatus.ConfirmedSuccess, second.Result.Status);
        Assert.Equal(1, api.Requests.Count(item => item.Method == "delete"));
        Assert.Equal(3, api.Requests.Count(item => item.Method == "list"));
    }

    public static IEnumerable<object[]> InvalidPages()
    {
        yield return [new JsonObject { ["offset"] = 1, ["total"] = 0, ["tasks"] = new JsonArray() }];
        yield return [new JsonObject { ["offset"] = 0, ["total"] = -1, ["tasks"] = new JsonArray() }];
        yield return [new JsonObject { ["offset"] = 0, ["total"] = 1, ["tasks"] = new JsonArray() }];
        yield return [new JsonObject { ["offset"] = 0, ["total"] = 1, ["tasks"] = new JsonArray("bad") }];
        yield return [Page(0, 2, TaskItem("same", "waiting"), TaskItem("same", "paused"))];
        yield return [new JsonObject { ["offset"] = 0, ["tasks"] = new JsonArray() }];
        yield return [new JsonObject { ["total"] = 0, ["tasks"] = new JsonArray() }];
    }

    private const string PublicTaskApi = "SYNO.DownloadStation.Task";
    private const string PublicStatisticApi = "SYNO.DownloadStation.Statistic";
    private const string PublicBtSearchApi = "SYNO.DownloadStation.BTSearch";

    private static DsmRepository CreateRepository(
        DownloadRecordingApiClient api,
        params ApiCapability[] capabilities) =>
        new(
            new NasProfile(ProfileId, "Synthetic NAS", "nas.invalid", 5001, "tester"),
            new DsmSession(ProfileId, "synthetic-sid", null, null),
            api,
            capabilities.ToDictionary(item => item.Name, StringComparer.Ordinal));

    private static ApiCapability Capability(
        string name,
        int minimum = 1,
        int maximum = 1) =>
        new(name, "entry.cgi", minimum, maximum, "FORM");

    private static JsonObject EmptyPage() => Page(0, 0);

    private static JsonObject Page(int offset, int total, params JsonObject[] tasks) => new()
    {
        ["offset"] = offset,
        ["total"] = total,
        ["tasks"] = new JsonArray(tasks.Select(task => (JsonNode)task).ToArray()),
    };

    private static JsonObject TaskItem(object id, string status) => new()
    {
        ["id"] = StableIdNode(id),
        ["title"] = $"Task {id}",
        ["status"] = status,
        ["size"] = 100,
        ["additional"] = new JsonObject
        {
            ["detail"] = new JsonObject
            {
                ["destination"] = "/synthetic",
            },
            ["transfer"] = new JsonObject
            {
                ["size_downloaded"] = 12,
                ["size_uploaded"] = 3,
                ["speed_download"] = 4,
                ["speed_upload"] = 5,
            },
        },
    };

    private static JsonNode StableIdNode(object id) => id switch
    {
        string text => JsonValue.Create(text)!,
        int integer => JsonValue.Create(integer)!,
        long integer => JsonValue.Create(integer)!,
        _ => throw new ArgumentOutOfRangeException(nameof(id)),
    };

    private static DownloadTask TaskBaseline(string id, string status) =>
        new(
            id,
            $"Task {id}",
            status,
            DownloadTaskStateFor(status),
            100,
            12,
            3,
            4,
            5,
            "/synthetic",
            null);

    private static DownloadTaskState DownloadTaskStateFor(string status) =>
        status switch
        {
            "waiting" => DownloadTaskState.Waiting,
            "downloading" => DownloadTaskState.Downloading,
            "paused" => DownloadTaskState.Paused,
            "finished" => DownloadTaskState.Finished,
            "hash_checking" => DownloadTaskState.Checking,
            "seeding" => DownloadTaskState.Seeding,
            "error" => DownloadTaskState.Error,
            _ => DownloadTaskState.Unknown,
        };

    private sealed record DownloadApiRequest(
        string ApiName,
        string Method,
        int Version,
        IReadOnlyDictionary<string, string> Parameters);

    private sealed class DownloadRecordingApiClient(
        Func<DownloadApiRequest, JsonObject> response) : IDsmApiClient
    {
        public List<DownloadApiRequest> Requests { get; } = [];
        public Queue<object> FileCreateResults { get; } = [];
        public List<DownloadTaskFileCreateRequest> FileCreateRequests { get; } = [];

        public Task<JsonObject> CallAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            string method,
            IReadOnlyDictionary<string, string>? parameters = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var request = new DownloadApiRequest(
                capability.Name,
                method,
                capability.MaxVersion,
                new Dictionary<string, string>(
                    parameters ?? new Dictionary<string, string>(StringComparer.Ordinal),
                    StringComparer.Ordinal));
            Requests.Add(request);
            return Task.FromResult(response(request));
        }

        public Task<DownloadTaskFileCreateTransportResult> CreateDownloadTaskFromFileAsync(
            NasProfile profile,
            DsmSession session,
            ApiCapability capability,
            DownloadTaskFileCreateRequest request,
            IProgress<long>? progress = null,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Assert.Equal(PublicTaskApi, capability.Name);
            Assert.Equal(1, capability.MinVersion);
            Assert.True(capability.MaxVersion >= 1);
            Assert.Equal(ProfileId, profile.Id);
            Assert.Equal(ProfileId, session.ProfileId);
            FileCreateRequests.Add(request);
            return Result<DownloadTaskFileCreateTransportResult>(FileCreateResults.Dequeue());
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

        private static Task<T> Result<T>(object value) => value switch
        {
            T result => Task.FromResult(result),
            Task<T> task => task,
            Exception error => Task.FromException<T>(error),
            _ => throw new InvalidOperationException(value.GetType().Name),
        };
    }
}
