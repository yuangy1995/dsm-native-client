namespace LanStash.Domain;

public sealed record IsoMountConnection(Guid ProfileId, string Source, string MountPoint, bool AutomaticMount)
{
    public override string ToString() => nameof(IsoMountConnection);
}

// 来源为用户当前选择的文件快照；卸载必须携带原清单身份，不能只按目录名操作。
public sealed record IsoMountChange(Guid ProfileId, Guid RequestId, string MountPoint, FileItem? Source = null,
    IsoMountConnection? Existing = null, bool AutomaticMount = false, bool Confirmed = false, bool ConfirmedAutomatic = false)
{
    public bool IsUnmount => Existing is not null;
    public override string ToString() => nameof(IsoMountChange);
}

public sealed record IsoMountProgress(IsoMountChange Change, MutationResult Outcome)
{
    public override string ToString() => nameof(IsoMountProgress);
}
