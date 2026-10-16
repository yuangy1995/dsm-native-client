using LanStash.App.Features.Downloads;
using LanStash.Domain;

namespace LanStash.Tests.Downloads;

public sealed class DownloadReadRecoveryModelTests
{
    private static DownloadTask Item(string id = "one", string title = "Synthetic", long? size = 100) => new(id, title, "downloading", size, 20, 0, 10, "downloads", null);
    private static DownloadTaskDetails Details(DownloadTask item) => new(item, "bt", "synthetic", 0, [], [], []);
    [Fact]
    public async Task DetailsChangedIdentityKeepsPriorValueAndDisposalRejectsLateResult()
    {
        var repo = new Repo(); var original = Item();
        using var model = new DownloadTaskDetailsModel(repo, original);
        await model.LoadAsync(); var first = model.Details;
        repo.Details = (_, _) => Task.FromResult(Details(original with { Title = "Changed" }));
        await model.LoadAsync(); Assert.True(model.HasError); Assert.Same(first, model.Details);
        var delayed = new TaskCompletionSource<DownloadTaskDetails>();
        repo.Details = (_, _) => delayed.Task;
        var work = model.LoadAsync(); model.Dispose(); delayed.SetResult(Details(original)); await work;
        Assert.Same(first, model.Details); await model.LoadAsync(); Assert.Same(first, model.Details);
    }
    [Fact]
    public async Task NewDetailsReadWinsOverCancelledOlderRead()
    {
        var repo = new Repo(); var first = new TaskCompletionSource<DownloadTaskDetails>(); var second = new TaskCompletionSource<DownloadTaskDetails>(); var count = 0;
        repo.Details = (_, _) => ++count == 1 ? first.Task : second.Task;
        using var model = new DownloadTaskDetailsModel(repo, Item());
        var old = model.LoadAsync(); var current = model.LoadAsync();
        second.SetResult(Details(Item()) with { Kind = "new" }); await current;
        first.SetResult(Details(Item()) with { Kind = "old" }); await old;
        Assert.Equal("new", model.Details!.Kind); Assert.False(model.IsLoading);
    }
    [Fact]
    public async Task RssSelectionGenerationAndFilterClearPreviousSource()
    {
        var repo = new Repo(); var delayed = new TaskCompletionSource<IReadOnlyList<DownloadRssFeed>>();
        repo.Feeds = (id, _) => id == 1 ? delayed.Task : Task.FromResult<IReadOnlyList<DownloadRssFeed>>([new("second", "Second", 1, 0, "https://source.invalid/second")]);
        using var model = new DownloadRssModel(repo);
        var old = model.LoadAsync(); await model.SelectSiteAsync(repo.Sites[1]);
        delayed.SetResult([new("first", "First", 1, 0, "https://source.invalid/first")]); await old;
        Assert.Equal(2, model.SelectedSite!.Id); Assert.Equal("second", Assert.Single(model.Feeds).Id);
        model.SelectFeed(model.Feeds[0]); Assert.NotNull(model.SelectedFeed);
        model.Search("missing"); Assert.Empty(model.VisibleFeeds); Assert.Null(model.SelectedFeed); Assert.Equal(0, repo.Creates);
    }
    [Fact]
    public async Task RssUpdateAndLateResultCannotReachDisposedPage()
    {
        var repo = new Repo(); using var model = new DownloadRssModel(repo); await model.LoadAsync();
        var delayed = new TaskCompletionSource<DownloadActionInfo>(); repo.Refresh = (_, _) => delayed.Task;
        var work = model.UpdateSiteAsync(); model.Dispose();
        delayed.SetResult(new(Guid.NewGuid(), repo.ProfileId, DownloadActionKind.RefreshRss, DateTimeOffset.UtcNow, [new("1", DownloadActionStage.Confirmed, null)]));
        await work; Assert.Null(model.FeedbackKey); Assert.Equal(0, repo.Creates);
    }
    [Fact]
    public async Task RecoveryOnlyContinuesAfterExplicitActionAndCancellationPreservesUnknown()
    {
        var repo = new Repo(); using var model = new DownloadRecoveryModel(repo); await model.LoadAsync();
        Assert.True(model.CanReview); Assert.False(model.CanContinue); Assert.True(model.CanCancel);
        await model.ContinueAsync(); Assert.Equal(0, repo.Continues);
        await model.ReviewAsync(); Assert.True(model.CanContinue); Assert.Equal(0, repo.Continues);
        await model.ContinueAsync(); Assert.Equal(1, repo.Continues); Assert.False(model.Selected!.IsPending);
        repo.ResetRecord(); await model.LoadAsync(); await model.CancelAsync();
        Assert.True(model.CanReview); Assert.False(model.CanCancel); Assert.False(model.CanContinue); Assert.Equal(1, repo.Continues);
    }
    [Fact]
    public async Task RecoveryRejectsForeignProfileAndLateLists()
    {
        var repo = new Repo { Foreign = true }; using var model = new DownloadRecoveryModel(repo);
        await model.LoadAsync(); Assert.True(model.HasError); Assert.Empty(model.Rows);
        repo.Foreign = false; var delayed = new TaskCompletionSource<IReadOnlyList<DownloadActionInfo>>(); repo.ActionLoad = () => delayed.Task;
        var work = model.LoadAsync(); model.Dispose(); delayed.SetResult([repo.Record]); await work;
        Assert.Empty(model.Rows);
    }
    [Fact]
    public async Task FailedRecoveryReloadDisablesStaleActionsUntilSuccessfulReload()
    {
        var repo = new Repo(); using var model = new DownloadRecoveryModel(repo); await model.LoadAsync();
        Assert.True(model.CanReview); Assert.True(model.CanCancel);
        repo.ActionLoad = () => Task.FromException<IReadOnlyList<DownloadActionInfo>>(new IOException("synthetic"));
        await model.LoadAsync(); Assert.True(model.HasError); Assert.False(model.CanReview); Assert.False(model.CanCancel); Assert.False(model.CanContinue);
        await model.ContinueAsync(); Assert.Equal(0, repo.Continues);
        repo.ActionLoad = null; await model.LoadAsync(); Assert.True(model.CanReview); Assert.True(model.CanCancel);
    }
    [Fact]
    public async Task SortingPreservesPerProfileChoiceAndDoesNotMutateTaskIdentity()
    {
        var first = new Repo { Tasks = [Item("b", "Beta", null), Item("a", "Alpha", 20), Item("c", "Gamma", 40)] };
        var second = new Repo(); using var model = new DownloadStationViewModel(); await model.ActivateAsync(first);
        model.SetSort(DownloadTaskSort.Size, true); Assert.Equal(new[] { "c", "a", "b" }, model.Tasks.Select(task => task.Id));
        model.SetSort(DownloadTaskSort.Name, false); Assert.Equal(new[] { "a", "b", "c" }, model.Tasks.Select(task => task.Id));
        model.SetSort(DownloadTaskSort.Size, true); await model.ActivateAsync(second); Assert.Equal(DownloadTaskSort.Name, model.Sort);
        await model.ActivateAsync(first); Assert.Equal(DownloadTaskSort.Size, model.Sort); Assert.True(model.SortDescending);
        Assert.Equal(new[] { "c", "a", "b" }, model.Tasks.Select(task => task.Id));
    }
    [Fact]
    public async Task MissingSettingsStayUnavailableWhileKnownFieldsRemainEditable()
    {
        var repo = new Repo(); using var model = new DownloadSettingsViewModel(repo); await model.LoadAsync();
        model.SetDraft(model.Draft! with { IsEmuleEnabled = true, BtUploadLimitKb = 0, BtDownloadLimitKb = 500 });
        Assert.Null(model.Draft!.IsEmuleEnabled); Assert.Null(model.Draft.BtUploadLimitKb); Assert.True(model.CanSave);
        model.SetDraft(model.Draft with { BtDownloadLimitKb = null }); Assert.False(model.CanSave);
    }
    private sealed class Repo : IDownloadStationRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public DownloadStationAvailability Availability => new(DownloadStationAvailabilityStatus.Available, new HashSet<DownloadStationReadFeature> { DownloadStationReadFeature.Tasks });
        public Func<string, CancellationToken, Task<DownloadTaskDetails>> Details { get; set; } = (_, _) => Task.FromResult(DownloadReadRecoveryModelTests.Details(Item()));
        public IReadOnlyList<DownloadRssSite> Sites { get; } = [new(1, new('a', 64), "First", false, 0), new(2, new('b', 64), "Second", false, 0)];
        public Func<int, CancellationToken, Task<IReadOnlyList<DownloadRssFeed>>> Feeds { get; set; } = (_, _) => Task.FromResult<IReadOnlyList<DownloadRssFeed>>([]);
        public Func<DownloadRssSite, CancellationToken, Task<DownloadActionInfo>>? Refresh { get; set; }
        public Func<Task<IReadOnlyList<DownloadActionInfo>>>? ActionLoad { get; set; }
        public DownloadTask[] Tasks { get; init; } = [Item()];
        public int Creates, Continues;
        public bool Foreign { get; set; }
        public DownloadActionInfo Record { get; private set; } = null!;
        public Repo() => ResetRecord();
        public void ResetRecord() => Record = new(Guid.NewGuid(), ProfileId, DownloadActionKind.Pause, DateTimeOffset.UtcNow,
            [new("one", DownloadActionStage.Unknown, null), new("two", DownloadActionStage.NotStarted, null)]);
        public Task<DownloadTaskDetails> LoadTaskDetailsAsync(string id, CancellationToken token = default) => Details(id, token);
        public Task<IReadOnlyList<DownloadRssSite>> ListRssSitesAsync(CancellationToken token = default) => Task.FromResult(Sites);
        public Task<IReadOnlyList<DownloadRssFeed>> ListRssFeedsAsync(int id, CancellationToken token = default) => Feeds(id, token);
        public Task<DownloadActionInfo> RefreshRssSiteAsync(DownloadRssSite site, CancellationToken token = default) => Refresh!(site, token);
        public Task<IReadOnlyList<DownloadActionInfo>> LoadDownloadActionsAsync(CancellationToken token = default) => ActionLoad?.Invoke() ?? Task.FromResult<IReadOnlyList<DownloadActionInfo>>([Foreign ? Record with { ProfileId = Guid.NewGuid() } : Record]);
        public Task<DownloadActionInfo> ReviewDownloadActionAsync(Guid id, CancellationToken token = default) => Task.FromResult(Record = Record with { Items = Record.Items.Select(item => item.Stage == DownloadActionStage.Unknown ? item with { Stage = DownloadActionStage.Confirmed } : item).ToArray() });
        public Task<DownloadActionInfo> ContinueDownloadActionAsync(Guid id, CancellationToken token = default)
        { Continues++; return Task.FromResult(Record = Record with { Items = Record.Items.Select(item => item with { Stage = DownloadActionStage.Confirmed }).ToArray() }); }
        public Task<DownloadActionInfo> CancelDownloadActionRemainderAsync(Guid id, CancellationToken token = default) => Task.FromResult(Record = Record with { Items = Record.Items.Select(item => item.Stage == DownloadActionStage.NotStarted ? item with { Stage = DownloadActionStage.Cancelled } : item).ToArray() });
        public Task<DownloadTaskPage> ListTasksAsync(int offset, int limit, CancellationToken token = default) => Task.FromResult(new DownloadTaskPage(Tasks, 0, Tasks.Length, Tasks.Length, null, false));
        public async Task<DownloadStationSnapshot> LoadSnapshotAsync(int offset, int limit, CancellationToken token = default) => new(ProfileId, await ListTasksAsync(offset, limit, token), new(DownloadStationSectionStatus.Unavailable, null), new(DownloadStationSectionStatus.Unavailable, null));
        public Task<DownloadTaskControlOutcome> ControlTaskAsync(DownloadTaskControlRequest request, CancellationToken token = default) => throw new NotSupportedException();
        public Task<DownloadTaskCreateOutcome> CreateTaskAsync(DownloadTaskCreateRequest request, CancellationToken token = default) { Creates++; throw new NotSupportedException(); }
        public Task<DownloadSettingsSnapshot> LoadSettingsAsync(CancellationToken token = default) => Task.FromResult(new DownloadSettingsSnapshot(ProfileId,
            new("downloads", null, false, 100, null, null, null, null, null, null, null, null), true, DownloadStationSectionStatus.Unavailable) { IsManager = true });
    }
}
