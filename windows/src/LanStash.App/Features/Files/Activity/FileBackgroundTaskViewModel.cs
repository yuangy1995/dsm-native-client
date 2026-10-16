using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.Files.Activity;

public sealed class FileBackgroundTaskViewModel(IFileBackgroundTaskRepository repository, FileBackgroundTaskSummary task) : ObservableObject, IDisposable
{
    private readonly CancellationTokenSource _lifetime = new();
    private bool _disposed;
    public FileBackgroundTaskSummary Task { get; private set; } = task;
    public FileBackgroundTaskProgress? Progress { get; private set; }
    public bool IsBusy { get; private set; }
    public bool LoadFailed { get; private set; }
    public bool Missing { get; private set; }
    public FileBackgroundTaskAction Action => Task.State == FileBackgroundTaskState.Finished ? FileBackgroundTaskAction.Clear : FileBackgroundTaskAction.Stop;
    public bool CanControl => !_disposed && !IsBusy && !LoadFailed && !Missing && Progress?.Outcome.RequiresRefresh != true && repository.CanControlTask(Task, Action);
    public string? MessageKey => LoadFailed ? "FileTaskLoadFailed" : Progress?.Outcome.Status switch
    {
        MutationResultStatus.ConfirmedSuccess => Progress.Change.Action == FileBackgroundTaskAction.Clear ? "FileTaskCleared" : "FileTaskStopped",
        MutationResultStatus.SubmittedButUnverified => "FileTaskPending",
        MutationResultStatus.PermissionDenied => "FileTaskDenied",
        MutationResultStatus.Unsupported => "FileTaskUnsupported",
        MutationResultStatus.ConfirmedFailure => Progress.Outcome.ErrorCategory == MutationErrorCategory.Conflict ? "FileTaskChanged" : "FileTaskFailed",
        MutationResultStatus.CancelledBeforeSubmission => "FileTaskNotSent",
        _ => Missing ? "FileTaskMissing" : !IsBusy && !repository.CanControlTask(Task, Action) ? "FileTaskUnsupported" : null,
    };
    public async Task RefreshAsync()
    {
        if (_disposed || IsBusy) return;
        IsBusy = true; LoadFailed = false; Notify();
        try
        {
            var operations = await repository.GetTaskOperationsAsync(_lifetime.Token);
            if (_disposed) return;
            var pending = operations.FirstOrDefault(p => p.Change.Task.Id == Task.Id);
            if (pending is not null) { Task = pending.Change.Task; Progress = await repository.ReviewTaskAsync(pending.Change.RequestId, _lifetime.Token) ?? pending; }
            if (_disposed) return;
            var offset = 0;
            while (true)
            {
                var page = await repository.ListTasksAsync(offset, 100, _lifetime.Token);
                if (_disposed) return;
                var current = page.Tasks.FirstOrDefault(t => t.Id == Task.Id);
                if (current is not null)
                {
                    if (Task.CreationTimestamp is not null && !Task.SameIdentity(current)) throw new InvalidDataException();
                    Task = current; Missing = false; break;
                }
                if (!page.HasMore) { Missing = true; break; }
                if (page.NextOffset <= offset) throw new InvalidDataException();
                offset = page.NextOffset;
            }
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch { if (!_disposed) LoadFailed = true; }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }
    public async Task ControlAsync(bool confirmed)
    {
        if (!confirmed || !CanControl) return;
        IsBusy = true; Notify();
        try
        {
            var result = await repository.ControlTaskAsync(new(Guid.NewGuid(), repository.ProfileId, Task, Action, true), _lifetime.Token);
            if (_disposed) return;
            Progress = result;
            if (result.Outcome.Status == MutationResultStatus.ConfirmedSuccess)
            {
                if (result.Change.Action == FileBackgroundTaskAction.Clear) Missing = true;
                else Task = Task with { State = FileBackgroundTaskState.Finished };
            }
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch { if (!_disposed) LoadFailed = true; }
        finally { if (!_disposed) { IsBusy = false; Notify(); } }
    }
    private void Notify() => RaisePropertyChanged(string.Empty);
    public void Dispose() { if (_disposed) return; _disposed = true; _lifetime.Cancel(); _lifetime.Dispose(); }
}
