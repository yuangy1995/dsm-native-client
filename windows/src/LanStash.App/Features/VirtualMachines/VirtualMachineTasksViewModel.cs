using System.Collections.ObjectModel;
using LanStash.App.Localization;
using LanStash.App.ViewModels;
using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public sealed partial class VirtualMachineTasksViewModel(TimeProvider? timeProvider = null) : ObservableObject, IDisposable
{
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;
    private IVirtualMachineManagerRepository? _repository;
    private CancellationTokenSource? _lifetime;
    private Task? _polling;
    private long _generation;
    private bool _visible, _disposed;
    public ObservableCollection<VirtualMachineTaskItem> Tasks { get; } = [];
    public bool IsLoading { get; private set; }
    public bool HasLoaded { get; private set; }
    public bool HasError { get; private set; }
    public bool RequiresReconnect { get; private set; }
    public bool IsUnavailable => _repository?.CanReadTasks != true;
    public bool CanRefresh => !_disposed && _visible && !IsLoading && !IsCleaning && _cleanupConfirmation is null && !RequiresReconnect && !IsUnavailable;
    public bool HasReadFailures => Tasks.Any(item => item.Task.State == VirtualMachineTaskState.ReadFailed);
    private bool HasUnfinishedTasks => Tasks.Any(item => item.Task.State != VirtualMachineTaskState.Finished || item.Task.IsProtected);
    public async Task ActivateAsync(IVirtualMachineManagerRepository repository)
    {
        ObjectDisposedException.ThrowIf(_disposed, this); ArgumentNullException.ThrowIfNull(repository);
        Deactivate(); _repository = repository; await SetVisibleAsync(true);
    }
    public async Task SetVisibleAsync(bool visible)
    {
        if (_disposed || _repository is null || _visible == visible) return;
        Cancel(); _visible = visible; IsLoading = false;
        if (visible) { _lifetime = new(); await RefreshAsync(); } else Notify();
    }
    public async Task RefreshAsync()
    {
        if (!CanRefresh) { Notify(); return; }
        var repository = _repository!; var generation = _generation; var token = _lifetime!.Token;
        IsLoading = true; Notify();
        try
        {
            var tasks = await repository.LoadVirtualMachineTasksAsync(token);
            if (!Current(generation, repository)) return;
            Apply(tasks); HasLoaded = true; HasError = false;
            if (repository.CanClearTasks)
            {
                var recoveries = await repository.GetTaskCleanupRecoveriesAsync(token);
                if (Current(generation, repository)) CleanupRecoveries = recoveries.ToArray();
            }
        }
        catch (DsmException error) when (error.AuthenticationFailure || error.Code is 106 or 107 or 119)
        { if (Current(generation, repository)) { RequiresReconnect = true; HasError = true; Tasks.Clear(); HasLoaded = false; _lifetime?.Cancel(); } }
        catch (Exception)
        { if (Current(generation, repository)) HasError = true; }
        finally
        {
            if (Current(generation, repository)) { IsLoading = false; Notify(); EnsurePolling(); }
        }
    }
    private void Apply(IReadOnlyList<VirtualMachineTaskSummary> incoming)
    {
        var keys = new HashSet<string>(StringComparer.Ordinal);
        if (incoming.Any(item => string.IsNullOrWhiteSpace(item.Key) || !keys.Add(item.Key))) throw new InvalidOperationException("vm.tasks.identity");
        for (var i = Tasks.Count - 1; i >= 0; i--) if (!keys.Contains(Tasks[i].Task.Key)) Tasks.RemoveAt(i);
        for (var i = 0; i < incoming.Count; i++)
        {
            var existing = Tasks.FirstOrDefault(item => item.Task.Key == incoming[i].Key);
            if (existing is null) Tasks.Insert(i, new(incoming[i], i + 1));
            else
            {
                var oldIndex = Tasks.IndexOf(existing); if (oldIndex != i) Tasks.Move(oldIndex, i);
                if (existing.Task != incoming[i] || existing.Number != i + 1) Tasks[i] = new(incoming[i], i + 1);
            }
        }
    }
    private void EnsurePolling()
    {
        if (!CanRefresh || !HasUnfinishedTasks || _polling is { IsCompleted: false }) return;
        _polling = PollAsync(_generation, _repository!, _lifetime!.Token);
    }
    private async Task PollAsync(long generation, IVirtualMachineManagerRepository repository, CancellationToken token)
    {
        try
        {
            while (Current(generation, repository) && !RequiresReconnect && !IsUnavailable && HasUnfinishedTasks)
            {
                await Task.Delay(TimeSpan.FromSeconds(2), _time, token);
                if (Current(generation, repository) && !RequiresReconnect && !IsUnavailable && HasUnfinishedTasks) await RefreshAsync();
            }
        }
        catch (OperationCanceledException) { }
    }
    private bool Current(long generation, IVirtualMachineManagerRepository repository) => !_disposed && _visible && generation == _generation && ReferenceEquals(_repository, repository);
    private void Cancel() { _generation++; _cleanupConfirmation = null; _cleanupCancellation?.Cancel(); IsCleaning = false; var old = _lifetime; _lifetime = null; old?.Cancel(); old?.Dispose(); _polling = null; }
    public void Deactivate()
    { Cancel(); _visible = false; _repository = null; IsLoading = HasLoaded = HasError = RequiresReconnect = false; Tasks.Clear(); CleanupRecoveries = []; LastCleanup = null; CleanupMessageKey = null; Notify(); }
    public void Dispose() { if (_disposed) return; _disposed = true; Deactivate(); }
    private void Notify() => RaisePropertyChanged(string.Empty);
}

public sealed record VirtualMachineTaskItem(VirtualMachineTaskSummary Task, int Number)
{
    public string Title => LocalizationService.Current.Format("VmTasksItemTitle", Number);
    public string StatusText => LocalizationService.Current.Get(Task.IsProtected ? "VmTasksProtected" : Task.State switch
    { VirtualMachineTaskState.Running => "VmTasksRunning", VirtualMachineTaskState.Finished => "VmTasksFinished", _ => "VmTasksReadFailed" });
    public string ProgressText => Task.ProgressPercent is { } progress ? LocalizationService.Current.Format("VmTasksProgress", progress) : LocalizationService.Current.Get("VmTasksProgressUnknown");
    public double Progress => Task.ProgressPercent ?? 0;
    public bool IsIndeterminate => Task.State == VirtualMachineTaskState.Running && Task.ProgressPercent is null;
}
