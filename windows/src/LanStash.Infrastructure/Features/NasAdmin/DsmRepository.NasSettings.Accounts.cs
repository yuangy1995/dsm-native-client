using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    // 旧签名没有完整确认基线，不能用于实际删除。
    public Task<MutationResult> DeleteAccountAsync(string accountName, CancellationToken cancellationToken = default) =>
        Task.FromResult(StableDirectoryName(accountName) ? UnsupportedResult("deleteAccount") : ServicePreflightFailure("deleteAccount", MutationErrorCategory.Validation));

    public Task<MutationResult> DeleteGroupAsync(string groupName, CancellationToken cancellationToken = default) =>
        Task.FromResult(StableDirectoryName(groupName) ? UnsupportedResult("deleteGroup") : ServicePreflightFailure("deleteGroup", MutationErrorCategory.Validation));

    // 旧 ID 签名缺少刚读取的完整连接目标，不能用于实际断开。
    public Task<MutationResult> DisconnectConnectionAsync(string connectionId, CancellationToken cancellationToken = default) =>
        Task.FromResult(string.IsNullOrWhiteSpace(connectionId) ? ServicePreflightFailure("disconnectConnection", MutationErrorCategory.Validation) : UnsupportedResult("disconnectConnection"));

    public Task<MutationResult> StartDiskTestAsync(
        string diskId,
        NasDiskTestType testType,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(diskId))
        {
            return Task.FromResult(ConfirmedFailureResult(
                "startDiskTest", MutationErrorCategory.Validation, "disk.test.validation"));
        }

        // 旧签名缺少稳定设备和确认状态，禁止发送历史猜测请求。
        return Task.FromResult(cancellationToken.IsCancellationRequested ? CancelledBeforeSubmissionResult("startDiskTest") :
            Enum.IsDefined(testType) ? UnsupportedResult("startDiskTest") : ServicePreflightFailure("startDiskTest", MutationErrorCategory.Validation));
    }
}
