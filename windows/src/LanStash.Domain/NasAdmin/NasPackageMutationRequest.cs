namespace LanStash.Domain;

// 操作绑定用户看到的完整套件快照；服务端桌面标识不接受表单自由输入。
public sealed record NasPackageMutationRequest(Guid ProfileId, NasPackageSummary Baseline,
    NasPackageAction Action, Guid RequestId, bool RiskConfirmed);

public sealed record NasPackageRecoveryInfo(string PackageId, string DisplayName, NasPackageAction Action);
public sealed record NasPackageControlAvailability(bool CanStartStop, bool CanUninstall);
