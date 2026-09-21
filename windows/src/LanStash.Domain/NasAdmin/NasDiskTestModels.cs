namespace LanStash.Domain;

public sealed record NasDiskTestTarget(string Id, string DeviceId, string? Name, bool? SupportsSmartTest)
{
    public override string ToString() => nameof(NasDiskTestTarget);
}
public sealed record NasDiskTestState(NasDiskTestTarget Target, bool IsRunning, NasDiskTestType? RunningType,
    bool? IsBusyWithOtherTest, string? ProgressDescription, string? LastResult)
{
    public override string ToString() => nameof(NasDiskTestState);
}
public sealed record NasDiskTestHistoryEntry(NasDiskTestType Type, string? ReportedTime, string? Result);
public sealed record NasDiskTestHistory(IReadOnlyList<NasDiskTestHistoryEntry> Entries, bool IsTruncated);

public enum NasDiskTestCommand { Quick, Extended, Stop }
public sealed record NasDiskTestRequest(Guid ProfileId, NasDiskTestState Baseline, NasDiskTestCommand Command, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(NasDiskTestRequest);
}
public sealed record NasDiskTestRecovery(NasDiskTestTarget Target, NasDiskTestCommand Command)
{
    public override string ToString() => nameof(NasDiskTestRecovery);
}
