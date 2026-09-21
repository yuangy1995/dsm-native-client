using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

public enum DownloadBatchAction { Pause, Resume, RemoveTask, FinishIncomplete }
public enum DownloadBatchState { NotStarted, Running, Confirmed, Failed, NeedsReview, Stopped }
public sealed record DownloadBatchChoice(string Id, string Title, DownloadTask Task);
public sealed record DownloadBatchResult(string Id, string Title, DownloadBatchState State, bool FinishIncomplete = false)
{
    public string StateText => LocalizationService.Current.Get(State switch
    {
        DownloadBatchState.NotStarted => "DownloadBatchNotStarted", DownloadBatchState.Running => "DownloadBatchRunning",
        DownloadBatchState.Confirmed => FinishIncomplete ? "DownloadBatchFinishConfirmed" : "DownloadBatchConfirmed", DownloadBatchState.Failed => "DownloadBatchFailed",
        DownloadBatchState.NeedsReview => "DownloadBatchNeedsReview", _ => "DownloadBatchStopped",
    });
}

/// <summary>复用既有单任务预检/写后回读；批次在页面内保留，不持久化任务或请求内容。</summary>
internal sealed class DownloadTaskBatchViewModel(IDownloadStationRepository repository) : ObservableObject, IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private CancellationTokenSource? _loadCancellation;
    private long _generation;
    private bool _disposed;
    private IReadOnlyList<DownloadTask> _tasks = [];
    private Step[] _steps = [];
    private readonly Dictionary<string, DownloadTask> _confirmedTasks = new(StringComparer.Ordinal);
    private readonly HashSet<string> _removedIds = new(StringComparer.Ordinal);
    public DownloadBatchAction Action { get; private set; }
    public bool IsLoading { get; private set; }
    public bool IsBusy { get; private set; }
    public bool RequiresReview => _steps.Any(step => step.State == DownloadBatchState.NeedsReview);
    public bool HasPending => _steps.Any(step => step.State is DownloadBatchState.NotStarted or DownloadBatchState.NeedsReview or DownloadBatchState.Running);
    public bool CanContinue => !IsBusy && !RequiresReview && _steps.Any(step => step.State == DownloadBatchState.NotStarted);
    public bool CanStopRemaining => !IsBusy && _steps.Any(step => step.State == DownloadBatchState.NotStarted);
    public string? ErrorKey { get; private set; }
    public IReadOnlyList<DownloadBatchChoice> Choices { get; private set; } = [];
    public IReadOnlyList<DownloadBatchResult> Results { get; private set; } = [];
    public IReadOnlyList<DownloadTask> ConfirmedTasks => _confirmedTasks.Values.ToArray();
    public IReadOnlySet<string> RemovedTaskIds => _removedIds;
    public void ClearAppliedResults() { _confirmedTasks.Clear(); _removedIds.Clear(); }
    public string Summary => LocalizationService.Current.Format("DownloadBatchSummary",
        Results.Count(row => row.State == DownloadBatchState.Confirmed), Results.Count(row => row.State == DownloadBatchState.Failed),
        Results.Count(row => row.State == DownloadBatchState.NeedsReview), Results.Count(row => row.State is DownloadBatchState.NotStarted or DownloadBatchState.Stopped));

    public async Task LoadAsync()
    {
        if (_disposed || IsBusy || HasPending) return;
        _loadCancellation?.Cancel(); _loadCancellation?.Dispose(); _loadCancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        var token = _loadCancellation.Token; var generation = ++_generation;
        IsLoading = true; ErrorKey = null; Choices = []; Changed();
        try
        {
            var tasks = new List<DownloadTask>(); var ids = new HashSet<string>(StringComparer.Ordinal);
            int? total = null; var offset = 0;
            while (true)
            {
                var page = await repository.ListTasksAsync(offset, 100, token);
                if (_disposed || generation != _generation || token.IsCancellationRequested) return;
                if (page.SourceOffset != offset || page.SourceRecordCount != page.Tasks.Count || page.SourceTotal < offset + page.Tasks.Count ||
                    page.Tasks.Count > 100 || page.SourceTotal > 5000 || (total is not null && total != page.SourceTotal)) throw new InvalidDataException("download.batch.invalid-page");
                total = page.SourceTotal;
                foreach (var task in page.Tasks) { if (!ids.Add(task.Id)) throw new InvalidDataException("download.batch.duplicate-task"); tasks.Add(task); }
                if (!page.HasMore) { if (tasks.Count != total) throw new InvalidDataException("download.batch.incomplete-page"); break; }
                if (page.NextOffset != offset + page.Tasks.Count || page.NextOffset <= offset) throw new InvalidDataException("download.batch.invalid-cursor");
                offset = page.NextOffset.Value;
            }
            _tasks = tasks; BuildChoices();
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { if (!_disposed && generation == _generation) ErrorKey = "DownloadBatchLoadFailed"; }
        finally { if (!_disposed && generation == _generation) { IsLoading = false; Changed(); } }
    }
    public void SetAction(DownloadBatchAction action)
    { if (_disposed || IsBusy || HasPending) return; Action = action; _steps = []; Results = []; BuildChoices(); Changed(); }
    private void BuildChoices() => Choices = _tasks.Where(task => Supports(Action, task.State)).Select(task => new DownloadBatchChoice(task.Id, task.Title, task)).ToArray();
    internal static bool Supports(DownloadBatchAction action, DownloadTaskState state) => action switch
    {
        DownloadBatchAction.Pause => state is DownloadTaskState.Waiting or DownloadTaskState.Downloading or DownloadTaskState.Checking or DownloadTaskState.Seeding,
        DownloadBatchAction.Resume => state == DownloadTaskState.Paused,
        DownloadBatchAction.FinishIncomplete => state != DownloadTaskState.Unknown && state != DownloadTaskState.Finished,
        _ => true,
    };
    public async Task StartAsync(IReadOnlyList<string> ids)
    {
        if (_disposed || IsBusy || IsLoading || HasPending || ErrorKey is not null || repository.Availability.Status != DownloadStationAvailabilityStatus.Available) return;
        var selected = ids.Distinct(StringComparer.Ordinal).ToArray();
        if (selected.Length == 0 || selected.Any(id => !Choices.Any(choice => choice.Id == id))) return;
        _steps = selected.Select(id => new Step(Choices.Single(choice => choice.Id == id).Task)).ToArray();
        await RunAsync(reviewOnly: false);
    }
    public Task ReviewAsync() => !IsBusy && RequiresReview ? RunAsync(true) : Task.CompletedTask;
    public Task ContinueAsync() => CanContinue ? RunAsync(false) : Task.CompletedTask;
    public void StopRemaining()
    { if (!CanStopRemaining) return; foreach (var step in _steps.Where(step => step.State == DownloadBatchState.NotStarted)) step.State = DownloadBatchState.Stopped; Publish(); }

    private async Task RunAsync(bool reviewOnly)
    {
        IsBusy = true; Publish();
        try
        {
            foreach (var step in _steps)
            {
                if (_disposed || _lifetime.IsCancellationRequested) return;
                if (step.State is not (DownloadBatchState.NotStarted or DownloadBatchState.NeedsReview)) continue;
                if (reviewOnly && step.State == DownloadBatchState.NotStarted) break;
                step.State = DownloadBatchState.Running; Publish();
                MutationResult? result = null;
                try
                {
                    if (Action is DownloadBatchAction.RemoveTask or DownloadBatchAction.FinishIncomplete)
                    {
                        var outcome = await repository.DeleteTaskAsync(new(repository.ProfileId, step.Task) { ForceComplete = Action == DownloadBatchAction.FinishIncomplete }, _lifetime.Token);
                        if (outcome.TaskId == step.Task.Id) result = outcome.Result;
                    }
                    else
                    {
                        var action = Action == DownloadBatchAction.Pause ? DownloadTaskControlAction.Pause : DownloadTaskControlAction.Resume;
                        var outcome = await repository.ControlTaskAsync(new(repository.ProfileId, step.Task, action), _lifetime.Token);
                        if (outcome.TaskId == step.Task.Id && (outcome.Task is null || outcome.Task.Id == step.Task.Id))
                        {
                            result = outcome.Result;
                            if (result.Status == MutationResultStatus.ConfirmedSuccess)
                            {
                                if (outcome.Task is null || (Action == DownloadBatchAction.Pause ? outcome.Task.State != DownloadTaskState.Paused :
                                    !Supports(DownloadBatchAction.Pause, outcome.Task.State))) result = null;
                                else step.ConfirmedTask = outcome.Task;
                            }
                        }
                    }
                }
                catch { /* 写边界不明时保留同一任务快照，仅沿原仓储待核对路径读取。 */ }
                if (_disposed) return;
                step.State = result?.Status switch
                {
                    MutationResultStatus.ConfirmedSuccess => DownloadBatchState.Confirmed,
                    MutationResultStatus.SubmittedButUnverified or MutationResultStatus.CancellationRequestedAfterSubmission or null => DownloadBatchState.NeedsReview,
                    MutationResultStatus.CancelledBeforeSubmission => DownloadBatchState.Stopped,
                    _ => DownloadBatchState.Failed,
                };
                if (step.State == DownloadBatchState.Confirmed)
                {
                    if (Action is DownloadBatchAction.RemoveTask or DownloadBatchAction.FinishIncomplete)
                    { _removedIds.Add(step.Task.Id); _confirmedTasks.Remove(step.Task.Id); _tasks = _tasks.Where(task => task.Id != step.Task.Id).ToArray(); }
                    else if (step.ConfirmedTask is { } confirmed)
                    { _confirmedTasks[confirmed.Id] = confirmed; _tasks = _tasks.Select(task => task.Id == confirmed.Id ? confirmed : task).ToArray(); }
                    BuildChoices();
                }
                Publish();
                if (step.State is DownloadBatchState.NeedsReview or DownloadBatchState.Stopped) break;
            }
        }
        finally { IsBusy = false; Publish(); }
    }
    private void Publish() { Results = _steps.Select(step => new DownloadBatchResult(step.Task.Id, step.Task.Title, step.State, Action == DownloadBatchAction.FinishIncomplete)).ToArray(); Changed(); }
    private void Changed() { if (!_disposed) RaisePropertyChanged(string.Empty); }
    public void CancelLoading() { _generation++; _loadCancellation?.Cancel(); IsLoading = false; Changed(); }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; CancelLoading(); _loadCancellation?.Dispose(); _loadCancellation = null;
        _lifetime.Cancel(); _lifetime.Dispose(); _tasks = []; Choices = []; Results = [];
        _steps = []; ClearAppliedResults();
    }
    private sealed class Step(DownloadTask task)
    { public DownloadTask Task { get; } = task; public DownloadTask? ConfirmedTask { get; set; } public DownloadBatchState State { get; set; } = DownloadBatchState.NotStarted; }
}
