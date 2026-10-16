using LanStash.App.Localization;
using LanStash.App.Features.Files.CopyMove;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Downloads;

public enum DownloadBatchAction { Pause, Resume, RemoveTask, FinishIncomplete, EditDestination }
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

/// <summary>原生批量界面复用仓储持久队列，页面关闭不丢失未知项或未开始项。</summary>
internal sealed class DownloadTaskBatchViewModel(IDownloadStationRepository repository, IFileCopyMoveFolderSource? folders = null) : ObservableObject, IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private CancellationTokenSource? _loadCancellation;
    private long _generation;
    private bool _disposed;
    private IReadOnlyList<DownloadTask> _tasks = [];
    private Step[] _steps = [];
    private DownloadTaskActionRequest? _request;
    public DownloadCreateOptionsViewModel Options { get; } = new(folders);
    public bool CanFinishIncomplete => repository.CanFinishIncomplete;
    public bool HasDestination => Action != DownloadBatchAction.EditDestination || Options.Destination is not null;
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
                    page.Tasks.Count > 100 || (offset > 0 && total != page.SourceTotal)) throw new InvalidDataException("download.batch.invalid-page");
                total = page.SourceTotal;
                foreach (var task in page.Tasks) { if (!ids.Add(task.Id)) throw new InvalidDataException("download.batch.duplicate-task"); tasks.Add(task); }
                if (!page.HasMore) { if (total is not null && tasks.Count != total) throw new InvalidDataException("download.batch.incomplete-page"); break; }
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
    { if (_disposed || IsBusy || HasPending || action == DownloadBatchAction.FinishIncomplete && !CanFinishIncomplete) return; Action = action; _request = null; _steps = []; Results = []; BuildChoices(); Changed(); }
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
        if (_disposed || IsBusy || IsLoading || HasPending || ErrorKey is not null || repository.Availability.Status != DownloadStationAvailabilityStatus.Available || !HasDestination) return;
        var selected = ids.Distinct(StringComparer.Ordinal).ToArray();
        if (selected.Length == 0 || selected.Any(id => !Choices.Any(choice => choice.Id == id))) return;
        _steps = selected.Select(id => new Step(Choices.Single(choice => choice.Id == id).Task)).ToArray();
        _request = new(repository.ProfileId, Guid.NewGuid(), Action switch
        { DownloadBatchAction.Pause => DownloadActionKind.Pause, DownloadBatchAction.Resume => DownloadActionKind.Resume,
            DownloadBatchAction.RemoveTask => DownloadActionKind.Remove, DownloadBatchAction.FinishIncomplete => DownloadActionKind.FinishIncomplete, _ => DownloadActionKind.EditDestination },
            _steps.Select(step => step.Task).ToArray(), Action == DownloadBatchAction.EditDestination ? Options.Destination : null);
        await RunAsync(reviewOnly: false, first: true);
    }
    public Task ReviewAsync() => !IsBusy && RequiresReview ? RunAsync(true) : Task.CompletedTask;
    public Task ContinueAsync() => CanContinue ? RunAsync(false) : Task.CompletedTask;
    public async Task StopRemainingAsync()
    {
        if (!CanStopRemaining || _request is null) return;
        IsBusy = true; Publish();
        try { Apply(await repository.CancelDownloadActionRemainderAsync(_request.Id, _lifetime.Token)); }
        catch { if (!_disposed) ErrorKey = "DownloadBatchLoadFailed"; }
        finally { IsBusy = false; Publish(); }
    }
    private async Task RunAsync(bool reviewOnly, bool first = false)
    {
        if (_request is null) return;
        IsBusy = true; ErrorKey = null; Publish();
        try
        {
            var info = first ? await repository.StartDownloadActionAsync(_request, _lifetime.Token)
                : reviewOnly ? await repository.ReviewDownloadActionAsync(_request.Id, _lifetime.Token)
                : await repository.ContinueDownloadActionAsync(_request.Id, _lifetime.Token);
            if (!_disposed) Apply(info);
        }
        catch { if (!_disposed) { ErrorKey = "DownloadBatchLoadFailed"; foreach (var step in _steps.Where(step => step.State == DownloadBatchState.NotStarted)) step.State = DownloadBatchState.NeedsReview; } }
        finally { IsBusy = false; Publish(); }
    }
    private void Apply(DownloadActionInfo info)
    {
        if (_disposed || _request is null || info.ProfileId != repository.ProfileId || info.Id != _request.Id || info.Kind != _request.Kind ||
            !info.Items.Select(item => item.TargetId).SequenceEqual(_steps.Select(step => step.Task.Id))) throw new InvalidDataException("download.batch.foreign-result");
        foreach (var step in _steps)
        {
            var item = info.Items.Single(item => item.TargetId == step.Task.Id);
            step.State = item.Stage switch
            {
                DownloadActionStage.NotStarted => DownloadBatchState.NotStarted, DownloadActionStage.Unknown => DownloadBatchState.NeedsReview,
                DownloadActionStage.Confirmed => DownloadBatchState.Confirmed, DownloadActionStage.Cancelled => DownloadBatchState.Stopped, _ => DownloadBatchState.Failed,
            };
            if (step.State != DownloadBatchState.Confirmed) continue;
            if (Action is DownloadBatchAction.RemoveTask or DownloadBatchAction.FinishIncomplete)
            { _removedIds.Add(step.Task.Id); _confirmedTasks.Remove(step.Task.Id); _tasks = _tasks.Where(task => task.Id != step.Task.Id).ToArray(); }
            else if (item.Task is { } task && task.Id == step.Task.Id)
            { _confirmedTasks[task.Id] = task; _tasks = _tasks.Select(old => old.Id == task.Id ? task : old).ToArray(); }
        }
        BuildChoices(); Publish();
    }
    private void Publish() { Results = _steps.Select(step => new DownloadBatchResult(step.Task.Id, step.Task.Title, step.State, Action == DownloadBatchAction.FinishIncomplete)).ToArray(); Changed(); }
    private void Changed() { if (!_disposed) RaisePropertyChanged(string.Empty); }
    public void CancelLoading() { _generation++; _loadCancellation?.Cancel(); IsLoading = false; Changed(); }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; CancelLoading(); _loadCancellation?.Dispose(); _loadCancellation = null;
        _lifetime.Cancel(); _lifetime.Dispose(); _tasks = []; Choices = []; Results = [];
        _steps = []; _request = null; Options.Dispose(); ClearAppliedResults();
    }
    private sealed class Step(DownloadTask task)
    { public DownloadTask Task { get; } = task; public DownloadBatchState State { get; set; } = DownloadBatchState.NotStarted; }
}
