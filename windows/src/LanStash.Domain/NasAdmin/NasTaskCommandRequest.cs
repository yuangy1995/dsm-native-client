namespace LanStash.Domain;

public enum NasTaskCommand { Enable, Disable, Run, Delete }
public sealed record NasTaskCommandRequest(Guid ProfileId, NasTaskEntry Baseline, NasTaskCommand Command,
    NasTaskDetail? DetailBaseline, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(NasTaskCommandRequest);
}
public sealed record NasTaskCommandAvailability(bool CanEnableDisable, bool CanRun, bool CanDelete);
public sealed record NasTaskRecoveryInfo(int Id, string Name, string? RealOwner, NasTaskCommand Command)
{
    public override string ToString() => nameof(NasTaskRecoveryInfo);
}

public static class NasTaskCommandRules
{
    public static bool HasRequiredPreview(NasTaskEntry task, NasTaskCommand command, NasTaskDetail? detail)
    {
        if (task.Type != "script" || command is not (NasTaskCommand.Enable or NasTaskCommand.Run)) return true;
        if (detail is null || detail.Id != task.Id || detail.Name != task.Name || string.IsNullOrEmpty(detail.Script) || string.IsNullOrWhiteSpace(detail.Owner) ||
            (string.IsNullOrEmpty(detail.RequestedRealOwner) ? null : detail.RequestedRealOwner) != (string.IsNullOrEmpty(task.RealOwner) ? null : task.RealOwner)) return false;
        return command != NasTaskCommand.Enable || detail.Schedule is
            { DateType: not null, WeekDays: not null, RepeatDate: not null, Hour: >= 0 and <= 23, Minute: >= 0 and <= 59,
                RepeatHour: not null, RepeatMinute: not null, LastWorkHour: not null };
    }
}
