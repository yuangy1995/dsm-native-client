using LanStash.Domain;

namespace LanStash.Infrastructure;

public sealed partial class DsmRepository
{
    private static bool IsMountAuthenticationFailure(DsmException error) =>
        error.AuthenticationFailure || error.Code is 106 or 107 or 119 or 401;

    // 保留旧调用方的返回契约，但它缺少确认快照和请求编号，不能转发为危险写。
    // 正式界面统一使用 RemoteMountWorkflow，不再保留猜测参数或回执即成功的平行实现。
    bool IFileLocationsRepository.AllowsRemoteMountManagement => false;

    Task<MutationResult> IFileLocationsRepository.CreateRemoteMountAsync(RemoteMountDraft draft, CancellationToken cancellationToken) =>
        Task.FromResult(LegacyRemoteMountResult("createRemoteMount", draft?.IsValidForSubmission == true, cancellationToken));

    Task<MutationResult> IFileLocationsRepository.UpdateRemoteMountAsync(RemoteMountDraft draft, CancellationToken cancellationToken) =>
        Task.FromResult(LegacyRemoteMountResult("updateRemoteMount", draft?.IsValidForSubmission == true, cancellationToken));

    Task<MutationResult> IFileLocationsRepository.DeleteRemoteMountAsync(string mountPoint, CancellationToken cancellationToken) =>
        Task.FromResult(LegacyRemoteMountResult("deleteRemoteMount", RemoteMountProtocol.IsMountPoint(mountPoint), cancellationToken));

    private MutationResult LegacyRemoteMountResult(string operation, bool valid, CancellationToken token)
    {
        var supported = _capabilities.TryGetValue("SYNO.FileStation.Mount", out var capability) &&
            capability.Name == "SYNO.FileStation.Mount" && capability.MinVersion <= 1 && capability.MaxVersion >= 1;
        var status = !supported ? MutationResultStatus.Unsupported : !valid ? MutationResultStatus.ConfirmedFailure :
            token.IsCancellationRequested ? MutationResultStatus.CancelledBeforeSubmission : MutationResultStatus.Unsupported;
        return new(1, status, operation, false, false, new(0, status == MutationResultStatus.ConfirmedFailure ? 1 : 0, 0),
            status == MutationResultStatus.ConfirmedFailure ? MutationErrorCategory.Validation :
            status == MutationResultStatus.Unsupported ? MutationErrorCategory.Unsupported : null);
    }
}
