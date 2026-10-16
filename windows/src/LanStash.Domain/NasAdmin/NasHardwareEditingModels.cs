namespace LanStash.Domain;

public enum NasHardwareEditKind { Zram, PowerSchedule }
public enum NasHardwareEditStage { NotStarted, Unknown, Confirmed, Rejected }
public sealed record NasHardwareEditStep(NasHardwareEditStage Stage, bool WasSubmitted, bool Accepted, MutationErrorCategory? Error);
public sealed record NasHardwareEditRecovery(Guid Id, NasHardwareEditKind Kind, DateTimeOffset CreatedAt,
    IReadOnlyList<NasHardwareEditStep> Steps)
{
    public bool IsComplete => Steps.All(step => step.Stage == NasHardwareEditStage.Confirmed);
    public bool HasUnknown => Steps.Any(step => step.Stage == NasHardwareEditStage.Unknown);
    public bool CanMarkReboot => Kind == NasHardwareEditKind.Zram && Steps.Count == 2 &&
        Steps[0].Stage == NasHardwareEditStage.Confirmed && Steps[1].Stage is NasHardwareEditStage.NotStarted or NasHardwareEditStage.Rejected;
}
public sealed record NasZramSaveRequest(Guid ProfileId, Guid RequestId, NasZramSnapshot Baseline, bool Enabled, bool RiskConfirmed);
public sealed record NasPowerScheduleSaveRequest(Guid ProfileId, Guid RequestId, NasPowerScheduleSnapshot Baseline,
    IReadOnlyList<NasPowerScheduleEntry> Entries, bool RiskConfirmed);
public sealed class NasHardwareEditException(MutationErrorCategory category) : Exception("nas.hardware-edit")
{
    public MutationErrorCategory Category { get; } = category;
}
