using LanStash.App.Features.Downloads;
using LanStash.Domain;

namespace LanStash.Tests;

public sealed class DownloadStationViewModelTests
{
    [Fact]
    public async Task UnavailableStateIssuesNoRequestsAndRefreshIsSafe()
    {
        var repository = new FakeDownloadStationRepository(
            Guid.NewGuid(),
            available: false);
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repository);
        await model.RefreshAsync();
        await model.LoadMoreAsync();

        Assert.Equal(DownloadStationContentState.Unavailable, model.ContentState);
        Assert.Empty(repository.SnapshotRequests);
        Assert.Empty(repository.PageRequests);
    }

    [Fact]
    public async Task RealOffsetsLoadMoreAndAllFiltersStayLocal()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.SnapshotResults.Enqueue(Snapshot(profile, Page(
            0,
            2,
            3,
            2,
            Task("active", DownloadTaskState.Downloading),
            Task("paused", DownloadTaskState.Paused))));
        repository.PageResults.Enqueue(Page(
            2,
            1,
            3,
            null,
            Task("finished", DownloadTaskState.Finished)));
        using var model = new DownloadStationViewModel(pageSize: 2);

        await model.ActivateAsync(repository);
        await model.LoadMoreAsync();
        model.SetFilter(DownloadTaskFilter.Active);
        Assert.Equal("active", Assert.Single(model.Tasks).Id);
        model.SetFilter(DownloadTaskFilter.Finished);
        Assert.Equal("finished", Assert.Single(model.Tasks).Id);
        model.SetFilter(DownloadTaskFilter.Paused);
        Assert.Equal("paused", Assert.Single(model.Tasks).Id);
        model.SetFilter(DownloadTaskFilter.All);
        model.SetSearchText("finish");
        Assert.Equal("finished", Assert.Single(model.Tasks).Id);

        Assert.Equal(new[] { (0, 2) }, repository.SnapshotRequests);
        Assert.Equal(new[] { (2, 2) }, repository.PageRequests);
    }

    [Fact]
    public async Task RefreshFailureKeepsVisibleTasksSelectionAndFilter()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.SnapshotResults.Enqueue(Snapshot(profile, Page(
            0, 1, 1, null, Task("paused", DownloadTaskState.Paused))));
        repository.SnapshotResults.Enqueue(new IOException("synthetic"));
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repository);
        model.SetFilter(DownloadTaskFilter.Paused);
        model.SelectTask(model.Tasks.Single());

        await model.RefreshAsync();

        Assert.Equal(DownloadStationContentState.Content, model.ContentState);
        Assert.Equal("paused", Assert.Single(model.Tasks).Id);
        Assert.Equal("paused", model.SelectedTask?.Id);
        Assert.Equal(DownloadTaskFilter.Paused, model.Filter);
        Assert.True(model.HasRefreshError);
    }

    [Fact]
    public async Task LoadMoreFailureRetainsContentAndRetriesSameSourceOffset()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.SnapshotResults.Enqueue(Snapshot(profile, Page(
            0, 1, 2, 1, Task("first", DownloadTaskState.Waiting))));
        repository.PageResults.Enqueue(new IOException("synthetic"));
        repository.PageResults.Enqueue(Page(
            1, 1, 2, null, Task("second", DownloadTaskState.Finished)));
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repository);

        await model.LoadMoreAsync();
        Assert.Equal("first", Assert.Single(model.Tasks).Id);
        Assert.True(model.HasLoadMoreError);
        await model.LoadMoreAsync();

        Assert.Equal(["first", "second"], model.Tasks.Select(item => item.Id));
        Assert.Equal(
            new[]
            {
                (1, DownloadStationViewModel.DefaultPageSize),
                (1, DownloadStationViewModel.DefaultPageSize),
            },
            repository.PageRequests);
        Assert.False(model.HasLoadMoreError);
    }

    [Fact]
    public async Task ProfileSwitchCancelsOldGenerationAndRejectsLateSnapshot()
    {
        var profileA = Guid.NewGuid();
        var profileB = Guid.NewGuid();
        var delayed = new TaskCompletionSource<DownloadStationSnapshot>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var repositoryA = Available(profileA);
        repositoryA.SnapshotResults.Enqueue(delayed.Task);
        var repositoryB = Available(profileB);
        repositoryB.SnapshotResults.Enqueue(Snapshot(profileB, Page(
            0, 1, 1, null, Task("b", DownloadTaskState.Finished))));
        using var model = new DownloadStationViewModel();

        var activationA = model.ActivateAsync(repositoryA);
        await WaitUntilAsync(() => repositoryA.SnapshotRequests.Count == 1);
        var oldToken = repositoryA.SnapshotTokens.Single();
        await model.ActivateAsync(repositoryB);
        delayed.SetResult(Snapshot(profileA, Page(
            0, 1, 1, null, Task("late-a", DownloadTaskState.Downloading))));
        await activationA;

        Assert.True(oldToken.IsCancellationRequested);
        Assert.Equal(profileB, model.ActiveProfileId);
        Assert.Equal("b", Assert.Single(model.Tasks).Id);
    }

    [Fact]
    public async Task ProfileRestoresCachedFilterAndSelectionWithoutNewRequest()
    {
        var profileA = Guid.NewGuid();
        var repositoryA = Available(profileA);
        repositoryA.SnapshotResults.Enqueue(Snapshot(profileA, Page(
            0, 1, 1, null, Task("a", DownloadTaskState.Paused))));
        var profileB = Guid.NewGuid();
        var repositoryB = Available(profileB);
        repositoryB.SnapshotResults.Enqueue(Snapshot(profileB, Page(
            0, 1, 1, null, Task("b", DownloadTaskState.Finished))));
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repositoryA);
        model.SetFilter(DownloadTaskFilter.Paused);
        model.SetSearchText("a");
        model.SelectTask(model.Tasks.Single());
        await model.ActivateAsync(repositoryB);
        await model.ActivateAsync(repositoryA);

        Assert.Equal(DownloadTaskFilter.Paused, model.Filter);
        Assert.Equal("a", model.SearchText);
        Assert.Equal("a", model.SelectedTask?.Id);
        Assert.Single(repositoryA.SnapshotRequests);
    }

    [Fact]
    public async Task EmptyFilteredEmptyErrorAndContentAreDistinct()
    {
        var emptyRepository = Available(Guid.NewGuid());
        emptyRepository.SnapshotResults.Enqueue(Snapshot(
            emptyRepository.ProfileId,
            Page(0, 0, 0, null)));
        using var empty = new DownloadStationViewModel();
        await empty.ActivateAsync(emptyRepository);
        Assert.Equal(DownloadStationContentState.Empty, empty.ContentState);

        var filteredRepository = Available(Guid.NewGuid());
        filteredRepository.SnapshotResults.Enqueue(Snapshot(
            filteredRepository.ProfileId,
            Page(0, 1, 1, null, Task("running", DownloadTaskState.Downloading))));
        using var filtered = new DownloadStationViewModel();
        await filtered.ActivateAsync(filteredRepository);
        Assert.Equal(DownloadStationContentState.Content, filtered.ContentState);
        filtered.SetFilter(DownloadTaskFilter.Finished);
        Assert.Equal(DownloadStationContentState.FilteredEmpty, filtered.ContentState);

        var failedRepository = Available(Guid.NewGuid());
        failedRepository.SnapshotResults.Enqueue(new IOException("synthetic"));
        using var failed = new DownloadStationViewModel();
        await failed.ActivateAsync(failedRepository);
        Assert.Equal(DownloadStationContentState.Error, failed.ContentState);
    }

    [Fact]
    public void UnknownRawStateIsNeverShownAsTechnicalStatus()
    {
        var task = Task("unknown", DownloadTaskState.Unknown, rawStatus: "future_private_state");
        var item = new DownloadTaskItem(task);

        Assert.DoesNotContain("future_private_state", item.StatusText, StringComparison.Ordinal);
        Assert.DoesNotContain("future_private_state", item.AutomationName, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ActivitySummaryIsPresentedAndCachedWithItsProfile()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.SnapshotResults.Enqueue(new DownloadStationSnapshot(
            profile,
            Page(0, 0, 0, null),
            new(
                DownloadStationSectionStatus.Available,
                new DownloadActivitySummary(1_024, 512, 0, 0)),
            new(DownloadStationSectionStatus.Unavailable, null)));
        repository.SnapshotResults.Enqueue(new IOException("synthetic refresh"));
        var other = Available(Guid.NewGuid());
        other.SnapshotResults.Enqueue(Snapshot(other.ProfileId, Page(0, 0, 0, null)));
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repository);

        Assert.True(model.HasActivity);
        Assert.False(model.HasActivityError);
        Assert.DoesNotContain("Not available", model.ActivityDownloadSpeedText);
        Assert.DoesNotContain("Not available", model.ActivityUploadSpeedText);
        await model.ActivateAsync(other);
        Assert.False(model.HasActivity);
        await model.ActivateAsync(repository);
        Assert.True(model.HasActivity);
        Assert.Single(repository.SnapshotRequests);

        await model.RefreshAsync();

        Assert.True(model.HasActivity);
        Assert.True(model.HasRefreshError);
    }

    [Fact]
    public async Task OptionalActivityFailureHasItsOwnStateWithoutDroppingTasks()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.SnapshotResults.Enqueue(new DownloadStationSnapshot(
            profile,
            Page(0, 1, 1, null, Task("safe", DownloadTaskState.Downloading)),
            new(DownloadStationSectionStatus.Failed, null),
            new(DownloadStationSectionStatus.Unavailable, null)));
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repository);

        Assert.Equal("safe", Assert.Single(model.Tasks).Id);
        Assert.False(model.HasActivity);
        Assert.True(model.HasActivityError);
    }

    [Fact]
    public async Task NewProfileNeverShowsPreviousProfileActivityWhileLoadingOrAfterFailure()
    {
        var profileA = Guid.NewGuid();
        var repositoryA = Available(profileA);
        repositoryA.SnapshotResults.Enqueue(new DownloadStationSnapshot(
            profileA,
            Page(0, 0, 0, null),
            new(
                DownloadStationSectionStatus.Available,
                new DownloadActivitySummary(1_024, 512, 0, 0)),
            new(DownloadStationSectionStatus.Unavailable, null)));
        var profileB = Guid.NewGuid();
        var repositoryB = Available(profileB);
        var delayedB = new TaskCompletionSource<DownloadStationSnapshot>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        repositoryB.SnapshotResults.Enqueue(delayedB.Task);
        using var model = new DownloadStationViewModel();
        await model.ActivateAsync(repositoryA);
        Assert.True(model.HasActivity);

        var activationB = model.ActivateAsync(repositoryB);
        await WaitUntilAsync(() => repositoryB.SnapshotRequests.Count == 1);
        Assert.False(model.HasActivity);
        delayedB.SetException(new IOException("synthetic"));
        await activationB;

        Assert.Equal(profileB, model.ActiveProfileId);
        Assert.False(model.HasActivity);
        Assert.False(model.HasActivityError);
        Assert.Equal(DownloadStationContentState.Error, model.ContentState);
    }

    [Fact]
    public void RawTaskErrorIsNeverExposedAndUnknownProgressIsIndeterminate()
    {
        var task = Task("error", DownloadTaskState.Error) with
        {
            Error = "broken_link",
            Size = null,
            Downloaded = 50,
        };
        var item = new DownloadTaskItem(task);

        Assert.DoesNotContain("broken_link", item.ErrorText, StringComparison.Ordinal);
        Assert.True(item.IsProgressUnknown);
        var errorWithoutDetail = new DownloadTaskItem(task with { Error = null });
        Assert.Equal(item.ErrorText, errorWithoutDetail.ErrorText);
    }

    [Fact]
    public async Task PauseSuccessSubmitsFrozenTaskAndRefreshesCurrentList()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.SnapshotResults.Enqueue(Snapshot(profile, Page(
            0, 1, 1, null, Task("task-1", DownloadTaskState.Downloading))));
        repository.ControlResults.Enqueue(ControlOutcome(
            "downloadPause",
            MutationResultStatus.ConfirmedSuccess,
            submitted: true,
            requiresRefresh: false,
            task: Task("task-1", DownloadTaskState.Paused)));
        repository.SnapshotResults.Enqueue(Snapshot(profile, Page(
            0, 1, 1, null, Task("task-1", DownloadTaskState.Paused))));
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repository);
        model.SelectTask(model.Tasks.Single());
        Assert.True(model.CanPauseSelectedTask);

        await model.ControlSelectedTaskAsync(DownloadTaskControlAction.Pause);

        var request = Assert.Single(repository.ControlRequests);
        Assert.Equal(profile, request.ProfileId);
        Assert.Equal("task-1", request.Task.Id);
        Assert.Equal(DownloadTaskControlAction.Pause, request.Action);
        Assert.Equal(DownloadTaskControlNoticeKind.Success, model.ControlNoticeKind);
        Assert.False(model.CanPauseSelectedTask);
        Assert.True(model.CanResumeSelectedTask);
        Assert.Equal(2, repository.SnapshotRequests.Count);
    }

    [Fact]
    public async Task UnknownControlResultShowsReviewWithoutPretendingRefreshSucceeded()
    {
        var profile = Guid.NewGuid();
        var repository = Available(profile);
        repository.SnapshotResults.Enqueue(Snapshot(profile, Page(
            0, 1, 1, null, Task("task-1", DownloadTaskState.Downloading))));
        repository.ControlResults.Enqueue(ControlOutcome(
            "downloadPause",
            MutationResultStatus.SubmittedButUnverified,
            submitted: true,
            requiresRefresh: true,
            task: null));
        using var model = new DownloadStationViewModel();

        await model.ActivateAsync(repository);
        model.SelectTask(model.Tasks.Single());
        await model.ControlSelectedTaskAsync(DownloadTaskControlAction.Pause);

        Assert.Equal(DownloadTaskControlNoticeKind.NeedsReview, model.ControlNoticeKind);
        Assert.True(model.HasControlNotice);
        Assert.Single(repository.ControlRequests);
        Assert.Single(repository.SnapshotRequests);
    }

    private static FakeDownloadStationRepository Available(Guid profileId) =>
        new(profileId, available: true);

    private static DownloadStationSnapshot Snapshot(Guid profileId, DownloadTaskPage page) =>
        new(
            profileId,
            page,
            new(DownloadStationSectionStatus.Unavailable, null),
            new(DownloadStationSectionStatus.Unavailable, null));

    private static DownloadTaskPage Page(
        int offset,
        int count,
        int total,
        int? nextOffset,
        params DownloadTask[] tasks) =>
        new(tasks, offset, count, total, nextOffset, nextOffset is not null);

    private static DownloadTask Task(
        string id,
        DownloadTaskState state,
        string? rawStatus = null) =>
        new(
            id,
            id,
            rawStatus ?? state.ToString().ToLowerInvariant(),
            state,
            100,
            50,
            10,
            5,
            2,
            "downloads",
            null);

    private static DownloadTaskControlOutcome ControlOutcome(
        string operation,
        MutationResultStatus status,
        bool submitted,
        bool requiresRefresh,
        DownloadTask? task) =>
        new(
            new MutationResult(
                1,
                status,
                operation,
                submitted,
                requiresRefresh,
                CountsFor(status),
                status == MutationResultStatus.SubmittedButUnverified
                    ? MutationErrorCategory.Unknown
                    : null,
                localizationKey: null,
                diagnosticTag: "download-station.test"),
            task?.Id ?? "task-1",
            task);

    private static MutationResultCounts CountsFor(MutationResultStatus status) =>
        status switch
        {
            MutationResultStatus.ConfirmedSuccess => new(1, 0, 0),
            MutationResultStatus.SubmittedButUnverified or
                MutationResultStatus.CancellationRequestedAfterSubmission => new(0, 0, 1),
            MutationResultStatus.CancelledBeforeSubmission => new(0, 0, 0),
            _ => new(0, 1, 0),
        };

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 100 && !condition(); attempt++)
        {
            await System.Threading.Tasks.Task.Delay(10);
        }
        Assert.True(condition());
    }

    private sealed class FakeDownloadStationRepository(
        Guid profileId,
        bool available) : IDownloadStationRepository
    {
        public Guid ProfileId { get; } = profileId;
        public DownloadStationAvailability Availability { get; } = new(
            available
                ? DownloadStationAvailabilityStatus.Available
                : DownloadStationAvailabilityStatus.Unavailable,
            available
                ? new HashSet<DownloadStationReadFeature> { DownloadStationReadFeature.Tasks }
                : new HashSet<DownloadStationReadFeature>());
        public Queue<object> SnapshotResults { get; } = new();
        public Queue<object> PageResults { get; } = new();
        public Queue<object> ControlResults { get; } = new();
        public List<(int Offset, int Limit)> SnapshotRequests { get; } = [];
        public List<(int Offset, int Limit)> PageRequests { get; } = [];
        public List<DownloadTaskControlRequest> ControlRequests { get; } = [];
        public List<CancellationToken> SnapshotTokens { get; } = [];

        public Task<DownloadStationSnapshot> LoadSnapshotAsync(
            int offset,
            int limit,
            CancellationToken cancellationToken = default)
        {
            SnapshotRequests.Add((offset, limit));
            SnapshotTokens.Add(cancellationToken);
            return Result<DownloadStationSnapshot>(SnapshotResults.Dequeue());
        }

        public Task<DownloadTaskPage> ListTasksAsync(
            int offset,
            int limit,
            CancellationToken cancellationToken = default)
        {
            PageRequests.Add((offset, limit));
            return Result<DownloadTaskPage>(PageResults.Dequeue());
        }

        public Task<DownloadTaskControlOutcome> ControlTaskAsync(
            DownloadTaskControlRequest request,
            CancellationToken cancellationToken = default)
        {
            ControlRequests.Add(request);
            return Result<DownloadTaskControlOutcome>(ControlResults.Dequeue());
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
