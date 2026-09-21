namespace LanStash.Domain;

public sealed record NasPowerRequest(Guid ProfileId, NasPowerAction Action, Guid RequestId, bool RiskConfirmed);
public sealed record NasPowerRecoveryInfo(NasPowerAction Action, MutationResult Result, bool HasFreshSession);
