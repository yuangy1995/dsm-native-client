using LanStash.Domain;
using System.Text.Json;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    public bool CanClearTasks => HasAuthenticatedVirtualMachineSession && CanReadTasks;
    private async Task<HashSet<string>> ProtectedVirtualMachineTaskIdsAsync(CancellationToken token)
    {
        var state = VmMutations; await state.Gate.WaitAsync(token).ConfigureAwait(false);
        try { return ProtectedVirtualMachineTaskIds(ServiceScope()); }
        finally { state.Gate.Release(); }
    }
    // 只能在原 VMM 协调器内读取；尚未完成资源核查的创建任务必须保留证据。
    private HashSet<string> ProtectedVirtualMachineTaskIds(string scope) => VmMutations.CreationPending.Values
        .Where(item => item.Scope == scope && item.TaskId is not null).Select(item => item.TaskId!)
        .Concat(VmMutations.ImageImportOperations.Values.Where(item => item.Scope == scope && item.Final is null && item.TaskId is not null).Select(item => item.TaskId!))
        .Concat(VmMutations.TaskCleanupOperations.Values.Where(item => item.Scope == scope).SelectMany(item => item.Items.Where(row => row.State == TaskCleanupState.Unknown).Select(row => row.Id)))
        .ToHashSet(StringComparer.Ordinal);

    public async Task<VirtualMachineTaskCleanupResult> ClearFinishedTasksAsync(VirtualMachineTaskCleanupRequest request, CancellationToken cancellationToken = default)
    {
        var keys = request?.Keys?.ToArray() ?? [];
        VirtualMachineTaskCleanupResult Reject(MutationErrorCategory category, bool cancelled = false) => new(keys.Length, 0, 0, 0, keys.Length, category, cancelled);
        if (cancellationToken.IsCancellationRequested) return Reject(MutationErrorCategory.Network, true);
        if (!CanClearTasks) return Reject(MutationErrorCategory.Unsupported);
        if (request is null || request.ProfileId != _profile.Id || request.RequestId == Guid.Empty || !request.RiskConfirmed ||
            keys.Length == 0 || keys.Any(string.IsNullOrWhiteSpace) || keys.Distinct(StringComparer.Ordinal).Count() != keys.Length) return Reject(MutationErrorCategory.Validation);
        var state = VmMutations; var scope = ServiceScope(); var signature = ServiceHash(JsonSerializer.Serialize(keys.Order(StringComparer.Ordinal).ToArray()));
        try { if (!await state.Gate.WaitAsync(0, cancellationToken).ConfigureAwait(false)) return Reject(MutationErrorCategory.Conflict); }
        catch (OperationCanceledException) { return Reject(MutationErrorCategory.Network, true); }
        try
        {
            if (state.PowerOperations.ContainsKey(request.RequestId) || state.SettingsOperations.ContainsKey(request.RequestId) || state.CreationOperations.ContainsKey(request.RequestId) || state.DeletionOperations.ContainsKey(request.RequestId)) return Reject(MutationErrorCategory.Conflict);
            if (state.NetworkOperations.ContainsKey(request.RequestId) || state.ImageImportOperations.ContainsKey(request.RequestId)) return Reject(MutationErrorCategory.Conflict);
            if (state.TaskCleanupOperations.TryGetValue(request.RequestId, out var prior))
                return prior.Scope == scope && prior.Signature == signature ? await ReviewTaskCleanupCoreAsync(prior, cancellationToken).ConfigureAwait(false) : Reject(MutationErrorCategory.Conflict);
            TaskCleanupItem[] items;
            try
            {
                var ids = await ReadVirtualMachineTaskIdsAsync(cancellationToken).ConfigureAwait(false);
                var byKey = ids.ToDictionary(id => ServiceHash(scope + "\n" + id), StringComparer.Ordinal);
                var protectedIds = ProtectedVirtualMachineTaskIds(scope);
                if (keys.Any(key => !byKey.ContainsKey(key) || protectedIds.Contains(byKey[key]))) return Reject(MutationErrorCategory.Conflict);
                items = keys.Select(key => new TaskCleanupItem(byKey[key])).ToArray();
                foreach (var item in items)
                    if ((await ReadVirtualMachineTaskAsync(item.Id, string.Empty, cancellationToken).ConfigureAwait(false)).State != VirtualMachineTaskState.Finished)
                        return Reject(MutationErrorCategory.Conflict);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException) { return Reject(MutationErrorCategory.Network, true); }
            catch (DsmException error) { return Reject(VirtualMachinePowerError(error)); }
            catch (Exception) { return Reject(MutationErrorCategory.Network); }
            var operation = new TaskCleanupOperation(scope, signature, items);
            state.TaskCleanupOperations.Add(request.RequestId, operation);
            foreach (var item in items)
            {
                if (cancellationToken.IsCancellationRequested) { operation.Cancelled = true; break; }
                try
                {
                    if ((await ReadVirtualMachineTaskAsync(item.Id, string.Empty, cancellationToken).ConfigureAwait(false)).State != VirtualMachineTaskState.Finished)
                    { operation.Error = MutationErrorCategory.Conflict; break; }
                }
                catch (OperationCanceledException) { operation.Cancelled = true; break; }
                catch (DsmException error) { operation.Error = VirtualMachinePowerError(error); break; }
                catch (Exception) { operation.Error = MutationErrorCategory.Network; break; }
                // 越过 clear 边界后，任何不明确的结果只允许 list 回读。
                item.State = TaskCleanupState.Unknown;
                try
                {
                    await SecurityCallAsync(_capabilities[PublicVirtualMachineTaskApi] with { MinVersion = 1, MaxVersion = 1 }, "clear",
                        new() { ["task_id"] = item.Id }, cancellationToken).ConfigureAwait(false);
                }
                catch (DsmException error) when (DsmApiClient.IsExplicitApiRejection(error))
                { item.State = TaskCleanupState.Failed; operation.Error = VirtualMachinePowerError(error); break; }
                catch (Exception) { operation.Error = MutationErrorCategory.Network; }
                if (cancellationToken.IsCancellationRequested) { operation.Cancelled = true; break; }
                await ReviewTaskCleanupCoreAsync(operation, cancellationToken).ConfigureAwait(false);
                if (item.State != TaskCleanupState.Cleared) break;
            }
            return CleanupResult(operation);
        }
        finally { state.Gate.Release(); }
    }
    public async Task<IReadOnlyList<VirtualMachineTaskCleanupRecovery>> GetTaskCleanupRecoveriesAsync(CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations; await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { var scope = ServiceScope(); return state.TaskCleanupOperations.Where(pair => pair.Value.Scope == scope && pair.Value.Items.Any(item => item.State == TaskCleanupState.Unknown))
                .Select(pair => new VirtualMachineTaskCleanupRecovery(pair.Key, pair.Value.Items.Length)).ToArray(); }
        finally { state.Gate.Release(); }
    }
    public async Task<VirtualMachineTaskCleanupResult?> ReviewTaskCleanupAsync(Guid requestId, CancellationToken cancellationToken = default)
    {
        EnsureVirtualMachineManagerProfile(); var state = VmMutations; await state.Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try { return state.TaskCleanupOperations.TryGetValue(requestId, out var operation) && operation.Scope == ServiceScope()
                ? await ReviewTaskCleanupCoreAsync(operation, cancellationToken).ConfigureAwait(false) : null; }
        finally { state.Gate.Release(); }
    }
    private async Task<VirtualMachineTaskCleanupResult> ReviewTaskCleanupCoreAsync(TaskCleanupOperation operation, CancellationToken token)
    {
        if (!operation.Items.Any(item => item.State == TaskCleanupState.Unknown)) return CleanupResult(operation);
        try
        {
            var ids = await ReadVirtualMachineTaskIdsAsync(token).ConfigureAwait(false); token.ThrowIfCancellationRequested();
            foreach (var item in operation.Items.Where(item => item.State == TaskCleanupState.Unknown && !ids.Contains(item.Id))) item.State = TaskCleanupState.Cleared;
            if (!operation.Items.Any(item => item.State is TaskCleanupState.Unknown or TaskCleanupState.Failed)) operation.Error = null;
        }
        catch (OperationCanceledException) { operation.Cancelled = true; }
        catch (DsmException error) { operation.Error = VirtualMachinePowerError(error); }
        catch (Exception) { operation.Error = MutationErrorCategory.Network; }
        return CleanupResult(operation);
    }
    private static VirtualMachineTaskCleanupResult CleanupResult(TaskCleanupOperation operation) => new(operation.Items.Length,
        operation.Items.Count(item => item.State == TaskCleanupState.Cleared), operation.Items.Count(item => item.State == TaskCleanupState.Failed),
        operation.Items.Count(item => item.State == TaskCleanupState.Unknown), operation.Items.Count(item => item.State == TaskCleanupState.NotStarted), operation.Error, operation.Cancelled);
    private enum TaskCleanupState { NotStarted, Unknown, Cleared, Failed }
    private sealed class TaskCleanupItem(string id) { public string Id { get; } = id; public TaskCleanupState State { get; set; } }
    private sealed class TaskCleanupOperation(string scope, string signature, TaskCleanupItem[] items)
    {
        public string Scope { get; } = scope; public string Signature { get; } = signature; public TaskCleanupItem[] Items { get; } = items;
        public MutationErrorCategory? Error { get; set; } public bool Cancelled { get; set; }
    }
}
