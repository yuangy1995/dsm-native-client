using LanStash.App.Features.Downloads;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DownloadStationBtSearchViewModelTests
{
    [Fact]
    public async Task CapabilityGateIssuesNoCatalogRequestWhenBtSearchIsMissing()
    {
        var repository = new FakeDownloadStationRepository(Guid.NewGuid(), supportsBtSearch: false);
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();

        Assert.False(model.HasBtSearchCapability);
        Assert.False(model.IsBtSearchSessionOpen);
        Assert.Equal(0, repository.CatalogRequestCount);
        Assert.Empty(repository.SearchRequests);
    }

    [Fact]
    public async Task CatalogNormalResultAndAllSupportedFiltersReachRepository()
    {
        var repository = Searchable(Guid.NewGuid());
        repository.SearchResults.Enqueue(new[]
        {
            Result("Resource A", "magnet:?xt=urn:btih:a"),
        });
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();
        Assert.Equal(DownloadBtSearchContentState.Ready, model.BtSearchContentState);
        Assert.Equal(new[] { "provider-a" }, model.BtSearchSelectedModuleIds);
        Assert.Equal(new string?[] { null, "Books" }, model.BtSearchCategories.Select(
            item => item.Id));

        model.SetBtSearchKeyword("  linux  ");
        model.SetBtSearchTitleFilter("  guide  ");
        model.SetBtSearchModuleScope(DownloadBtSearchModuleScope.Selected);
        model.SetBtSearchSelectedModules(["provider-b"]);
        model.SetBtSearchCategory("Books");
        model.SetBtSearchSort(DownloadBtSearchSort.Size);
        model.SetBtSearchDirection(DownloadBtSearchDirection.Ascending);
        await model.SearchBtAsync();

        var request = Assert.Single(repository.SearchRequests);
        Assert.Equal(repository.ProfileId, request.ProfileId);
        Assert.Equal("linux", request.Keyword);
        Assert.Equal("guide", request.TitleFilter);
        Assert.Equal(DownloadBtSearchModuleScope.Selected, request.ModuleScope);
        Assert.Equal(new[] { "provider-b" }, request.SelectedModuleIds);
        Assert.Equal("Books", request.CategoryId);
        Assert.Equal(DownloadBtSearchSort.Size, request.Sort);
        Assert.Equal(DownloadBtSearchDirection.Ascending, request.Direction);
        Assert.Equal(DownloadBtSearchContentState.Content, model.BtSearchContentState);
        Assert.Equal("Resource A", Assert.Single(model.BtSearchResults).Title);
    }

    [Fact]
    public async Task EmptyFilteredEmptyAndErrorRemainDistinctAndRecoverable()
    {
        var repository = Searchable(Guid.NewGuid());
        repository.SearchResults.Enqueue(Array.Empty<DownloadBtSearchResult>());
        repository.SearchResults.Enqueue(Array.Empty<DownloadBtSearchResult>());
        repository.SearchResults.Enqueue(new IOException("synthetic"));
        repository.SearchResults.Enqueue(new[] { Result("Recovered", "magnet:?xt=urn:btih:r") });
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();
        model.SetBtSearchKeyword("linux");

        await model.SearchBtAsync();
        Assert.Equal(DownloadBtSearchContentState.Empty, model.BtSearchContentState);

        model.SetBtSearchCategory("Books");
        await model.SearchBtAsync();
        Assert.Equal(DownloadBtSearchContentState.FilteredEmpty, model.BtSearchContentState);

        await model.SearchBtAsync();
        Assert.Equal(DownloadBtSearchContentState.Error, model.BtSearchContentState);
        await model.RetryBtSearchAsync();
        Assert.Equal(DownloadBtSearchContentState.Content, model.BtSearchContentState);
        Assert.Equal("Recovered", Assert.Single(model.BtSearchResults).Title);
    }

    [Fact]
    public async Task CatalogErrorCanRetryWithoutPersistingPartialOptions()
    {
        var repository = new FakeDownloadStationRepository(
            Guid.NewGuid(),
            supportsBtSearch: true);
        repository.CatalogResults.Enqueue(new IOException("synthetic"));
        repository.CatalogResults.Enqueue(new DownloadBtSearchCatalog(
            [new("provider-a", "Provider A", true)],
            [new("Books", "Books")]));
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();
        Assert.Equal(DownloadBtSearchContentState.Error, model.BtSearchContentState);
        Assert.False(model.HasBtSearchCatalog);
        Assert.Empty(model.BtSearchModules);

        await model.RetryBtSearchAsync();
        Assert.Equal(DownloadBtSearchContentState.Ready, model.BtSearchContentState);
        Assert.True(model.HasBtSearchCatalog);
        Assert.Equal("provider-a", Assert.Single(model.BtSearchModules).Id);
    }

    [Fact]
    public async Task CatalogWithoutProvidersShowsRecoverableStateAndIssuesNoSearch()
    {
        var repository = new FakeDownloadStationRepository(
            Guid.NewGuid(),
            supportsBtSearch: true);
        repository.CatalogResults.Enqueue(new DownloadBtSearchCatalog(
            [],
            [new("_allcat_", "All categories")]));
        repository.CatalogResults.Enqueue(new DownloadBtSearchCatalog(
            [new("provider-a", "Provider A", true)],
            [new("_allcat_", "All categories"), new("Books", "Books")]));
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();

        Assert.True(model.HasBtSearchCatalog);
        Assert.True(model.HasNoBtSearchProviders);
        Assert.Equal(DownloadBtSearchContentState.NoProviders, model.BtSearchContentState);
        Assert.Empty(model.BtSearchModules);
        Assert.Single(model.BtSearchCategories);
        model.SetBtSearchKeyword("linux");
        await model.SearchBtAsync();
        Assert.Empty(repository.SearchRequests);
        Assert.Equal(DownloadBtSearchContentState.NoProviders, model.BtSearchContentState);

        await model.RetryBtSearchAsync();

        Assert.Equal(2, repository.CatalogRequestCount);
        Assert.Equal(DownloadBtSearchContentState.Ready, model.BtSearchContentState);
        Assert.Equal("provider-a", Assert.Single(model.BtSearchModules).Id);
        Assert.Equal(new string?[] { null, "Books" }, model.BtSearchCategories.Select(
            item => item.Id));
    }

    [Fact]
    public async Task ClosingSessionCancelsRequestAndRejectsLateResults()
    {
        var repository = Searchable(Guid.NewGuid());
        var delayed = new TaskCompletionSource<IReadOnlyList<DownloadBtSearchResult>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.SearchResults.Enqueue(delayed.Task);
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();
        model.SetBtSearchKeyword("linux");

        var search = model.SearchBtAsync();
        await WaitUntilAsync(() => repository.SearchTokens.Count == 1);
        var token = repository.SearchTokens.Single();
        model.EndBtSearchSession();
        delayed.SetResult([Result("Late", "magnet:?xt=urn:btih:late")]);
        await search;

        Assert.True(token.IsCancellationRequested);
        Assert.False(model.IsBtSearchSessionOpen);
        Assert.Equal(string.Empty, model.BtSearchKeyword);
        Assert.Equal(string.Empty, model.BtSearchTitleFilter);
        Assert.Null(model.BtSearchCategoryId);
        Assert.Empty(model.BtSearchResults);
        Assert.Equal(DownloadBtSearchContentState.Ready, model.BtSearchContentState);
    }

    [Fact]
    public async Task CancelActionReachesRepositoryTokenAndKeepsSessionRecoverable()
    {
        var repository = Searchable(Guid.NewGuid());
        var delayed = new TaskCompletionSource<IReadOnlyList<DownloadBtSearchResult>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.SearchResults.Enqueue(delayed.Task);
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();
        model.SetBtSearchKeyword("linux");

        var search = model.SearchBtAsync();
        await WaitUntilAsync(() => repository.SearchTokens.Count == 1);
        var token = repository.SearchTokens.Single();
        model.CancelCurrentBtSearch();
        delayed.SetResult([Result("Late", "magnet:?xt=urn:btih:late-cancel")]);
        await search;

        Assert.True(token.IsCancellationRequested);
        Assert.True(model.IsBtSearchSessionOpen);
        Assert.True(model.CanSearchBt);
        Assert.Empty(model.BtSearchResults);
        Assert.Equal(DownloadBtSearchContentState.Ready, model.BtSearchContentState);
    }

    [Fact]
    public async Task CriteriaChangeCancelsARequestAndRejectsLateResultAfterReturningToA()
    {
        var repository = Searchable(Guid.NewGuid());
        var delayed = new TaskCompletionSource<IReadOnlyList<DownloadBtSearchResult>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repository.SearchResults.Enqueue(delayed.Task);
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();
        model.SetBtSearchKeyword("A");

        var search = model.SearchBtAsync();
        await WaitUntilAsync(() => repository.SearchTokens.Count == 1);
        var token = repository.SearchTokens.Single();
        model.SetBtSearchKeyword("B");
        model.SetBtSearchKeyword("A");
        delayed.SetResult([Result("Late A", "magnet:?xt=urn:btih:late-a")]);
        await search;

        Assert.True(token.IsCancellationRequested);
        Assert.Equal("A", model.BtSearchKeyword);
        Assert.Single(repository.SearchRequests);
        Assert.Empty(model.BtSearchResults);
        Assert.Null(model.SelectedBtSearchResult);
        Assert.Equal(DownloadBtSearchContentState.Ready, model.BtSearchContentState);
    }

    [Fact]
    public async Task EveryCriteriaChangeClearsCompletedResultsAndSelection()
    {
        foreach (var (name, change) in CriteriaChanges())
        {
            var repository = Searchable(Guid.NewGuid());
            repository.SearchResults.Enqueue(
                new[] { Result(name, $"magnet:?xt=urn:btih:{name}") });
            using var model = new DownloadStationViewModel();
            await model.ActivateAsync(repository);
            await model.BeginBtSearchSessionAsync();
            model.SetBtSearchKeyword("A");
            await model.SearchBtAsync();
            model.SelectBtSearchResult(model.BtSearchResults.Single());
            Assert.True(model.CanCreateSelectedBtSearchResult, name);

            change(model);

            Assert.Empty(model.BtSearchResults);
            Assert.Null(model.SelectedBtSearchResult);
            Assert.False(model.CanCreateSelectedBtSearchResult, name);
            Assert.Equal(DownloadBtSearchContentState.Ready, model.BtSearchContentState);
        }
    }

    [Fact]
    public async Task InvalidSearchTextNeverReachesRepository()
    {
        var repository = Searchable(Guid.NewGuid());
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();

        model.SetBtSearchKeyword(new string('a', 201));
        await model.SearchBtAsync();
        model.SetBtSearchKeyword("valid");
        model.SetBtSearchTitleFilter(new string('b', 201));
        await model.SearchBtAsync();
        model.SetBtSearchTitleFilter(string.Empty);
        model.SetBtSearchKeyword("invalid\u0001keyword");
        await model.SearchBtAsync();
        model.SetBtSearchKeyword("\nvalid");
        await model.SearchBtAsync();
        model.SetBtSearchKeyword("valid\r");
        await model.SearchBtAsync();
        model.SetBtSearchKeyword("valid");
        model.SetBtSearchTitleFilter("\tfilter");
        await model.SearchBtAsync();

        Assert.Empty(repository.SearchRequests);
        Assert.False(model.CanSearchBt);
    }

    [Fact]
    public async Task SearchRequiresCurrentCategoryAndProvidersMatchingSelectedScope()
    {
        var repository = Searchable(Guid.NewGuid());
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();
        model.SetBtSearchKeyword("linux");

        model.SetBtSearchCategory("stale-category");
        Assert.False(model.CanSearchBt);
        await model.SearchBtAsync();

        model.SetBtSearchCategory("Books");
        model.SetBtSearchModuleScope(DownloadBtSearchModuleScope.Selected);
        model.SetBtSearchSelectedModules(["provider-b"]);
        Assert.True(model.CanSearchBt);
        model.BtSearchModules.Remove(model.BtSearchModules.Single(item => item.Id == "provider-b"));
        Assert.False(model.CanSearchBt);
        await model.SearchBtAsync();

        Assert.Empty(repository.SearchRequests);
    }

    [Fact]
    public async Task EnabledScopeRequiresAtLeastOneEnabledProviderWhileAllAcceptsDisabledProviders()
    {
        var repository = new FakeDownloadStationRepository(
            Guid.NewGuid(),
            supportsBtSearch: true);
        repository.CatalogResults.Enqueue(new DownloadBtSearchCatalog(
            [new("provider-a", "Provider A", false)],
            [new("_allcat_", "All categories")]));
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();
        model.SetBtSearchKeyword("linux");

        Assert.False(model.CanSearchBt);
        model.SetBtSearchModuleScope(DownloadBtSearchModuleScope.All);
        Assert.True(model.CanSearchBt);
        model.SetBtSearchModuleScope(DownloadBtSearchModuleScope.Selected);
        Assert.False(model.CanSearchBt);
        model.SetBtSearchSelectedModules(["provider-a"]);
        Assert.True(model.CanSearchBt);
    }

    [Fact]
    public async Task SelectedResultCreatesExactlyOnceThroughExistingSafeChain()
    {
        var repository = Searchable(Guid.NewGuid());
        repository.SearchResults.Enqueue(new[] { Result("Safe", "magnet:?xt=urn:btih:safe") });
        repository.CreateResults.Enqueue(CreateOutcome(
            MutationResultStatus.ConfirmedSuccess,
            task: TaskItem("created")));
        repository.SnapshotResults.Enqueue(Snapshot(repository.ProfileId, TaskItem("created")));
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();
        model.SetBtSearchKeyword("safe");
        await model.SearchBtAsync();
        model.SelectBtSearchResult(model.BtSearchResults.Single());

        await model.CreateSelectedBtSearchResultAsync();
        await model.CreateSelectedBtSearchResultAsync();

        var request = Assert.Single(repository.CreateRequests);
        Assert.Equal("magnet:?xt=urn:btih:safe", request.Uri);
        Assert.Equal(DownloadTaskCreateNoticeKind.Success, model.CreateNoticeKind);
        Assert.False(model.CanCreateSelectedBtSearchResult);
    }

    [Fact]
    public async Task SubmittedButUnknownCreationIsNeverReplayedInSameSession()
    {
        var repository = Searchable(Guid.NewGuid());
        repository.SearchResults.Enqueue(new[] { Result("Review", "magnet:?xt=urn:btih:review") });
        repository.CreateResults.Enqueue(CreateOutcome(
            MutationResultStatus.SubmittedButUnverified,
            task: null));
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repository);
        await model.BeginBtSearchSessionAsync();
        model.SetBtSearchKeyword("review");
        await model.SearchBtAsync();
        model.SelectBtSearchResult(model.BtSearchResults.Single());

        await model.CreateSelectedBtSearchResultAsync();
        await model.CreateSelectedBtSearchResultAsync();

        Assert.Single(repository.CreateRequests);
        Assert.Equal(DownloadTaskCreateNoticeKind.NeedsReview, model.CreateNoticeKind);
        Assert.False(model.CanCreateSelectedBtSearchResult);
    }

    [Fact]
    public async Task ProfileSwitchCancelsSearchAndRejectsPreviousRepositoryResult()
    {
        var first = Searchable(Guid.NewGuid());
        var delayed = new TaskCompletionSource<IReadOnlyList<DownloadBtSearchResult>>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        first.SearchResults.Enqueue(delayed.Task);
        var second = Searchable(Guid.NewGuid());
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(first);
        await model.BeginBtSearchSessionAsync();
        model.SetBtSearchKeyword("first");
        var search = model.SearchBtAsync();
        await WaitUntilAsync(() => first.SearchTokens.Count == 1);
        var token = first.SearchTokens.Single();

        await model.ActivateAsync(second);
        delayed.SetResult([Result("Late first", "magnet:?xt=urn:btih:first")]);
        await search;

        Assert.True(token.IsCancellationRequested);
        Assert.Equal(second.ProfileId, model.ActiveProfileId);
        Assert.False(model.IsBtSearchSessionOpen);
        Assert.Empty(model.BtSearchResults);
    }

    private static FakeDownloadStationRepository Searchable(Guid profileId)
    {
        var repository = new FakeDownloadStationRepository(profileId, supportsBtSearch: true);
        repository.CatalogResults.Enqueue(new DownloadBtSearchCatalog(
            [
                new("provider-a", "Provider A", true),
                new("provider-b", "Provider B", false),
            ],
            [new("_allcat_", "All categories"), new("Books", "Books")]));
        return repository;
    }

    private static IEnumerable<(string Name, Action<DownloadStationViewModel> Change)>
        CriteriaChanges()
    {
        yield return ("keyword", model => model.SetBtSearchKeyword("B"));
        yield return ("title", model => model.SetBtSearchTitleFilter("filtered"));
        yield return ("scope", model => model.SetBtSearchModuleScope(
            DownloadBtSearchModuleScope.All));
        yield return ("modules", model => model.SetBtSearchSelectedModules(["provider-b"]));
        yield return ("category", model => model.SetBtSearchCategory("Books"));
        yield return ("sort", model => model.SetBtSearchSort(DownloadBtSearchSort.Size));
        yield return ("direction", model => model.SetBtSearchDirection(
            DownloadBtSearchDirection.Ascending));
    }

    private static DownloadBtSearchResult Result(string title, string uri) =>
        new(title, 1_024, "2026-08-01", uri, null, 3, 5, 2, "Provider");

    private static DownloadTask TaskItem(string id) =>
        new(
            id,
            id,
            "waiting",
            DownloadTaskState.Waiting,
            100,
            0,
            0,
            0,
            0,
            "downloads",
            null);

    private static DownloadStationSnapshot Snapshot(Guid profileId, params DownloadTask[] tasks) =>
        new(
            profileId,
            new DownloadTaskPage(tasks, 0, tasks.Length, tasks.Length, null, false),
            new(DownloadStationSectionStatus.Unavailable, null),
            new(DownloadStationSectionStatus.Unavailable, null));

    private static DownloadTaskCreateOutcome CreateOutcome(
        MutationResultStatus status,
        DownloadTask? task) =>
        new(
            new MutationResult(
                1,
                status,
                "downloadCreate",
                submitted: status != MutationResultStatus.CancelledBeforeSubmission,
                requiresRefresh: status != MutationResultStatus.CancelledBeforeSubmission,
                counts: status == MutationResultStatus.ConfirmedSuccess
                    ? new MutationResultCounts(1, 0, 0)
                    : new MutationResultCounts(0, 0, 1),
                errorCategory: status == MutationResultStatus.SubmittedButUnverified
                    ? MutationErrorCategory.Unknown
                    : null,
                localizationKey: null,
                diagnosticTag: "download-station.bt-search.test"),
            task?.Id,
            task);

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 100 && !condition(); attempt++)
        {
            await System.Threading.Tasks.Task.Delay(10);
        }
        Assert.True(condition());
    }

    private sealed class FakeDownloadStationRepository : IDownloadStationRepository
    {
        public FakeDownloadStationRepository(Guid profileId, bool supportsBtSearch)
        {
            ProfileId = profileId;
            Availability = new(
                DownloadStationAvailabilityStatus.Available,
                supportsBtSearch
                    ? new HashSet<DownloadStationReadFeature>
                    {
                        DownloadStationReadFeature.Tasks,
                        DownloadStationReadFeature.BtSearch,
                    }
                    : new HashSet<DownloadStationReadFeature>
                    {
                        DownloadStationReadFeature.Tasks,
                    });
            SnapshotResults.Enqueue(Snapshot(profileId));
        }

        public Guid ProfileId { get; }
        public DownloadStationAvailability Availability { get; }
        public Queue<object> SnapshotResults { get; } = new();
        public Queue<object> CatalogResults { get; } = new();
        public Queue<object> SearchResults { get; } = new();
        public Queue<object> CreateResults { get; } = new();
        public List<DownloadBtSearchRequest> SearchRequests { get; } = [];
        public List<CancellationToken> SearchTokens { get; } = [];
        public List<DownloadTaskCreateRequest> CreateRequests { get; } = [];
        public int CatalogRequestCount { get; private set; }

        public Task<DownloadStationSnapshot> LoadSnapshotAsync(
            int offset,
            int limit,
            CancellationToken cancellationToken = default) =>
            Result<DownloadStationSnapshot>(SnapshotResults.Dequeue());

        public Task<DownloadTaskPage> ListTasksAsync(
            int offset,
            int limit,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<DownloadTaskControlOutcome> ControlTaskAsync(
            DownloadTaskControlRequest request,
            CancellationToken cancellationToken = default) =>
            throw new NotSupportedException();

        public Task<DownloadBtSearchCatalog> LoadBtSearchCatalogAsync(
            CancellationToken cancellationToken = default)
        {
            CatalogRequestCount++;
            return Result<DownloadBtSearchCatalog>(CatalogResults.Dequeue());
        }

        public Task<IReadOnlyList<DownloadBtSearchResult>> SearchBtAsync(
            DownloadBtSearchRequest request,
            CancellationToken cancellationToken = default)
        {
            SearchRequests.Add(request);
            SearchTokens.Add(cancellationToken);
            return Result<IReadOnlyList<DownloadBtSearchResult>>(SearchResults.Dequeue());
        }

        public Task<DownloadTaskCreateOutcome> CreateTaskAsync(
            DownloadTaskCreateRequest request,
            CancellationToken cancellationToken = default)
        {
            CreateRequests.Add(request);
            return Result<DownloadTaskCreateOutcome>(CreateResults.Dequeue());
        }

        private static Task<T> Result<T>(object value) => value switch
        {
            T result => System.Threading.Tasks.Task.FromResult(result),
            Task<T> task => task,
            Exception error => System.Threading.Tasks.Task.FromException<T>(error),
            _ => throw new InvalidOperationException(value.GetType().Name),
        };
    }
}
