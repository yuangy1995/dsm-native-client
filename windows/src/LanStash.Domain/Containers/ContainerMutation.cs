namespace LanStash.Domain;

public enum ContainerMutationAction { Start, Stop, Restart, Delete }

// 确认绑定实例身份与当前摘要；未知结果只能使用原请求标识核查。
public sealed record ContainerMutationRequest(Guid ProfileId, ContainerSummary Baseline,
    ContainerMutationAction Action, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(ContainerMutationRequest);
}

public sealed record ContainerMutationRecovery(Guid RequestId, ContainerSummary Baseline, ContainerMutationAction Action)
{
    public override string ToString() => nameof(ContainerMutationRecovery);
}
