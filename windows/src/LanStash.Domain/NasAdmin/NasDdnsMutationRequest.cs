namespace LanStash.Domain;

public enum NasDdnsAction { Test, Save, UpdateAddress, Delete }

// 确认快照不含密码；密码只作为当次调用参数，不能进入恢复记录或重复提交指纹。
// Save 的 Baseline 为 null 表示新建；UpdateAddress 使用整个记录目录的服务商集合。
public sealed record NasDdnsMutationRequest(
    Guid ProfileId, NasDdnsAction Action, NasDDNSRecord? Baseline, NasDDNSRecord? Desired,
    IReadOnlyList<string> ExpectedProviderIds, Guid RequestId, bool RiskConfirmed)
{
    public override string ToString() => nameof(NasDdnsMutationRequest);
}
