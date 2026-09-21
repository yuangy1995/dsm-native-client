namespace LanStash.Domain;

public enum VirtualMachineTaskState { Running, Finished, ReadFailed }

// Key 只包含单向摘要，不向领域或界面传递可能含账号信息的原始任务标识。
public sealed record VirtualMachineTaskSummary(string Key, VirtualMachineTaskState State, int? ProgressPercent)
{
    public bool IsProtected { get; init; }
    public override string ToString() => nameof(VirtualMachineTaskSummary);
}

public sealed record VirtualMachineTaskCleanupRequest(Guid ProfileId, Guid RequestId, IReadOnlyList<string> Keys, bool RiskConfirmed)
{
    public override string ToString() => nameof(VirtualMachineTaskCleanupRequest);
}
public sealed record VirtualMachineTaskCleanupResult(int SelectedCount, int ClearedCount, int FailedCount,
    int NeedsReviewCount, int NotStartedCount, MutationErrorCategory? ErrorCategory = null, bool Cancelled = false);
public sealed record VirtualMachineTaskCleanupRecovery(Guid RequestId, int SelectedCount);
