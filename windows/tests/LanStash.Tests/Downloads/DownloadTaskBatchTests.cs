using LanStash.App.Features.Downloads;
using LanStash.Domain;

namespace LanStash.Tests.Downloads;

public sealed class DownloadTaskBatchTests
{
    private static DownloadTask Task(string id, string status = "downloading") => new(id, "Synthetic " + id, status, 100, 20, 1, 0, "downloads", null);
    private static MutationResult Result(MutationResultStatus status) => new(1, status, "downloadBatch", true, status == MutationResultStatus.SubmittedButUnverified,
        status == MutationResultStatus.ConfirmedSuccess ? new(1, 0, 0) : status == MutationResultStatus.SubmittedButUnverified ? new(0, 0, 1) : new(0, 1, 0));

    [Fact]
    public async Task UnknownTaskPausesAndReviewCannotStartNextTask()
    {
        var repo = new Repo(); repo.Outcomes.Enqueue(Result(MutationResultStatus.SubmittedButUnverified));
        using var model = new DownloadTaskBatchViewModel(repo); await model.LoadAsync();
        await model.StartAsync(["1", "2"]); Assert.True(model.RequiresReview); Assert.Single(repo.Calls);
        model.SetAction(DownloadBatchAction.RemoveTask); Assert.Equal(DownloadBatchAction.Pause, model.Action);
        await model.ReviewAsync(); Assert.True(model.CanContinue); Assert.Equal(new[] { "1", "1" }, repo.Calls.Select(call => call.Id));
        await model.ReviewAsync(); Assert.Equal(2, repo.Calls.Count);
        await model.ContinueAsync(); Assert.False(model.HasPending); Assert.Equal("2", repo.Calls[2].Id);
        Assert.Equal(2, model.ConfirmedTasks.Count);
        model.ClearAppliedResults(); Assert.Empty(model.ConfirmedTasks);
    }

    [Fact]
    public async Task StoppingUnstartedItemsDoesNotDiscardUnknownResultOrRepeatFinishedItems()
    {
        var repo = new Repo(); repo.Outcomes.Enqueue(Result(MutationResultStatus.SubmittedButUnverified));
        using var model = new DownloadTaskBatchViewModel(repo); await model.LoadAsync(); await model.StartAsync(["1", "2"]);
        await model.StopRemainingAsync(); Assert.True(model.RequiresReview); Assert.False(model.CanContinue);
        await model.ReviewAsync(); Assert.False(model.HasPending);
        Assert.Equal(new[] { DownloadBatchState.Confirmed, DownloadBatchState.Stopped }, model.Results.Select(row => row.State));
        Assert.All(repo.Calls, call => Assert.Equal("1", call.Id));
    }

    [Fact]
    public async Task PartialFailureKeepsPerTaskResultsAndForcedCompletionIsNotFileDeletion()
    {
        var repo = new Repo(); repo.Outcomes.Enqueue(Result(MutationResultStatus.ConfirmedFailure));
        using var model = new DownloadTaskBatchViewModel(repo); await model.LoadAsync(); model.SetAction(DownloadBatchAction.FinishIncomplete);
        await model.StartAsync(["1", "2", "2"]);
        Assert.Equal(new[] { DownloadBatchState.Failed, DownloadBatchState.Confirmed }, model.Results.Select(row => row.State));
        Assert.All(repo.Calls, call => Assert.True(call.ForceComplete));
        Assert.Equal("2", Assert.Single(model.RemovedTaskIds)); Assert.False(model.HasPending);
        Assert.All(model.Results, row => Assert.True(row.FinishIncomplete));
        await model.ReviewAsync(); Assert.Equal(2, repo.Calls.Count);
    }

    [Fact]
    public async Task ForeignResultCannotConfirmSelectedTask()
    {
        var repo = new Repo { ForeignResult = true }; using var model = new DownloadTaskBatchViewModel(repo); await model.LoadAsync();
        await model.StartAsync(["1"]); Assert.True(model.RequiresReview); Assert.Empty(model.ConfirmedTasks);
    }

    [Fact]
    public async Task FullPaginationIsLoadedAndMalformedPagesFailWithoutWrites()
    {
        var repo = new Repo { Count = 101 }; using var model = new DownloadTaskBatchViewModel(repo); await model.LoadAsync();
        Assert.Equal(101, model.Choices.Count); Assert.Equal(new[] { 0, 100 }, repo.Offsets);
        repo.InvalidPage = true; await model.LoadAsync(); Assert.Equal("DownloadBatchLoadFailed", model.ErrorKey);
        await model.StartAsync(["1"]); Assert.Empty(repo.Calls);
    }

    [Fact]
    public async Task DisposalDuringFirstCallPreventsLaterWrites()
    {
        var repo = new Repo(); var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        repo.Delay = () => release.Task;
        using var model = new DownloadTaskBatchViewModel(repo); await model.LoadAsync(); var work = model.StartAsync(["1", "2"]);
        model.Dispose(); release.SetResult(); await work; Assert.Single(repo.Calls);
    }

    private sealed class Repo : IDownloadStationRepository
    {
        public Guid ProfileId { get; } = Guid.NewGuid();
        public DownloadStationAvailability Availability => new(DownloadStationAvailabilityStatus.Available, new HashSet<DownloadStationReadFeature> { DownloadStationReadFeature.Tasks });
        public int Count { get; init; } = 2;
        public bool ForeignResult { get; init; }
        public bool InvalidPage { get; set; }
        public Func<System.Threading.Tasks.Task>? Delay { get; set; }
        public List<int> Offsets { get; } = [];
        public List<(string Id, bool ForceComplete)> Calls { get; } = [];
        public Queue<MutationResult> Outcomes { get; } = [];
        public Task<DownloadTaskPage> ListTasksAsync(int offset, int limit, CancellationToken cancellationToken = default)
        {
            Offsets.Add(offset); var rows = Enumerable.Range(offset + 1, Math.Min(limit, Count - offset)).Select(id => Task(id.ToString())).ToArray();
            var more = offset + rows.Length < Count;
            return System.Threading.Tasks.Task.FromResult(new DownloadTaskPage(rows, InvalidPage ? offset + 1 : offset, rows.Length, Count, more ? offset + rows.Length : null, more));
        }
        public async Task<DownloadTaskControlOutcome> ControlTaskAsync(DownloadTaskControlRequest request, CancellationToken cancellationToken = default)
        {
            Calls.Add((request.Task.Id, false)); if (Delay is not null) await Delay();
            var result = Outcomes.TryDequeue(out var value) ? value : Result(MutationResultStatus.ConfirmedSuccess);
            return new(result, ForeignResult ? "foreign" : request.Task.Id, result.Status == MutationResultStatus.ConfirmedSuccess ? Task(request.Task.Id, request.Action == DownloadTaskControlAction.Pause ? "paused" : "downloading") : null);
        }
        public Task<DownloadTaskDeleteOutcome> DeleteTaskAsync(DownloadTaskDeleteRequest request, CancellationToken cancellationToken = default)
        { Calls.Add((request.Task.Id, request.ForceComplete)); return System.Threading.Tasks.Task.FromResult(new DownloadTaskDeleteOutcome(Outcomes.TryDequeue(out var value) ? value : Result(MutationResultStatus.ConfirmedSuccess), request.Task.Id)); }
        public bool CanFinishIncomplete => true;
        private DownloadActionInfo? _action;
        public async Task<DownloadActionInfo> StartDownloadActionAsync(DownloadTaskActionRequest request, CancellationToken cancellationToken = default)
        {
            _action = new(request.Id, ProfileId, request.Kind, DateTimeOffset.UtcNow,
                request.Tasks.Select(task => new DownloadActionItem(task.Id, DownloadActionStage.NotStarted, null, task)).ToArray());
            return await Run(false, cancellationToken);
        }
        public Task<DownloadActionInfo> ReviewDownloadActionAsync(Guid id, CancellationToken cancellationToken = default) => Run(true, cancellationToken);
        public Task<DownloadActionInfo> ContinueDownloadActionAsync(Guid id, CancellationToken cancellationToken = default) => Run(false, cancellationToken);
        public Task<DownloadActionInfo> CancelDownloadActionRemainderAsync(Guid id, CancellationToken cancellationToken = default)
        {
            _action = _action! with { Items = _action!.Items.Select(item => item.Stage == DownloadActionStage.NotStarted ? item with { Stage = DownloadActionStage.Cancelled } : item).ToArray() };
            return System.Threading.Tasks.Task.FromResult(_action);
        }
        private async Task<DownloadActionInfo> Run(bool review, CancellationToken token)
        {
            var rows = _action!.Items.ToArray();
            for (var index = 0; index < rows.Length; index++)
            {
                if (token.IsCancellationRequested) break;
                var row = rows[index];
                if (row.Stage != DownloadActionStage.Unknown && (review || row.Stage != DownloadActionStage.NotStarted)) continue;
                MutationResult result;
                if (_action.Kind is DownloadActionKind.Remove or DownloadActionKind.FinishIncomplete)
                    result = (await DeleteTaskAsync(new(ProfileId, row.Task!) { ForceComplete = _action.Kind == DownloadActionKind.FinishIncomplete }, token)).Result;
                else result = (await ControlTaskAsync(new(ProfileId, row.Task!, _action.Kind == DownloadActionKind.Pause ? DownloadTaskControlAction.Pause : DownloadTaskControlAction.Resume), token)).Result;
                rows[index] = row with { TargetId = ForeignResult ? "foreign" : row.TargetId, Stage = result.Status switch
                    { MutationResultStatus.ConfirmedSuccess => DownloadActionStage.Confirmed, MutationResultStatus.SubmittedButUnverified => DownloadActionStage.Unknown, _ => DownloadActionStage.Rejected },
                    Task = Task(row.TargetId, _action.Kind == DownloadActionKind.Pause ? "paused" : "downloading") };
                if (rows[index].Stage == DownloadActionStage.Unknown) break;
            }
            return _action = _action with { Items = rows };
        }
        public Task<DownloadStationSnapshot> LoadSnapshotAsync(int offset, int limit, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    }
}
