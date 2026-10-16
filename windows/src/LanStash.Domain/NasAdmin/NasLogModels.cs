namespace LanStash.Domain;

public sealed record NasLogEntry(DateTimeOffset? Time, string? Source, string? Level, string? Account, string Message)
{
    // 日志正文和账号只供当前查看窗口使用，不进入默认诊断表示。
    public override string ToString() => nameof(NasLogEntry);
}

public sealed record NasLogPage(Guid ProfileId, int Offset, int Limit, IReadOnlyList<NasLogEntry> Entries,
    long? Total, long? InfoCount = null, long? WarningCount = null, long? ErrorCount = null)
{
    public bool HasNext => Total is { } total ? Entries.Count > 0 && (long)Offset + Limit < total : Entries.Count == Limit;
    public override string ToString() => nameof(NasLogPage);
}

public enum NasLogLevelFilter { All, Error, Warning, Information }
