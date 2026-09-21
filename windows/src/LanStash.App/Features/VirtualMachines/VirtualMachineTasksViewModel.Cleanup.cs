using LanStash.Domain;

namespace LanStash.App.Features.VirtualMachines;

public sealed partial class VirtualMachineTasksViewModel
{
    private VirtualMachineTaskCleanupRequest? _cleanupConfirmation;
    private CancellationTokenSource? _cleanupCancellation;
    private bool _cleanupSubmitted;
    public bool IsCleaning { get; private set; }
    public IReadOnlyList<VirtualMachineTaskCleanupRecovery> CleanupRecoveries { get; private set; } = [];
    public VirtualMachineTaskCleanupResult? LastCleanup { get; private set; }
    public string? CleanupMessageKey { get; private set; }
    public int ClearableCount => Tasks.Count(item => item.Task.State == VirtualMachineTaskState.Finished && !item.Task.IsProtected);
    public bool CanPrepareCleanup => CanRefresh && HasLoaded && !HasError && _repository?.CanClearTasks == true && ClearableCount > 0;
    public bool CanSubmitCleanup => !_disposed && _visible && !IsCleaning && !_cleanupSubmitted && _cleanupConfirmation is { } request && _repository?.ProfileId == request.ProfileId && !RequiresReconnect;
    public bool CanReviewCleanup => CanRefresh && CleanupRecoveries.Count > 0;
    public VirtualMachineTaskCleanupRequest? BeginCleanupConfirmation()
    {
        if (!CanPrepareCleanup) return null;
        _cleanupSubmitted = false; LastCleanup = null; CleanupMessageKey = null;
        _cleanupConfirmation = new(_repository!.ProfileId, Guid.NewGuid(), Array.AsReadOnly(Tasks.Where(item => item.Task.State == VirtualMachineTaskState.Finished && !item.Task.IsProtected).Select(item => item.Task.Key).ToArray()), false);
        Notify(); return _cleanupConfirmation;
    }
    public void EndCleanupConfirmation()
    {
        _cleanupConfirmation = null; _cleanupCancellation?.Cancel(); Notify(); EnsurePolling();
    }
    public async Task SubmitCleanupAsync()
    {
        if (!CanSubmitCleanup || _repository is not { } repository || _cleanupConfirmation is not { } request) return;
        var generation = _generation; _cleanupSubmitted = true; IsCleaning = true;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime!.Token); _cleanupCancellation = cancellation; Notify();
        try
        {
            var result = await repository.ClearFinishedTasksAsync(request with { RiskConfirmed = true }, cancellation.Token);
            if (!Current(generation, repository) || _cleanupConfirmation?.RequestId != request.RequestId) return;
            LastCleanup = result;
            CleanupMessageKey = result.ErrorCategory == MutationErrorCategory.Authentication ? "VmTasksReconnect" : null;
        }
        catch { if (Current(generation, repository) && _cleanupConfirmation?.RequestId == request.RequestId) CleanupMessageKey = "VmTasksClearUnknown"; }
        finally
        {
            if (ReferenceEquals(_cleanupCancellation, cancellation)) _cleanupCancellation = null;
            if (Current(generation, repository))
            {
                IsCleaning = false; Notify();
                if (_cleanupConfirmation is null) await RefreshAsync();
            }
        }
    }
    public async Task ReviewCleanupAsync()
    {
        if (!CanReviewCleanup || _repository is not { } repository) return;
        var generation = _generation; IsCleaning = true; LastCleanup = null; CleanupMessageKey = null;
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime!.Token); _cleanupCancellation = cancellation; Notify();
        try
        {
            var results = new List<VirtualMachineTaskCleanupResult>();
            foreach (var recovery in CleanupRecoveries.ToArray())
            {
                var result = await repository.ReviewTaskCleanupAsync(recovery.RequestId, cancellation.Token);
                if (!Current(generation, repository)) return;
                if (result is not null) results.Add(result);
                if (result?.ErrorCategory == MutationErrorCategory.Authentication) break;
            }
            var pending = await repository.GetTaskCleanupRecoveriesAsync(cancellation.Token);
            if (!Current(generation, repository)) return;
            CleanupRecoveries = pending.ToArray();
            if (results.Count > 0) LastCleanup = new(results.Sum(item => item.SelectedCount), results.Sum(item => item.ClearedCount), results.Sum(item => item.FailedCount),
                results.Sum(item => item.NeedsReviewCount), results.Sum(item => item.NotStartedCount), results.FirstOrDefault(item => item.ErrorCategory is not null)?.ErrorCategory, results.Any(item => item.Cancelled));
            else CleanupMessageKey = "VmTasksClearUnknown";
        }
        catch { if (Current(generation, repository)) CleanupMessageKey = "VmTasksClearUnknown"; }
        finally
        {
            if (ReferenceEquals(_cleanupCancellation, cancellation)) _cleanupCancellation = null;
            if (Current(generation, repository)) { IsCleaning = false; Notify(); }
        }
        if (Current(generation, repository)) await RefreshAsync();
    }
}
